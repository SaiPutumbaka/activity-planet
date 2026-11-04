-- ============================================================================
-- Activity Planet schema v2 — migration 25: collector region limits and
--   anonymity (D-040 review fixes for migration 24). Fixes forward; the one
--   rebuilt function, collector_note_home_point, starts from its latest body
--   (migration 24, 20261119000100) and changes only what is listed.
--   Checks: supabase/tests/location_region_limits.sql.
--
--   What this file does
--     1. profile_private.home_region_noted_at and home_count_noted_at:
--        owner-only stamps of when this person last added a collector region
--        and last counted a home save on one. Deleted with the row on account
--        deletion (delete-account removes profile_private whole). No client
--        UPDATE grant.
--     4. collector_note_home_point (migration 24 body):
--        - per person, at most one new region per 24 hours and one home_count
--          bump per 24 hours (moving back and forth no longer grows counts);
--        - across everyone, at most 100 new regions per UTC day;
--        - a new region stores label = null, never the person's typed text
--          (p_label is accepted for the callers and ignored);
--        - first_user_at is the UTC day, not the exact time.
--        Callers (set_home_location, set_home_area, complete_onboarding) are
--        unchanged; the person is auth.uid() of the calling RPC.
--     2. collector_regions times rounded to the UTC day on every write
--        (first_user_at, created_at, updated_at), so a row cannot be matched
--        to one person's onboarding or home change. The per-row set_updated_at
--        trigger is replaced by the rounding trigger.
--     3. Existing rows: user-created regions (first_user_at set) lose their
--        label; every row's times are rounded.
--     * meta.schema_version 2.21.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Per-person stamps (owner-only)
-- ---------------------------------------------------------------------------
alter table public.profile_private
  add column if not exists home_region_noted_at timestamptz,
  add column if not exists home_count_noted_at  timestamptz;

comment on column public.profile_private.home_region_noted_at is
  'When this person''s home save last added a collector region (D-040). collector_note_home_point adds at most one per 24 hours per person. Owner-only.';
comment on column public.profile_private.home_count_noted_at is
  'When this person''s home save last counted on a collector region (home_count). At most once per 24 hours per person. Owner-only.';

revoke update (home_region_noted_at, home_count_noted_at) on public.profile_private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. collector_regions times rounded to the UTC day
-- ---------------------------------------------------------------------------
create or replace function public.collector_regions_round_times()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  new.first_user_at := date_trunc('day', new.first_user_at, 'UTC');
  new.created_at    := date_trunc('day', new.created_at, 'UTC');
  new.updated_at    := date_trunc('day', new.updated_at, 'UTC');
  return new;
end $$;
comment on function public.collector_regions_round_times() is
  'Trigger: rounds collector_regions.first_user_at, created_at and updated_at to the UTC day on every insert and update (D-040: a region is a place and a count, never linkable to one person''s save time). Sets updated_at on update.';

drop trigger if exists collector_regions_set_updated_at on public.collector_regions;
drop trigger if exists collector_regions_round_times on public.collector_regions;
create trigger collector_regions_round_times
  before insert or update on public.collector_regions
  for each row execute function public.collector_regions_round_times();

-- ---------------------------------------------------------------------------
-- 3. Existing rows
-- ---------------------------------------------------------------------------
update public.collector_regions
   set label = case when first_user_at is not null then null else label end;

comment on table public.collector_regions is
  'Collector discovery queue (D-040): places where sources should be found, as a point rounded to 0.1 degree plus a radius. Added when someone saves a home point outside every region (collector_note_home_point; at most one per person per 24 hours and 100 per UTC day). User-added rows carry no label; times are rounded to the UTC day; never a user id. Service role writes; moderators read.';
comment on column public.collector_regions.label is
  'Seeded or moderator-set place name. Null on rows added from a home save (never the person''s text).';

-- ---------------------------------------------------------------------------
-- 4. collector_note_home_point (migration 24 body) with limits
-- ---------------------------------------------------------------------------
create or replace function public.collector_note_home_point(
  p_point extensions.geography, p_label text, p_old_point extensions.geography default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_region  uuid;
  v_region_at timestamptz;
  v_count_at  timestamptz;
  c_daily_cap constant integer := 100;
begin
  if p_point is null then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtext('public.collector_regions'));

  if uid is not null then
    select pp.home_region_noted_at, pp.home_count_noted_at into v_region_at, v_count_at
      from public.profile_private pp where pp.user_id = uid;
  end if;

  select r.id into v_region
    from public.collector_regions r
   where extensions.ST_DWithin(r.point, p_point, r.radius_km * 1000.0)
   order by extensions.ST_Distance(r.point, p_point)
   limit 1;

  if v_region is not null then
    if (v_count_at is null or v_count_at <= now() - interval '24 hours')
       and (p_old_point is null or not exists (
         select 1 from public.collector_regions r
          where r.id = v_region and extensions.ST_DWithin(r.point, p_old_point, r.radius_km * 1000.0))) then
      update public.collector_regions set home_count = home_count + 1 where id = v_region;
      if uid is not null then
        update public.profile_private set home_count_noted_at = now() where user_id = uid;
      end if;
    end if;
    return false;
  end if;

  -- One new region per person per 24 hours; 100 per UTC day across everyone.
  if v_region_at is not null and v_region_at > now() - interval '24 hours' then
    return false;
  end if;
  if (select count(*) from public.collector_regions r
       where r.first_user_at is not null
         and r.created_at >= date_trunc('day', now(), 'UTC')) >= c_daily_cap then
    return false;
  end if;

  insert into public.collector_regions (point, radius_km, label, first_user_at, priority, home_count)
  values (
    extensions.ST_SetSRID(extensions.ST_MakePoint(
      round(extensions.ST_X(p_point::extensions.geometry)::numeric, 1)::double precision,
      round(extensions.ST_Y(p_point::extensions.geometry)::numeric, 1)::double precision),
      4326)::extensions.geography,
    25,
    null,
    date_trunc('day', now(), 'UTC'),
    10,
    1);
  if uid is not null then
    update public.profile_private
       set home_region_noted_at = now(), home_count_noted_at = now()
     where user_id = uid;
  end if;
  return true;
end $$;
comment on function public.collector_note_home_point(extensions.geography, text, extensions.geography) is
  'Internal (D-040): adds a collector_regions row (point rounded to 0.1 degree, 25 km, priority 10, no label, first_user_at the UTC day) when p_point is outside every region, at most once per 24 hours for the calling person (auth.uid()) and 100 times per UTC day overall; else counts the save on the nearest containing region if p_old_point was not already in it, at most once per 24 hours per person. p_label is ignored. Returns true when a region was added. Called only by set_home_location, set_home_area and complete_onboarding.';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.collector_regions_round_times() from public, anon, authenticated, service_role;
revoke all on function public.collector_note_home_point(extensions.geography, text, extensions.geography) from public, anon, authenticated, service_role;

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.21')
  on conflict (key) do update set value = excluded.value, updated_at = now();
