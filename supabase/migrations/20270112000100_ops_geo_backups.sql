-- ============================================================================
-- Migration 80: uptime alerts, the address and city search proxy, the staging
-- backup bucket (pre-launch ops, task B).
--
--   1. public.ops_uptime_alert(p_failed): keepalive.yml's uptime job calls it
--      (Management API, production token, main only) after a failed check of
--      the site health or the app. One ops_alert {alert: site_down, count} per
--      active moderator, at most one per six-hour window. Service role only.
--   2. Address and city search through the geo-search Edge Function, so the
--      Geoapify key never reaches a browser (the app used VITE_GEOAPIFY_KEY):
--        geo_search_usage   searches per member and UTC day (kept two days,
--                           removed when the account is deleted)
--        geo_search_cache   answers by a hash of the normalized request, 30 days
--        geo_search_take    service role: counts one search for a member
--                           (meta.geo_search_user_daily_cap, default 100) and,
--                           on a cache miss, one Geoapify credit of the day
--                           (collector_budget geoapify_autocomplete,
--                           meta.geo_search_daily_cap, default 1500; staging
--                           300). The free tier is 3,000 credits a day, shared
--                           with places fill (500) and venue geocoding (300).
--        geo_search_store   service role: caches one answer.
--   3. Staging only: the private bucket prod-backups for backup.yml's
--      encrypted production dumps (age; service role only, no policies). On
--      production and on a fresh database this does nothing.
--   4. meta.schema_version 2.76.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Uptime alerts for moderators
-- ---------------------------------------------------------------------------
create or replace function public.ops_uptime_alert(p_failed integer default 1)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_now    timestamptz := now() at time zone 'UTC';
  v_window text;
begin
  -- Callers: the Management API (postgres) and the service role. Never a member.
  if (select auth.uid()) is not null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_window := to_char(v_now, 'YYYY-MM-DD') || 'T' || lpad((extract(hour from v_now)::integer / 6 * 6)::text, 2, '0');
  return private.notify_moderators('ops_alert', 'ops_alert:site_down:' || v_window,
    jsonb_build_object('alert', 'site_down', 'count', greatest(1, least(coalesce(p_failed, 1), 10))));
end $$;
comment on function public.ops_uptime_alert(integer) is
  'Migration 80, service role and the Management API (keepalive.yml uptime job, main only): one ops_alert {alert: site_down, count: failed checks} per active moderator and six-hour UTC window. Returns the notices added.';

-- ---------------------------------------------------------------------------
-- 2. Address and city search (geo-search Edge Function)
-- ---------------------------------------------------------------------------
create table if not exists public.geo_search_usage (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  day        date not null,
  used       integer not null default 0,
  primary key (user_id, day),
  constraint geo_search_usage_used_nonneg check (used >= 0)
);
comment on table public.geo_search_usage is
  'Migration 80: address and city searches per member and UTC day (geo-search Edge Function), for the per-member daily cap. Kept two days; removed when the account is deleted. No client access.';
alter table public.geo_search_usage enable row level security;
revoke all on public.geo_search_usage from public, anon, authenticated;
grant all on public.geo_search_usage to service_role;

create table if not exists public.geo_search_cache (
  key        text primary key,
  results    jsonb not null,
  created_at timestamptz not null default now(),
  constraint geo_search_cache_key_format check (key ~ '^[0-9a-f]{64}$'),
  constraint geo_search_cache_results_array check (jsonb_typeof(results) = 'array')
);
create index if not exists geo_search_cache_created_idx on public.geo_search_cache (created_at);
comment on table public.geo_search_cache is
  'Migration 80: geo-search answers (public geocoder fields only) by the sha256 of the normalized request (kind, text, rounded bias, language); no user reference. Kept 30 days. No client access.';
alter table public.geo_search_cache enable row level security;
revoke all on public.geo_search_cache from public, anon, authenticated;
grant all on public.geo_search_cache to service_role;

create or replace function public.geo_search_take(p_user_id uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_day     date := (now() at time zone 'UTC')::date;
  v_ucap    integer := private.email_meta_int('geo_search_user_daily_cap', 100);
  v_gcap    integer := private.email_meta_int('geo_search_daily_cap', 1500);
  v_used    integer;
  v_results jsonb;
begin
  if (select auth.uid()) is not null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_key is null or p_key !~ '^[0-9a-f]{64}$' then
    raise exception 'key_invalid' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p
                  where p.id = p_user_id and p.status = 'active' and p.deleted_at is null) then
    return jsonb_build_object('allowed', false, 'limit', 'user_not_found');
  end if;

  -- Old counters go (yesterday's stays for the day boundary).
  delete from public.geo_search_usage where day < v_day - 1;

  insert into public.geo_search_usage as u (user_id, day, used) values (p_user_id, v_day, 1)
  on conflict (user_id, day) do update set used = u.used + 1 where u.used < v_ucap
  returning u.used into v_used;
  if v_used is null then
    return jsonb_build_object('allowed', false, 'limit', 'user');
  end if;

  select c.results into v_results from public.geo_search_cache c
   where c.key = p_key and c.created_at > now() - interval '30 days';
  if v_results is not null then
    return jsonb_build_object('allowed', true, 'cached', v_results);
  end if;

  insert into public.collector_budget (day, source, used) values (v_day, 'geoapify_autocomplete', 0)
  on conflict (day, source) do nothing;
  update public.collector_budget set used = used + 1
   where day = v_day and source = 'geoapify_autocomplete' and used < v_gcap
  returning used into v_used;
  if not found then
    -- The member's search did not reach Geoapify; it does not count against them.
    update public.geo_search_usage set used = greatest(0, used - 1) where user_id = p_user_id and day = v_day;
    return jsonb_build_object('allowed', false, 'limit', 'global');
  end if;
  return jsonb_build_object('allowed', true);
end $$;
comment on function public.geo_search_take(uuid, text) is
  'Migration 80, service role (geo-search Edge Function): counts one search for an active member (meta.geo_search_user_daily_cap a UTC day, default 100). A cached answer (30 days) comes back as {allowed: true, cached}; otherwise one credit of collector_budget geoapify_autocomplete (meta.geo_search_daily_cap, default 1500) is taken: {allowed: true}. Over a cap: {allowed: false, limit: user | global | user_not_found}.';

create or replace function public.geo_search_store(p_key text, p_results jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_key is null or p_key !~ '^[0-9a-f]{64}$' then
    raise exception 'key_invalid' using errcode = '22023';
  end if;
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 10
     or octet_length(p_results::text) > 16384 then
    raise exception 'results_invalid' using errcode = '22023';
  end if;
  insert into public.geo_search_cache (key, results, created_at) values (p_key, p_results, now())
  on conflict (key) do update set results = excluded.results, created_at = excluded.created_at;
  delete from public.geo_search_cache
   where key in (select c.key from public.geo_search_cache c
                  where c.created_at < now() - interval '30 days' order by c.created_at limit 200);
end $$;
comment on function public.geo_search_store(text, jsonb) is
  'Migration 80, service role (geo-search Edge Function): caches one answer (an array of at most 10 results, 16 KB) by its request hash and drops up to 200 entries older than 30 days.';

-- Account deletion (D-031): the tombstoned profile is never hard-deleted, so the cascade above
-- does not fire; the counters go when the profile becomes deleted.
create or replace function private.geo_search_usage_forget()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.geo_search_usage where user_id = new.id;
  return null;
end $$;
comment on function private.geo_search_usage_forget() is
  'Migration 80, trigger: removes a member''s geo_search_usage rows when their profile becomes deleted (request_account_deletion).';
drop trigger if exists profiles_geo_search_usage_forget on public.profiles;
create trigger profiles_geo_search_usage_forget after update of status on public.profiles
  for each row when (new.status = 'deleted' and old.status is distinct from 'deleted')
  execute function private.geo_search_usage_forget();

-- Each project's share of the one Geoapify account (only where unset). project_url is set on both
-- projects by migrate.yml; a fresh database (the rehearsal) keeps the defaults.
do $$
begin
  if public.project_url() like '%gzrscndzzggxmcwnvvcq%' then
    insert into public.meta (key, value) values ('geo_search_daily_cap', '300') on conflict (key) do nothing;
    insert into public.meta (key, value) values ('geo_search_user_daily_cap', '60') on conflict (key) do nothing;
  elsif public.project_url() like '%gtesfiqxqontescqpllo%' then
    insert into public.meta (key, value) values ('geo_search_daily_cap', '1500') on conflict (key) do nothing;
    insert into public.meta (key, value) values ('geo_search_user_daily_cap', '100') on conflict (key) do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Staging only: the encrypted production backup bucket
-- ---------------------------------------------------------------------------
-- backup.yml uploads age-encrypted parts (at most 45 MB each, under the Free plan's 50 MB file
-- limit) as <stamp>/part-NNN plus <stamp>/SHA256SUMS and keeps the newest 14 stamps. No policy
-- names this bucket, so only the service role reaches it.
do $$
begin
  if public.project_url() like '%gzrscndzzggxmcwnvvcq%' and to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('prod-backups', 'prod-backups', false, 52428800, array['application/octet-stream', 'text/plain'])
    on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                                   allowed_mime_types = excluded.allowed_mime_types;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.ops_uptime_alert(integer) from public, anon, authenticated;
grant execute on function public.ops_uptime_alert(integer) to service_role;
revoke all on function public.geo_search_take(uuid, text) from public, anon, authenticated;
grant execute on function public.geo_search_take(uuid, text) to service_role;
revoke all on function public.geo_search_store(text, jsonb) from public, anon, authenticated;
grant execute on function public.geo_search_store(text, jsonb) to service_role;
revoke all on function private.geo_search_usage_forget() from public, anon, authenticated, service_role;

insert into public.meta (key, value) values ('schema_version', '2.76')
  on conflict (key) do update set value = excluded.value, updated_at = now();
