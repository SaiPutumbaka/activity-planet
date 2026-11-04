-- ============================================================================
-- Activity Planet schema v2 — migration 48: lane 1 by region, Ticketmaster
--   and SeatGeek for the "Shows and games" row (D-042 slice 10,
--   docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md 7 and 10). New
--   functions and one pg_cron job only; no existing function is changed.
--   Shows are already listing_kind 'show' (feed_sources_listing_kind_default
--   and event_listing_kind_sync, migration 35).
--   Checks: supabase/tests/lane1_shows.sql.
--
--   What this file does
--     1. collector_api_budget_take(p_api, p_calls), service role (POST
--        /collector/api-budget): grants up to p_calls (1 to 1000) of the
--        API's calls for today (UTC), within its daily cap: ticketmaster
--        1000 (design 7; the free key allows 5000 a day), seatgeek 1000
--        (its free limit is not published). Recorded in collector_budget as
--        ticketmaster_calls and seatgeek_calls. Returns {api, day, granted,
--        cap, used}; granted is 0 once the day is spent.
--     2. collector_api_budget_return(p_api, p_day, p_calls), service role
--        (POST /collector/api-budget/return): gives back calls granted but
--        not sent, on the day they were taken (today or yesterday), never
--        below 0.
--     3. collector_api_shows_sweep(), pg_cron daily (api-shows-sweep): the
--        caching limit of the ticketing APIs' terms. Ticketmaster allows
--        caching only "for reasonable periods" needed for the service and
--        SeatGeek data is shown with SeatGeek's attribution, so their
--        listings live only while the nightly run keeps refreshing them:
--        an upcoming published imported event whose only live copies are
--        Ticketmaster or SeatGeek rows not seen for 3 days is cancelled as
--        "No longer listed by the source." (the importer brings it back the
--        next time it is listed), and the stored raw item of a ticketing row
--        is cleared 7 days after its event ended (or 7 days after it was
--        last seen without an event). Covers a key that is removed too.
--     * meta.schema_version 2.44.
--
--   Account deletion: collector_budget, event_imports and the imported
--   events touched here hold no user id, so request_account_deletion is
--   unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. collector_api_budget_take
-- ---------------------------------------------------------------------------
create or replace function public.collector_api_budget_cap(p_api text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_api when 'ticketmaster' then 1000 when 'seatgeek' then 1000 end;
$$;

comment on function public.collector_api_budget_cap(text) is
  'D-042 slice 10, internal: the daily call cap of a lane 1 API (ticketmaster 1000, seatgeek 1000), null for any other name.';

create or replace function public.collector_api_budget_take(p_api text, p_calls integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cap   integer := public.collector_api_budget_cap(p_api);
  v_day   date := (now() at time zone 'utc')::date;
  v_src   text;
  v_used  integer;
  v_grant integer;
begin
  if v_cap is null then
    raise exception 'api_invalid' using errcode = 'check_violation';
  end if;
  if p_calls is null or p_calls < 1 or p_calls > 1000 then
    raise exception 'calls_invalid' using errcode = 'check_violation';
  end if;
  v_src := p_api || '_calls';
  insert into public.collector_budget (day, source, used) values (v_day, v_src, 0)
  on conflict (day, source) do nothing;
  select b.used into v_used from public.collector_budget b
   where b.day = v_day and b.source = v_src
   for update;
  v_grant := greatest(0, least(p_calls, v_cap - v_used));
  if v_grant > 0 then
    update public.collector_budget set used = used + v_grant
     where day = v_day and source = v_src;
  end if;
  return jsonb_build_object('api', p_api, 'day', v_day, 'granted', v_grant,
                            'cap', v_cap, 'used', v_used + v_grant);
end $$;

comment on function public.collector_api_budget_take(text, integer) is
  'D-042 slice 10, service_role only (POST /collector/api-budget): grants up to p_calls (1 to 1000) of today''s (UTC) calls for a lane 1 API (ticketmaster or seatgeek) within its daily cap (collector_api_budget_cap) and records them in collector_budget (<api>_calls). Returns {api, day, granted, cap, used}; granted 0 once the day is spent. No user data.';

revoke all on function public.collector_api_budget_cap(text) from public, anon, authenticated;
revoke all on function public.collector_api_budget_take(text, integer) from public, anon, authenticated;
grant execute on function public.collector_api_budget_cap(text) to service_role;
grant execute on function public.collector_api_budget_take(text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 2. collector_api_budget_return
-- ---------------------------------------------------------------------------
create or replace function public.collector_api_budget_return(p_api text, p_day date, p_calls integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_used  integer;
begin
  if public.collector_api_budget_cap(p_api) is null then
    raise exception 'api_invalid' using errcode = 'check_violation';
  end if;
  if p_day is null or p_day not in (v_today, v_today - 1) then
    raise exception 'day_invalid' using errcode = 'check_violation';
  end if;
  if p_calls is null or p_calls < 1 or p_calls > 1000 then
    raise exception 'calls_invalid' using errcode = 'check_violation';
  end if;
  update public.collector_budget set used = greatest(0, used - p_calls)
   where day = p_day and source = p_api || '_calls'
  returning used into v_used;
  return jsonb_build_object('api', p_api, 'day', p_day, 'used', coalesce(v_used, 0));
end $$;

comment on function public.collector_api_budget_return(text, date, integer) is
  'D-042 slice 10, service_role only (POST /collector/api-budget/return): gives back p_calls (1 to 1000) a run was granted but did not send, on the day they were taken (today or yesterday, UTC), never below 0. Returns {api, day, used}.';

revoke all on function public.collector_api_budget_return(text, date, integer) from public, anon, authenticated;
grant execute on function public.collector_api_budget_return(text, date, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 3. collector_api_shows_sweep and its pg_cron job
-- ---------------------------------------------------------------------------
create or replace function public.collector_api_shows_sweep()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cancelled integer := 0;
  v_cleared   integer := 0;
begin
  with stale as (
    select e.id from public.events e
     where e.kind = 'imported' and e.status = 'published' and e.ends_at > now()
       and exists (select 1 from public.event_imports ei
                     join public.feed_sources fs on fs.id = ei.source_id
                    where ei.event_id = e.id and ei.removed_at is null
                      and fs.kind in ('ticketmaster', 'seatgeek'))
       and not exists (select 1 from public.event_imports ei
                         join public.feed_sources fs on fs.id = ei.source_id
                        where ei.event_id = e.id and ei.removed_at is null
                          and (fs.kind not in ('ticketmaster', 'seatgeek')
                               or ei.last_seen_at >= now() - interval '3 days'))
     for update of e skip locked
  ), done as (
    update public.events e
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'No longer listed by the source.'
      from stale where e.id = stale.id
    returning e.id
  )
  select count(*) into v_cancelled from done;

  with cleared as (
    update public.event_imports ei set raw = '{}'::jsonb
      from public.feed_sources fs
     where fs.id = ei.source_id and fs.kind in ('ticketmaster', 'seatgeek')
       and ei.raw <> '{}'::jsonb
       and ((ei.event_id is null and ei.last_seen_at < now() - interval '7 days')
            or exists (select 1 from public.events e
                        where e.id = ei.event_id and e.ends_at < now() - interval '7 days'))
    returning ei.id
  )
  select count(*) into v_cleared from cleared;

  return jsonb_build_object('cancelled', v_cancelled, 'raw_cleared', v_cleared);
end $$;

comment on function public.collector_api_shows_sweep() is
  'D-042 slice 10, pg_cron daily (api-shows-sweep): the ticketing APIs'' caching limit (Ticketmaster: cache only for reasonable periods). Cancels upcoming published imported events whose only live copies are Ticketmaster or SeatGeek rows not seen for 3 days, as "No longer listed by the source." (the importer re-publishes them when listed again), and clears the stored raw item of ticketing rows 7 days after their event ended or, without an event, 7 days after last seen. Returns counts. No user data.';

revoke all on function public.collector_api_shows_sweep() from public, anon, authenticated;
grant execute on function public.collector_api_shows_sweep() to service_role;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; api-shows-sweep not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'api-shows-sweep') then
    perform cron.unschedule('api-shows-sweep');
  end if;
  perform cron.schedule('api-shows-sweep', '47 4 * * *', 'select public.collector_api_shows_sweep()');
end $$;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.44')
  on conflict (key) do update set value = excluded.value, updated_at = now();
