-- ============================================================================
-- Activity Planet schema v2 — migration 68: recommendations review fixes.
--   Builds on migrations 1 to 67, which reached staging and are not edited.
--   Every rebuilt function starts from its migration 67 body; changes are
--   marked "Migration 68".
--
--     * Account deletion (taste): a deleted account's taste is never re-created
--       or rebuilt. private.rec_mark_stale and recs_embed_record skip deleted
--       profiles (a deleted client keeps past bookings as payment records, so
--       re-embedding a listing or auto-completing a booking used to re-create
--       the row); private.rec_taste_compute removes a deleted account's row;
--       purge_recs removes any that remain.
--     * Account deletion (dismissals): request_account_deletion also deletes
--       other members' "Not interested" in the caller as a coach
--       (subject_kind 'coach' is keyed by the coach's user id); purge_recs
--       removes any that remain.
--     * Embed cap: public.rec_embed_daily counts every stored embedding per
--       UTC day (re-embeds included) and private.rec_embedded_today reads it,
--       so meta recs_embed_daily_cap binds. A subject embedded in the last
--       hour is queued at priority 6 or later (private.rec_enqueue), so
--       repeated edits cannot hold the front of the queue.
--     * Scorecard weekly actives: public.scorecard_active_weeks counts each
--       member's first visit of a Monday-to-Sunday America/New_York week as it
--       happens (a trigger on profile_private.last_seen_at, which holds only
--       the latest visit); scorecard_week reads it. The app now calls
--       touch_last_seen (throttled to 15 minutes in the database).
--     * meta.schema_version 2.64.
--
--   Account deletion: the two new tables hold counts only, no user id.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Counter tables (counts only)
-- ---------------------------------------------------------------------------
create table if not exists public.rec_embed_daily (
  day      date primary key,
  embedded integer not null default 0 check (embedded >= 0)
);
create table if not exists public.scorecard_active_weeks (
  week_start date primary key check (extract(isodow from week_start) = 1),
  active     integer not null default 0 check (active >= 0)
);

alter table public.rec_embed_daily enable row level security;
alter table public.scorecard_active_weeks enable row level security;
revoke all on table public.rec_embed_daily from public, anon, authenticated;
revoke all on table public.scorecard_active_weeks from public, anon, authenticated;
grant select, insert, update, delete on table public.rec_embed_daily to service_role;
grant select, insert, update, delete on table public.scorecard_active_weeks to service_role;

comment on table public.rec_embed_daily is
  'Migration 68 (D-045): embeddings stored per UTC day by recs_embed_record, re-embeds included; read by private.rec_embedded_today for meta recs_embed_daily_cap. Counts only; no client role; rows older than 60 days go in purge_recs.';
comment on table public.scorecard_active_weeks is
  'Migration 68: members active per Monday-to-Sunday America/New_York week, counted at each member''s first visit of the week (trigger on profile_private.last_seen_at). Counts only; no client role.';

-- Backfill today's counter from the embeddings already made today (at least that many).
insert into public.rec_embed_daily (day, embedded)
select (now() at time zone 'UTC')::date,
       (select count(*) from public.hub_embeddings x where x.embedded_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC')
     + (select count(*) from public.event_embeddings x where x.embedded_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC')
     + (select count(*) from public.coach_listing_embeddings x where x.embedded_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC')
on conflict (day) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Embed cap and queue order
-- ---------------------------------------------------------------------------
create or replace function private.rec_embedded_today()
returns bigint language sql stable security definer set search_path = '' as $$
  -- Migration 68: from the day counter (an overwritten embedding row counted once).
  select coalesce((select d.embedded::bigint from public.rec_embed_daily d
                    where d.day = (now() at time zone 'UTC')::date), 0);
$$;

create or replace function private.rec_embedded_recently(p_kind public.rec_subject_kind, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case p_kind
           when 'hub' then exists (select 1 from public.hub_embeddings x
                                    where x.hub_id = p_id and x.embedded_at > now() - interval '1 hour')
           when 'event' then exists (select 1 from public.event_embeddings x
                                      where x.event_id = p_id and x.embedded_at > now() - interval '1 hour')
           when 'coach' then exists (select 1 from public.coach_listing_embeddings x
                                      where x.listing_id = p_id and x.embedded_at > now() - interval '1 hour')
           else false end;
$$;

create or replace function private.rec_enqueue(p_kind public.rec_subject_kind, p_id uuid, p_priority smallint)
returns void language sql security definer set search_path = '' as $$
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  -- Migration 68: a subject embedded in the last hour waits behind new subjects (priority 6 or
  -- later), so repeated edits of one hub, plan or listing cannot hold the front of the queue.
  values (p_kind, p_id,
          case when private.rec_embedded_recently(p_kind, p_id) then greatest(p_priority, 6::smallint)
               else p_priority end)
  on conflict (subject_kind, subject_id) do update
     set queued_at = now(), claimed_at = null, attempts = 0, failed_at = null, last_error = null,
         priority = least(public.rec_embed_queue.priority, excluded.priority);
$$;


-- ---------------------------------------------------------------------------
-- 3. Deleted accounts get no taste
-- ---------------------------------------------------------------------------
create or replace function private.rec_mark_stale(p_user uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.rec_taste (user_id, stale)
  select p_user, true where p_user is not null and exists (select 1 from public.profiles p where p.id = p_user
                                                                   -- Migration 68: never for a deleted account.
                                                                   and p.deleted_at is null and p.status <> 'deleted')
  on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
$$;


create or replace function public.recs_embed_record(p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r       jsonb;
  v_kind  public.rec_subject_kind;
  v_id    uuid;
  v_hash  text;
  v_arr   jsonb;
  v_ok    boolean;
  v_norm  double precision;
  v_vec   extensions.halfvec(384);
  v_n     integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  for r in select x from jsonb_array_elements(p_rows) x loop
    begin
      v_kind := (r ->> 'kind')::public.rec_subject_kind;
      v_id := (r ->> 'id')::uuid;
    exception when others then
      continue;
    end;
    if v_kind not in ('hub', 'event', 'coach') or v_id is null then
      continue;
    end if;
    v_hash := r ->> 'hash';
    v_arr := r -> 'embedding';
    -- 384 finite numbers, normalized within 1e-3.
    v_ok := jsonb_typeof(v_arr) = 'array' and jsonb_array_length(v_arr) = 384
            and not exists (select 1 from jsonb_array_elements(v_arr) e where jsonb_typeof(e) <> 'number');
    if v_ok then
      select sqrt(sum(((e #>> '{}')::double precision) ^ 2)), bool_and(abs((e #>> '{}')::double precision) <= 1.001)
        into v_norm, v_ok
        from jsonb_array_elements(v_arr) e;
      v_ok := coalesce(v_ok, false) and abs(v_norm - 1) <= 1e-3;
    end if;
    if not v_ok then
      perform public.recs_embed_fail(v_kind, v_id, 'bad_vector');
      continue;
    end if;
    if not private.rec_embeddable(v_kind, v_id) then
      delete from public.rec_embed_queue q where q.subject_kind = v_kind and q.subject_id = v_id;
      continue;
    end if;
    if v_hash is null or v_hash is distinct from private.rec_hash(private.rec_text(v_kind, v_id)) then
      -- A newer edit wins: the row is claimed again with the current text.
      update public.rec_embed_queue q set claimed_at = null
       where q.subject_kind = v_kind and q.subject_id = v_id;
      continue;
    end if;
    v_vec := (select array_agg(((e #>> '{}')::real) order by i) from jsonb_array_elements(v_arr) with ordinality t(e, i))
               ::real[]::extensions.vector(384)::extensions.halfvec(384);
    if v_kind = 'hub' then
      insert into public.hub_embeddings (hub_id, embedding, content_hash, model, embedded_at)
      values (v_id, v_vec, v_hash, 'gte-small', now())
      on conflict (hub_id) do update set embedding = excluded.embedding, content_hash = excluded.content_hash,
                                         model = excluded.model, embedded_at = excluded.embedded_at;
      insert into public.rec_taste (user_id, stale)
      select hm.user_id, true from public.hub_members hm
        join public.profiles p on p.id = hm.user_id and p.deleted_at is null and p.status <> 'deleted' -- Migration 68
       where hm.hub_id = v_id
      on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
    elsif v_kind = 'event' then
      insert into public.event_embeddings (event_id, embedding, content_hash, model, embedded_at)
      values (v_id, v_vec, v_hash, 'gte-small', now())
      on conflict (event_id) do update set embedding = excluded.embedding, content_hash = excluded.content_hash,
                                           model = excluded.model, embedded_at = excluded.embedded_at;
      insert into public.rec_taste (user_id, stale)
      select distinct rv.user_id, true from public.rsvps rv
        join public.profiles p on p.id = rv.user_id and p.deleted_at is null and p.status <> 'deleted' -- Migration 68
       where rv.event_id = v_id and rv.status <> 'cancelled'
      on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
    else
      insert into public.coach_listing_embeddings (listing_id, embedding, content_hash, model, embedded_at)
      values (v_id, v_vec, v_hash, 'gte-small', now())
      on conflict (listing_id) do update set embedding = excluded.embedding, content_hash = excluded.content_hash,
                                             model = excluded.model, embedded_at = excluded.embedded_at;
      insert into public.rec_taste (user_id, stale)
      select distinct b.client_id, true from public.bookings b
        -- Migration 68: a deleted client keeps past bookings (payment records) but gets no taste.
        join public.profiles p on p.id = b.client_id and p.deleted_at is null and p.status <> 'deleted'
       where b.listing_id = v_id and b.status = 'completed'
      on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
    end if;
    delete from public.rec_embed_queue q where q.subject_kind = v_kind and q.subject_id = v_id;
    v_n := v_n + 1;
  end loop;
  -- Migration 68: every stored embedding counts toward the day's cap, re-embeds included.
  if v_n > 0 then
    insert into public.rec_embed_daily (day, embedded)
    values ((now() at time zone 'UTC')::date, v_n)
    on conflict (day) do update set embedded = public.rec_embed_daily.embedded + excluded.embedded;
  end if;
  return v_n;
end $$;


create or replace function private.rec_taste_compute(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_sum extensions.vector;
  v_n   integer;
  v_emb extensions.halfvec(384);
begin
  if p_user is null or not exists (select 1 from public.profiles p where p.id = p_user) then
    return;
  end if;
  -- Migration 68: a deleted account has no taste; a row that reached it is removed.
  if exists (select 1 from public.profiles p where p.id = p_user and (p.deleted_at is not null or p.status = 'deleted')) then
    delete from public.rec_taste t where t.user_id = p_user;
    return;
  end if;
  if not private.rec_personalize(p_user) then
    insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
    values (p_user, null, 0, false, now())
    on conflict (user_id) do update set embedding = null, inputs = 0, stale = false, computed_at = now();
    return;
  end if;

  with inp as (
    -- Joined hubs: 1.0, no decay.
    select he.embedding as emb, 1.0::double precision as w
      from public.hub_members hm
      join public.hub_embeddings he on he.hub_id = hm.hub_id
      join public.hubs h on h.id = hm.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where hm.user_id = p_user and not c.is_sensitive and h.moderation_state is null
    union all
    -- RSVPs and check-ins: half-life 90 days from the start.
    select ee.embedding,
           (case when r.checked_in_at is not null then 2.5
                 when r.status in ('going', 'waitlisted') then 1.5
                 else 0.75 end)
           * power(0.5, greatest(0, extract(epoch from (now() - e.starts_at)) / 86400.0) / 90.0)
      from public.rsvps r
      join public.events e on e.id = r.event_id
      join public.event_embeddings ee on ee.event_id = e.id
      join public.hubs h on h.id = e.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where r.user_id = p_user and r.status <> 'cancelled'
       and e.status = 'published' and e.moderation_state is null and not c.is_sensitive
       and e.starts_at > now() - interval '365 days'
    union all
    -- Completed coaching sessions: 2.0, half-life 90 days.
    select le.embedding,
           2.0 * power(0.5, greatest(0, extract(epoch from (now() - b.starts_at)) / 86400.0) / 90.0)
      from public.bookings b
      join public.coach_listings l on l.id = b.listing_id
      join public.coach_listing_embeddings le on le.listing_id = l.id
     where b.client_id = p_user and b.status = 'completed' and b.starts_at > now() - interval '365 days'
       and l.moderation_state is null and (l.hub_id is null or not private.rec_hub_sensitive(l.hub_id))
    union all
    -- "Not interested": -0.5, half-life 30 days.
    select ee.embedding,
           -0.5 * power(0.5, greatest(0, extract(epoch from (now() - d.created_at)) / 86400.0) / 30.0)
      from public.rec_dismissals d
      join public.event_embeddings ee on ee.event_id = d.subject_id
     where d.user_id = p_user and d.subject_kind = 'event'
    union all
    select he.embedding,
           -0.5 * power(0.5, greatest(0, extract(epoch from (now() - d.created_at)) / 86400.0) / 30.0)
      from public.rec_dismissals d
      join public.hub_embeddings he on he.hub_id = d.subject_id
     where d.user_id = p_user and d.subject_kind = 'hub'
  )
  select extensions.sum(extensions.vector_mul(inp.emb::extensions.vector,
                                              array_fill(inp.w::real, array[384])::extensions.vector)),
         count(*) filter (where inp.w > 0)
    into v_sum, v_n
    from inp;

  if coalesce(v_n, 0) = 0 or v_sum is null or extensions.vector_norm(v_sum) < 1e-6 then
    v_emb := null;
    v_n := 0;
  else
    v_emb := extensions.l2_normalize(v_sum)::extensions.halfvec(384);
  end if;
  insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
  values (p_user, v_emb, v_n, false, now())
  on conflict (user_id) do update set embedding = excluded.embedding, inputs = excluded.inputs,
                                      stale = false, computed_at = excluded.computed_at;
end $$;


create or replace function public.purge_recs()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ev integer; v_hub integer; v_co integer; v_dis integer; v_q integer;
  v_gone integer; v_c integer; -- Migration 68
begin
  delete from public.event_embeddings x where not private.rec_keep('event', x.event_id);
  get diagnostics v_ev = row_count;
  delete from public.hub_embeddings x where not private.rec_keep('hub', x.hub_id);
  get diagnostics v_hub = row_count;
  delete from public.coach_listing_embeddings x where not private.rec_keep('coach', x.listing_id);
  get diagnostics v_co = row_count;
  delete from public.rec_dismissals d where d.created_at < now() - interval '180 days';
  get diagnostics v_dis = row_count;
  delete from public.rec_embed_queue q where q.failed_at is not null and q.failed_at < now() - interval '30 days';
  get diagnostics v_q = row_count;
  -- Migration 68: anything left that names a deleted account (a taste row, others' "Not
  -- interested" in them as a person or a coach), and day counters older than 60 days.
  delete from public.rec_taste t using public.profiles p
   where p.id = t.user_id and (p.deleted_at is not null or p.status = 'deleted');
  get diagnostics v_gone = row_count;
  delete from public.rec_dismissals d using public.profiles p
   where d.subject_kind in ('person', 'coach') and p.id = d.subject_id
     and (p.deleted_at is not null or p.status = 'deleted');
  get diagnostics v_c = row_count; v_gone := v_gone + v_c;
  delete from public.rec_embed_daily x where x.day < (now() at time zone 'UTC')::date - 60;
  return jsonb_build_object('events', v_ev, 'hubs', v_hub, 'listings', v_co, 'dismissals', v_dis, 'failed', v_q,
                            'deleted_accounts', v_gone);
end $$;


-- ---------------------------------------------------------------------------
-- 4. Weekly actives
-- ---------------------------------------------------------------------------
-- The Monday (America/New_York) of the week holding p_at.
create or replace function private.scorecard_week_of(p_at timestamptz)
returns date language sql stable set search_path = '' as $$
  select (p_at at time zone 'America/New_York')::date
         - (extract(isodow from (p_at at time zone 'America/New_York')::date)::integer - 1);
$$;

create or replace function private.scorecard_count_active()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_week date;
begin
  if new.last_seen_at is null or new.last_seen_at > now() + interval '5 minutes' then
    return null;
  end if;
  v_week := private.scorecard_week_of(new.last_seen_at);
  if old.last_seen_at is null or private.scorecard_week_of(old.last_seen_at) < v_week then
    insert into public.scorecard_active_weeks (week_start, active) values (v_week, 1)
    on conflict (week_start) do update set active = public.scorecard_active_weeks.active + 1;
  end if;
  return null;
end $$;

drop trigger if exists scorecard_count_active on public.profile_private;
create trigger scorecard_count_active after update of last_seen_at on public.profile_private
  for each row
  when (new.last_seen_at is distinct from old.last_seen_at)
  execute function private.scorecard_count_active();

create or replace function public.scorecard_week(p_week_start date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz     text := 'America/New_York';
  v_start  date := coalesce(p_week_start, private.scorecard_last_week());
  v_from   timestamptz;
  v_to     timestamptz;
  v_health jsonb;
  v_gate   jsonb;
begin
  if not coalesce(public.is_privileged(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if extract(isodow from v_start) <> 1 then
    raise exception 'invalid_week' using errcode = '22023', hint = 'A Monday.';
  end if;
  v_from := v_start::timestamp at time zone v_tz;
  v_to := (v_start + 7)::timestamp at time zone v_tz;
  v_health := public.collector_health_snapshot();

  select jsonb_object_agg(g.k, jsonb_build_object(
           'recurring', (select count(*) from public.events e
                          where e.kind <> 'imported' and e.status = 'published' and e.series_id is not null
                            and e.moderation_state is null
                            and e.starts_at >= (g.d::timestamp at time zone v_tz)
                            and e.starts_at < ((g.d + 7)::timestamp at time zone v_tz)),
           'target', 10))
    into v_gate
    from (values ('week_2027_01_11', date '2027-01-11'), ('week_2027_01_18', date '2027-01-18')) g(k, d);
  v_gate := v_gate || jsonb_build_object('chapters_live', jsonb_build_object(
    'count', (select count(*) from public.hub_chapters ch
               where ch.is_active and ch.moderation_state is null
                 and exists (select 1 from public.events e
                              where e.chapter_id = ch.id and e.status = 'published' and e.moderation_state is null
                                and e.starts_at > now() - interval '30 days' and e.starts_at < now() + interval '30 days')),
    'target', 5));

  return jsonb_build_object(
    'week_start', v_start,
    'people', jsonb_build_object(
       'signups', (select count(*) from public.profiles p where p.created_at >= v_from and p.created_at < v_to),
       'onboarded', (select count(*) from public.profiles p
                      where p.onboarding_completed_at >= v_from and p.onboarding_completed_at < v_to),
       -- Migration 68: members' first visit of each week, counted as it happens (last_seen_at
       -- holds only the latest visit).
       'wau', coalesce((select w.active from public.scorecard_active_weeks w where w.week_start = v_start), 0),
       'members', (select count(*) from public.profiles p
                    where p.status = 'active' and p.deleted_at is null and p.onboarding_completed_at is not null
                      and p.created_at < v_to)),
    'plans', jsonb_build_object(
       'human_hosted_held', (select count(*) from public.events e
                              where e.kind <> 'imported' and e.status = 'published'
                                and e.starts_at >= v_from and e.starts_at < v_to),
       'human_hosted_next_7d', (select count(*) from public.events e
                                 where e.kind <> 'imported' and e.status = 'published'
                                   and e.starts_at >= v_to and e.starts_at < v_to + interval '7 days'),
       'four_plus_checked_in', (select count(*) from (
                                  select r.event_id from public.rsvps r join public.events e on e.id = r.event_id
                                   where e.kind <> 'imported' and e.status = 'published'
                                     and e.starts_at >= v_from and e.starts_at < v_to and r.checked_in_at is not null
                                   group by r.event_id having count(*) >= 4) x),
       'unique_attendees', (select count(distinct r.user_id) from public.rsvps r join public.events e on e.id = r.event_id
                             where e.kind <> 'imported' and e.status = 'published'
                               and e.starts_at >= v_from and e.starts_at < v_to and r.checked_in_at is not null),
       'second_attendance_rate', (select case when count(*) = 0 then 0
                                              else round(count(*) filter (where x.n >= 2)::numeric / count(*), 3) end
                                    from (select r.user_id, count(*) as n
                                            from public.rsvps r join public.events e on e.id = r.event_id
                                           where e.status = 'published' and r.checked_in_at is not null
                                             and e.starts_at >= v_to - interval '28 days' and e.starts_at < v_to
                                           group by r.user_id) x)),
    'chapters_active', (select count(distinct e.chapter_id) from public.events e
                         where e.chapter_id is not null and e.status = 'published'
                           and e.starts_at >= v_from and e.starts_at < v_to),
    'messages', jsonb_build_object(
       'sent', (select count(*) from public.messages m where m.created_at >= v_from and m.created_at < v_to),
       'active_conversations', (select count(distinct m.conversation_id) from public.messages m
                                 where m.created_at >= v_from and m.created_at < v_to)),
    'coaching', jsonb_build_object(
       'requested', (select count(*) from public.bookings b where b.requested_at >= v_from and b.requested_at < v_to),
       'confirmed', (select count(*) from public.bookings b where b.confirmed_at >= v_from and b.confirmed_at < v_to),
       'completed', (select count(*) from public.bookings b where b.completed_at >= v_from and b.completed_at < v_to),
       'gmv_minor', coalesce((select jsonb_object_agg(x.currency, x.total)
                                from (select b.currency::text as currency, sum(b.price_minor) as total
                                        from public.bookings b
                                       where b.status = 'completed' and b.completed_at >= v_from and b.completed_at < v_to
                                       group by b.currency) x), '{}'::jsonb)),
    'collector', jsonb_build_object(
       'imported_upcoming', (select count(*) from public.events e
                              where e.kind = 'imported' and e.status = 'published' and e.starts_at > now()),
       'sources_ok', greatest(0, coalesce((select sum((s ->> 'count')::integer) from jsonb_array_elements(v_health -> 'sources') s
                                            where s ->> 'state' = 'enabled'), 0)
                                 - coalesce(jsonb_array_length(v_health -> 'stale'), 0)),
       'sources_stale', coalesce(jsonb_array_length(v_health -> 'stale'), 0)),
    'recs', jsonb_build_object(
       'tastes_with_vector', (select count(*) from public.rec_taste t where t.embedding is not null),
       'embeddings', jsonb_build_object(
          'hub', (select count(*) from public.hub_embeddings),
          'event', (select count(*) from public.event_embeddings),
          'coach', (select count(*) from public.coach_listing_embeddings)),
       'queue_due', (select count(*) from public.rec_embed_queue q where q.failed_at is null),
       'failed', (select count(*) from public.rec_embed_queue q where q.failed_at is not null)),
    'trust', jsonb_build_object(
       'reports_open', (select count(*) from (select 1 from public.reports r where r.status = 'open'
                                               group by r.target_kind, r.target_id) x),
       'reports_overdue', (select count(*) from (select 1 from public.reports r where r.status = 'open'
                                                  group by r.target_kind, r.target_id having min(r.due_at) < now()) x),
       'takedowns_open', (select count(*) from public.takedown_requests t where t.status in ('open', 'waiting'))),
    'launch_gate', v_gate);
end $$;


-- ---------------------------------------------------------------------------
-- 5. Account deletion (migration 67 body; the change is marked "Migration 68")
-- ---------------------------------------------------------------------------
create or replace function public.request_account_deletion(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_email   text;
  v_handle  text;
  v_reason  text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_event   uuid;
  v_ids     uuid[];
  v_conv    uuid;   -- Migration 58
  v_b       record; -- Migration 60
  v_src     uuid;   -- Migration 62
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = uid for update;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  -- Idempotent: a retry after a lost response must not fail.
  if v_profile.status = 'deleted' then
    return;
  end if;

  select lower(email) into v_email from auth.users where id = uid;

  -- Evidence ledger first; it has no foreign key and outlives everything below.
  insert into public.account_deletions (user_id, email_hash, requested_at, retain_evidence_until, reason)
  values (
    uid,
    encode(extensions.digest(coalesce(v_email, uid::text), 'sha256'), 'hex'),
    now(),
    -- Migration 51: a banned account's ledger row is kept for a year.
    now() + case when v_profile.status = 'banned' then interval '365 days' else interval '30 days' end,
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null;

  -- Release the handle (30-day hold, same as a rename) and pick a tombstone handle that
  -- cannot collide: 'deleted' itself is reserved and the suffix is random.
  insert into public.handle_history (user_id, handle) values (uid, v_profile.handle);
  loop
    v_handle := 'deleted_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = v_handle);
  end loop;

  perform set_config('ap.account_deletion', 'on', true);
  update public.profiles
     set handle                 = v_handle,
         first_name             = 'Deleted user',
         bio                    = '',
         avatar_url             = null,
         home_org_id            = null,
         home_campus_id         = null,
         guidelines_accepted_at = null,
         status                 = 'deleted',
         deletion_requested_at  = now(),
         deleted_at             = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Events: hosted series and future events are cancelled (past ones stay as
  -- history under "Deleted user"), their addresses go, private venues go,
  -- public venues lose the creator link.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted',
         location_text = '', address_note = ''
   where host_id = uid and status = 'published';
  update public.event_series
     set location_text = '', address_note = ''
   where host_id = uid and (location_text <> '' or address_note <> '');
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
     where host_id = uid and status = 'published' and starts_at > now()
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;
  -- Their attendees hear about it (migration 18); the caller's own profile is
  -- already a tombstone, so nothing is queued for the caller.
  foreach v_event in array v_ids loop
    perform public.notify_event_audience(
      v_event, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
      v_event::text, null, jsonb_build_object('reason', 'host_deleted'));
  end loop;
  v_event := null;
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

  -- Places (migration 27): the caller's private pins and still-pending
  -- requests go; places a moderator reviewed stay as ODbL place facts with
  -- no creator link (D-041).
  delete from public.places
   where created_by = uid and source = 'user' and (not is_public or status = 'pending');
  update public.places set created_by = null where created_by = uid;

  -- Place corrections and reports (migration 34): pending edits go; the
  -- rest of the caller's edits and every report they made lose the author
  -- and the note (a report keeps its reason, so a place it hid stays in the
  -- moderation queue); reviewer stamps and moderation log entries naming the caller are
  -- cleared.
  delete from public.place_edits where proposed_by = uid and status = 'pending';
  update public.place_edits set proposed_by = null, note = '' where proposed_by = uid;
  update public.place_edits set reviewed_by = null where reviewed_by = uid;
  update public.place_reports set reporter_id = null, note = '' where reporter_id = uid;
  update public.place_reports set resolved_by = null where resolved_by = uid;
  update public.place_mod_actions set moderator_id = null where moderator_id = uid;
  -- Migration 36: the caller's add and edit rate log.
  delete from public.place_rate_log where user_id = uid;

  -- Attendance (migration 20): the caller's reports and every meet that
  -- names the caller, in either direction. (Reports would also go with the
  -- RSVP rows below; deleted here so the order does not matter.)
  delete from public.event_meets              where user_id = uid or met_user_id = uid;
  delete from public.event_attendance_reports where user_id = uid;

  -- RSVPs: every row goes (the counters trigger fixes the counts); seats on
  -- future events are handed to the waitlist.
  for v_event in
    select event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = uid and r.status = 'going' and e.status = 'published' and e.ends_at > now()
  loop
    delete from public.rsvps where event_id = v_event and user_id = uid;
    perform public.rsvp_promote_waitlist(v_event);
  end loop;
  delete from public.rsvps where user_id = uid;
  update public.rsvps set removed_by = null where removed_by = uid;
  update public.rsvps set checked_in_by = null where checked_in_by = uid;

  -- Chapters: the caller's claims (reference contacts included) go; stamps
  -- that point at the caller are cleared. The chapter_members row goes below
  -- (the last-organizer guard lets a deleted profile leave).
  delete from public.chapter_claims where user_id = uid;
  update public.chapter_claims set reviewed_by = null where reviewed_by = uid;
  update public.hub_chapters set claimed_by = null where claimed_by = uid;

  -- Notifications (migration 18): the caller's inbox goes; rows that name the
  -- caller as the actor keep their text and lose the link; broadcasts the
  -- caller sent stay with the event, unattributed.
  delete from public.notifications where user_id = uid;
  update public.notifications set actor_id = null where actor_id = uid;
  update public.event_broadcasts set sender_id = null where sender_id = uid;

  -- Trust and safety (migration 51): blocks and mutes in either direction
  -- go; reports the caller filed lose the reporter and the note; resolver
  -- and moderator stamps naming the caller are cleared, and so are profile
  -- snapshots about the caller. Reports about the caller and the action log
  -- stay as moderation evidence.
  delete from public.blocks where blocker_id = uid or blocked_id = uid;
  delete from public.mutes  where muter_id = uid or muted_id = uid;
  update public.reports set reporter_id = null, note = '' where reporter_id = uid;
  update public.reports set resolved_by = null where resolved_by = uid;
  update public.moderation_actions set moderator_id = null where moderator_id = uid;
  update public.moderation_actions set snapshot = null where target_user_id = uid and snapshot is not null;

  -- Migration 52: NCII takedowns. Resolver stamps naming the caller are
  -- cleared; the caller's image hashes go, except blocked ones (evidence of
  -- who uploaded a removed image). Requests about the caller stay, like
  -- reports.
  update public.takedown_requests set resolved_by = null where resolved_by = uid;
  delete from public.image_hashes where owner_id = uid and status <> 'blocked';

  -- Migration 53: admin panel lookups the caller made lose the moderator
  -- link; lookups about the caller stay (a year, like the rest of the log).
  update public.admin_lookups set moderator_id = null where moderator_id = uid;

  -- Migration 58: messaging. Pending requests the caller sent go with their
  -- one message (the DM existed only for them); requests to the caller go.
  -- Groups the caller owns pass to the oldest admin, else the oldest member.
  -- DMs with the caller close. The caller's member rows go; a dm or group
  -- nobody is left in goes with its messages. Messages others received stay
  -- under the tombstone ("Deleted user"), without the device key or a kept
  -- deleted text; images are removed (the Edge Function deletes the files).
  -- Report evidence stays until its retain_until.
  delete from public.conversations c
   using public.message_requests r
   where r.conversation_id = c.id and r.from_user = uid and r.status = 'pending';
  for v_conv in
    select cm.conversation_id from public.conversation_members cm
      join public.conversations c on c.id = cm.conversation_id
     where cm.user_id = uid and c.kind = 'group' and cm.role = 'owner' and cm.left_at is null
  loop
    update public.conversation_members set role = 'owner'
     where conversation_id = v_conv
       and user_id = (select cm.user_id from public.conversation_members cm
                       where cm.conversation_id = v_conv and cm.user_id <> uid
                         and cm.left_at is null and cm.removed_at is null
                       order by (cm.role = 'admin') desc, cm.joined_at, cm.user_id
                       limit 1);
  end loop;
  update public.conversations set closed_at = coalesce(closed_at, now())
   where kind = 'dm' and (split_part(dm_key, ':', 1) = uid::text or split_part(dm_key, ':', 2) = uid::text);
  delete from public.message_requests where from_user = uid or to_user = uid;
  delete from public.conversation_members where user_id = uid;
  update public.conversation_members set removed_by = null where removed_by = uid;
  update public.conversations set created_by = null where created_by = uid;
  delete from public.conversations c
   where c.kind in ('dm', 'group')
     and not exists (select 1 from public.conversation_members cm
                      where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null);
  update public.messages
     set client_id = null, deleted_body = null,
         image_state = case when kind = 'image' then 'removed' else image_state end
   where author_id = uid;
  delete from public.chat_filter_strikes where user_id = uid;

  -- Migration 60: coaching (design section 13). Open requests and upcoming confirmed bookings
  -- end: as the coach with full refunds, as the client as a client cancellation now; the other
  -- side is told. Reports on reviews by or about the caller keep the text in the report note;
  -- those reviews go (ratings are recomputed). Bookings with the caller lose the client note and
  -- the meeting details. The coach profile goes with its credentials, photo rows, hubs, listings
  -- and their private notes, availability, exceptions and sessions; past bookings keep their own
  -- snapshot (listing_id and session_id are set null) under "Deleted user", as payment and tax
  -- records. booking_payments and coach_stripe_accounts stay (the delete-account function closes
  -- the Stripe account). Photo files go with the avatars/<uid>/ folder.
  for v_b in select b.id, b.coach_id from public.bookings b
              where (b.coach_id = uid or b.client_id = uid)
                and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
    perform private.booking_cancel(v_b.id, 'system', 'account_deleted',
                                   case when v_b.coach_id = uid then 'full' else 'policy' end, true);
  end loop;
  update public.reports r
     set note = left(btrim(r.note || ' [text] ' || case when r.target_kind = 'coach_review' then cr.body
                                                         else coalesce(cr.reply, '') end), 1000)
    from public.coach_reviews cr
   where r.target_id = cr.booking_id and r.target_kind in ('coach_review', 'coach_review_reply')
     and (cr.client_id = uid or cr.coach_id = uid);
  delete from public.coach_reviews where client_id = uid or coach_id = uid;
  update public.bookings set client_note = '' where (coach_id = uid or client_id = uid) and client_note <> '';
  delete from public.booking_private bp using public.bookings b
   where b.id = bp.booking_id and (b.coach_id = uid or b.client_id = uid);
  delete from public.coach_profiles where user_id = uid;

  -- Migration 62: organizer claims and connected feeds. Feeds the caller connected (organizer
  -- origin) stop, their upcoming items are withdrawn, and they lose the owner; claimed sources the
  -- collector found itself stay on without an owner. Claims, OAuth states and the Eventbrite token
  -- in the vault go. Listing removal requests hold no account link; resolver stamps are cleared.
  for v_src in
    select f.id from public.feed_sources f
     where f.origin = 'organizer'
       and (f.organizer_id = uid
            or f.organizer_claim_id in (select c.id from public.organizer_claims c where c.user_id = uid))
  loop
    perform public.feed_source_withdraw(v_src, 'stop');
    update public.feed_sources
       set enabled = false, organizer_stopped_at = coalesce(organizer_stopped_at, now()),
           organizer_id = null, organizer_verified_at = null
     where id = v_src;
  end loop;
  update public.feed_sources
     set organizer_id = null, organizer_verified_at = null, organizer_hub_id = null
   where organizer_id = uid;
  delete from public.organizer_claims where user_id = uid;
  delete from public.organizer_oauth_states where user_id = uid;
  begin
    delete from vault.secrets where name = 'eventbrite:' || uid::text;
  exception when insufficient_privilege then
    -- Where the definer may not delete vault rows, the token is overwritten instead.
    perform vault.update_secret(s.id, 'revoked') from vault.secrets s where s.name = 'eventbrite:' || uid::text;
  end;
  update public.listing_removal_requests set resolved_by = null where resolved_by = uid;

  -- Personal data and memberships go now. Avatar files are removed by the Edge Function
  -- through the Storage API (deleting storage.objects rows here would orphan the files).
  delete from public.profile_private          where user_id = uid;
  delete from public.notification_prefs       where user_id = uid;
  delete from public.push_devices             where user_id = uid;
  delete from public.hub_members              where user_id = uid;
  delete from public.chapter_members          where user_id = uid;
  delete from public.org_memberships          where user_id = uid;
  delete from public.verified_emails          where user_id = uid;
  delete from public.email_verification_codes where user_id = uid;
  delete from public.user_roles               where user_id = uid;
  delete from public.area_waitlist            where user_id = uid;
  -- Migration 67: recommendations. The caller's taste vector, prefs and dismissals go (after
  -- the hub_members delete above, whose trigger marks the taste stale), and so does every other
  -- member's "Not interested" in the caller.
  delete from public.rec_taste                where user_id = uid;
  delete from public.rec_prefs                where user_id = uid;
  delete from public.rec_dismissals           where user_id = uid;
  delete from public.rec_dismissals           where subject_kind = 'person' and subject_id = uid;
  -- Migration 68: coach dismissals are keyed by the coach's user id too.
  delete from public.rec_dismissals           where subject_kind = 'coach' and subject_id = uid;
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;


-- ---------------------------------------------------------------------------
-- 6. Comments
-- ---------------------------------------------------------------------------
comment on function public.recs_embed_record(jsonb) is
  'Migration 67, service role (recs-embed): [{kind, id, hash, embedding (384 numbers)}]. Refuses a wrong length or a vector not normalized within 1e-3 (bad_vector) and a stale hash (claimed again); upserts the embedding, completes the queue row and marks the owners'' tastes stale (migration 68: never a deleted account''s) and adds the count stored to rec_embed_daily. Returns the count stored.';
comment on function public.purge_recs() is
  'Migration 67, service role (pg_cron purge-recs): embeddings that may not stay, dismissals older than 180 days, failed queue rows older than 30 days; migration 68: deleted accounts'' taste rows, others'' dismissals of a deleted person or coach, rec_embed_daily rows older than 60 days. Returns counts.';
comment on function public.scorecard_week(date) is
  'Migration 67 (D-045), service role or moderators: counts only for the Monday-to-Sunday week in America/New_York (the last full week when null): people (wau from scorecard_active_weeks, migration 68), plans, chapters_active, messages, coaching, collector, recs, trust, launch_gate. Errors: forbidden, invalid_week.';
comment on function public.touch_last_seen() is
  'Throttled presence write (15 minutes) on the caller''s profile_private.last_seen_at; called by the app on load and when it returns to the foreground. Migration 68: the first write of a week counts the member in scorecard_active_weeks.';

-- ---------------------------------------------------------------------------
-- 7. Privileges (explicit), version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function private.rec_embedded_today() from public, anon, authenticated;
revoke all on function private.rec_embedded_recently(public.rec_subject_kind, uuid) from public, anon, authenticated;
revoke all on function private.rec_enqueue(public.rec_subject_kind, uuid, smallint) from public, anon, authenticated;
revoke all on function private.rec_mark_stale(uuid) from public, anon, authenticated;
revoke all on function private.rec_taste_compute(uuid) from public, anon, authenticated;
revoke all on function private.scorecard_week_of(timestamptz) from public, anon, authenticated;
revoke all on function private.scorecard_count_active() from public, anon, authenticated;

revoke all on function public.recs_embed_record(jsonb) from public, anon, authenticated;
grant execute on function public.recs_embed_record(jsonb) to service_role;
revoke all on function public.purge_recs() from public, anon, authenticated;
grant execute on function public.purge_recs() to service_role;
revoke all on function public.scorecard_week(date) from public, anon;
grant execute on function public.scorecard_week(date) to authenticated, service_role;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;
revoke all on function public.touch_last_seen() from public, anon;
grant execute on function public.touch_last_seen() to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.64')
  on conflict (key) do update set value = excluded.value, updated_at = now();
