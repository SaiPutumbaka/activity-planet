-- ============================================================================
-- Activity Planet schema v2 — migration 46: discovered event sources and
--   member calendar suggestions (D-042 slice 7, docs/design/auto-coverage/
--   AUTO_COVERAGE_DESIGN.md 6.1 and 6.3). New tables and functions; one
--   existing function is rebuilt from its latest body (named below) and
--   changes only the lines marked "Migration 46".
--   Checks: supabase/tests/source_discovery.sql.
--
--   What this file does
--     1. collector_denylist: the D-040 denylist in the database (the same
--        entries as packages/collector/data/denylist.json, which a collector
--        test keeps in step), and collector_host_denied(host), the same match
--        as the collector's Denylist.hostDenied: a listed domain and its
--        subdomains, or a listed name as the site's own label under any
--        suffix (eventbrite.com, eventbrite.co.uk).
--     2. source_candidates: one row per candidate calendar site, deduplicated
--        by host globally (a leading www. is dropped), with its region, origin
--        (osm, wikidata, member), score, lifecycle status (discovered,
--        probation, enabled, paused, rejected, needs_permission), review
--        (none, or pending, approved, rejected for member suggestions),
--        reason, retry_after, run counters and the UTC days with a good run.
--        No user id: a member suggestion stores the URL and a count only.
--     3. source_probe_results: one row per probe or collector run of a
--        candidate (outcome, kind, platform, item counts, error count), kept
--        90 days. No user id.
--     4. feed_sources gains discovery_status (null for hand-written seeds)
--        and candidate_id; a discovered source's row has slug disc-<12 hex>,
--        collector = true, and is enabled only by the lifecycle.
--     5. place_rate_log takes kind 'calendar' (one row per suggestion), so a
--        member's 5 suggestions a day survive any later change to the row and
--        account deletion already removes them (migration 36).
--     6. source_url_check(p_url): the D-040 URL rules shared by the
--        suggestion RPC and the service-role adds. https only (http:// and
--        webcal:// read as https://, as the collector fetches), at most 500
--        characters, no user name or password, port 443 only, a public DNS
--        name (no IP literal, no localhost, .local, .internal and the like),
--        not denylisted; the fragment is dropped.
--     7. suggest_calendar(p_url), authenticated members (onboarded, active):
--        "Suggest a calendar". At most 5 a day per member (rate_limited) and
--        500 pending suggestions in all (queue_full). A new host becomes a
--        member candidate with review pending, in the collector region that
--        holds the member's saved home (else none); a host already known
--        (a candidate or a collector source) only counts the suggestion.
--        Returns {status: received | already_known}. Nothing a member
--        suggests is fetched until a moderator approves it.
--     8. mod_review_source_candidate(p_id, p_approve, p_reason), moderators:
--        approve (the probe may now read it) or reject (never probed).
--     9. Service role only, behind the collector Edge Function:
--        source_candidates_add(p_candidates) (POST /collector/candidates),
--        source_candidates_due(p_limit, p_regions) (GET /collector/candidates),
--        source_candidates_record(p_results) (POST /collector/sources/record:
--        the lifecycle, including the two-separate-days rule) and
--        collector_sources_for_regions(p_regions) (GET /collector/sources:
--        the probation and enabled sources of the given regions as seeds).
--        Automatic discovery stays off in the EU and EEA (and the UK, which
--        kept the same database right) while meta.eu_discovery is 'off':
--        osm and wikidata candidates there are never offered for probing;
--        member suggestions are.
--    10. collector_ingest_events (migration 39 body,
--        20261203000100_collector_images_licensed_fix.sql): p_enable (the
--        staging switch) leaves a discovered source (a disc- slug or a row
--        with a discovery_status) as the lifecycle set it, and a new disc-
--        row starts off; only source_candidates_record switches them.
--     * meta.eu_discovery 'off' (added once) and meta.schema_version 2.42.
--
--   Account deletion: source_candidates and source_probe_results hold no
--   user id. The only per-member row, place_rate_log kind 'calendar', is
--   already deleted by request_account_deletion (migration 36) and cascades
--   from profiles, so request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. collector_denylist and collector_host_denied
-- ---------------------------------------------------------------------------
create table if not exists public.collector_denylist (
  name       text not null,
  match      text not null default 'domain',
  reason     text not null,
  created_at timestamptz not null default now(),
  primary key (name, match),
  constraint collector_denylist_match check (match in ('domain', 'any_tld')),
  constraint collector_denylist_name_format check (name ~ '^[a-z0-9]([a-z0-9.-]{0,98}[a-z0-9])?$'),
  constraint collector_denylist_reason_length check (char_length(reason) between 1 and 200)
);
comment on table public.collector_denylist is
  'D-040 denylist (migration 46): sites whose terms forbid automated collection or that sit behind logins. match domain covers the domain and every subdomain; any_tld covers the name as the site''s own label under any suffix. Mirrors packages/collector/data/denylist.json (a collector test checks they agree). Used by source_url_check and the discovery lifecycle. Service role writes; moderators read.';

alter table public.collector_denylist enable row level security;
revoke all on public.collector_denylist from public, anon, authenticated;
grant select on public.collector_denylist to authenticated;   -- rows only through the moderator policy
grant all on public.collector_denylist to service_role;
drop policy if exists "collector_denylist_select_mod" on public.collector_denylist;
create policy "collector_denylist_select_mod" on public.collector_denylist for select to authenticated
  using ((select public.is_moderator()));

insert into public.collector_denylist (name, match, reason) values
  ('facebook.com', 'domain', 'Meta terms forbid automated collection; login wall'),
  ('fb.com', 'domain', 'Meta'),
  ('fb.me', 'domain', 'Meta short links'),
  ('instagram.com', 'domain', 'Meta terms forbid automated collection; login wall'),
  ('threads.net', 'domain', 'Meta terms forbid automated collection; login wall'),
  ('threads.com', 'domain', 'Meta (Threads)'),
  ('m.me', 'domain', 'Meta Messenger short links'),
  ('meetup.com', 'domain', 'Terms forbid scraping'),
  ('meetu.ps', 'domain', 'Meetup short links'),
  ('linkedin.com', 'domain', 'Terms forbid automated collection; litigates (D-004)'),
  ('lnkd.in', 'domain', 'LinkedIn short links'),
  ('joinhandshake.com', 'domain', 'Login wall; terms forbid automated collection (D-004)'),
  ('x.com', 'domain', 'Terms forbid automated collection'),
  ('twitter.com', 'domain', 'Terms forbid automated collection'),
  ('t.co', 'domain', 'X short links'),
  ('tiktok.com', 'domain', 'Terms forbid automated collection'),
  ('evbuc.com', 'domain', 'Eventbrite link and CDN domain'),
  ('eventbrite', 'any_tld', 'Terms forbid scraping; no free public search API'),
  ('ticketmaster', 'any_tld', 'Web pages are off limits; only the Discovery API'),
  ('livenation', 'any_tld', 'Ticketmaster group web pages'),
  ('seatgeek', 'any_tld', 'Web pages are off limits; only the Platform API'),
  ('nextdoor', 'any_tld', 'Login wall; terms forbid automated collection')
on conflict (name, match) do nothing;

create or replace function public.collector_host_denied(p_host text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  h      text := regexp_replace(lower(btrim(coalesce(p_host, ''))), '\.+$', '');
  labels text[];
  n      integer;
  site   text[];
  v      text;
begin
  if h = '' then
    return null;
  end if;
  select d.reason into v
    from public.collector_denylist d
   where d.match = 'domain' and (h = d.name or right(h, char_length(d.name) + 1) = '.' || d.name)
   order by char_length(d.name) desc
   limit 1;
  if v is not null then
    return v;
  end if;
  -- The site's own label (the collector's siteOf): the last two labels, or three
  -- under a two-letter second-level suffix (co.uk, com.au).
  labels := array(select l from unnest(string_to_array(h, '.')) l where l <> '');
  n := cardinality(labels);
  if n = 0 then
    return null;
  end if;
  if n <= 2 then
    site := labels;
  elsif char_length(labels[n]) = 2 and labels[n - 1] in ('co', 'com', 'org', 'net', 'gov', 'ac', 'edu') then
    site := labels[n - 2:n];
  else
    site := labels[n - 1:n];
  end if;
  select d.reason into v from public.collector_denylist d where d.match = 'any_tld' and d.name = site[1];
  return v;
end $$;
comment on function public.collector_host_denied(text) is
  'D-040 (migration 46): the denylist reason for a host, or null. Same match as the collector''s Denylist.hostDenied: a listed domain or any subdomain, or a listed any_tld name as the site''s own label. Internal (service role and definer functions).';

-- ---------------------------------------------------------------------------
-- 2. source_candidates
-- ---------------------------------------------------------------------------
create table if not exists public.source_candidates (
  id             uuid primary key default gen_random_uuid(),
  host           text not null,
  url            text not null,
  region_id      uuid references public.collector_regions (id) on delete set null,
  origin         text not null,
  name           text,
  place_kind     text,
  wikidata_id    text,
  country        text,
  score          smallint not null default 0,
  status         text not null default 'discovered',
  review_status  text not null default 'none',
  reason         text,
  locked         boolean not null default false,
  retry_after    timestamptz,
  feed_kind      text,
  feed_url       text,
  platform       text,
  ok_runs        integer not null default 0,
  empty_runs     integer not null default 0,
  error_runs     integer not null default 0,
  ok_days        smallint not null default 0,
  last_ok_on     date,
  empty_since    date,
  suggest_count  integer not null default 0,
  last_probe_at  timestamptz,
  status_at      timestamptz not null default now(),
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint source_candidates_host_key unique (host),
  constraint source_candidates_host_format check (host ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' and char_length(host) <= 253),
  constraint source_candidates_url_https check (url ~ '^https://' and char_length(url) <= 500),
  constraint source_candidates_origin check (origin in ('osm', 'wikidata', 'member')),
  constraint source_candidates_name_length check (name is null or char_length(name) between 2 and 80),
  constraint source_candidates_place_kind_format check (place_kind is null or place_kind ~ '^[a-z0-9_]{1,40}$'),
  constraint source_candidates_wikidata_format check (wikidata_id is null or wikidata_id ~ '^Q[1-9][0-9]{0,11}$'),
  constraint source_candidates_country_format check (country is null or country ~ '^[A-Z]{2}$'),
  constraint source_candidates_score_range check (score between 0 and 100),
  constraint source_candidates_status check (status in ('discovered', 'probation', 'enabled', 'paused', 'rejected', 'needs_permission')),
  constraint source_candidates_review check (review_status in ('none', 'pending', 'approved', 'rejected')),
  constraint source_candidates_member_review check ((origin = 'member') = (review_status <> 'none')),
  constraint source_candidates_reason_length check (reason is null or char_length(reason) <= 200),
  constraint source_candidates_feed_kind check (feed_kind is null or feed_kind in ('ics', 'rss', 'page')),
  constraint source_candidates_feed_url_https check (feed_url is null or (feed_url ~ '^https://' and char_length(feed_url) <= 500)),
  constraint source_candidates_platform_format check (platform is null or platform ~ '^[a-z0-9_]{1,40}$'),
  constraint source_candidates_counts_nonneg check (ok_runs >= 0 and empty_runs >= 0 and error_runs >= 0 and ok_days >= 0 and suggest_count >= 0),
  constraint source_candidates_enabled_two_days check (status <> 'enabled' or ok_days >= 2),
  constraint source_candidates_live_has_feed check (status not in ('probation', 'enabled') or (feed_url is not null and feed_kind is not null)),
  constraint source_candidates_member_approved check (status not in ('probation', 'enabled') or review_status in ('none', 'approved'))
);
create index if not exists source_candidates_region_idx on public.source_candidates (region_id, status);
create index if not exists source_candidates_queue_idx on public.source_candidates (status, retry_after, score desc);
create index if not exists source_candidates_review_idx on public.source_candidates (created_at) where review_status = 'pending';
comment on table public.source_candidates is
  'Candidate calendar sites for automatic event discovery (D-042 slice 7, design 6.1 and 6.3), one per host worldwide (leading www. dropped). origin osm, wikidata or member ("Suggest a calendar"; review pending until a moderator approves, and never fetched before). status: discovered (waiting for a probe), probation (one UTC day with a good run), enabled (good runs on two separate UTC days: its feed_sources row is on), paused (3 empty runs; retried weekly), rejected (retry_after says when it may be probed again; null is never), needs_permission (Localist and the like: never automatic). locked is a removal request or the denylist: never reopened. No user id; suggest_count counts member suggestions. Written by the definer functions of migration 46; moderators read.';
comment on column public.source_candidates.ok_days is
  'UTC days with at least one good run (at least 1 valid in-window item inside the region, a complete read, under 20% errors). Two are needed to enable (design 6.3); a second good run on the same day does not count.';
create or replace trigger source_candidates_set_updated_at before update on public.source_candidates
  for each row execute function public.set_updated_at();

alter table public.source_candidates enable row level security;
revoke all on public.source_candidates from public, anon, authenticated;
grant select on public.source_candidates to authenticated;   -- rows only through the moderator policy
grant all on public.source_candidates to service_role;
drop policy if exists "source_candidates_select_mod" on public.source_candidates;
create policy "source_candidates_select_mod" on public.source_candidates for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 3. source_probe_results
-- ---------------------------------------------------------------------------
create table if not exists public.source_probe_results (
  id           bigint generated always as identity primary key,
  candidate_id uuid not null references public.source_candidates (id) on delete cascade,
  run_id       text not null,
  run_on       date not null default (now() at time zone 'UTC')::date,
  outcome      text not null,
  good         boolean not null default false,
  feed_kind    text,
  platform     text,
  items        integer,
  in_region    integer,
  requests     integer,
  errors       integer,
  complete     boolean,
  created_at   timestamptz not null default now(),
  constraint source_probe_results_run_key unique (candidate_id, run_id),
  constraint source_probe_results_run_id_format check (run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'),
  constraint source_probe_results_outcome check (outcome in ('ok', 'empty', 'no_feed', 'error', 'blocked', 'robots', 'noindex', 'needs_permission', 'denylisted')),
  constraint source_probe_results_feed_kind check (feed_kind is null or feed_kind in ('ics', 'rss', 'page')),
  constraint source_probe_results_platform_format check (platform is null or platform ~ '^[a-z0-9_]{1,40}$'),
  constraint source_probe_results_counts_nonneg check (coalesce(items, 0) >= 0 and coalesce(in_region, 0) >= 0 and coalesce(requests, 0) >= 0 and coalesce(errors, 0) >= 0)
);
create index if not exists source_probe_results_created_idx on public.source_probe_results (created_at);
comment on table public.source_probe_results is
  'One row per probe or collector run of a discovered source (D-042 slice 7): outcome, whether it was a good run, feed kind, platform, counts. Written by source_candidates_record; kept 90 days. No user id, no item text. Moderators read.';

alter table public.source_probe_results enable row level security;
revoke all on public.source_probe_results from public, anon, authenticated;
grant select on public.source_probe_results to authenticated;
grant all on public.source_probe_results to service_role;
drop policy if exists "source_probe_results_select_mod" on public.source_probe_results;
create policy "source_probe_results_select_mod" on public.source_probe_results for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 4. feed_sources: discovery_status and candidate_id
-- ---------------------------------------------------------------------------
alter table public.feed_sources add column if not exists discovery_status text;
alter table public.feed_sources add column if not exists candidate_id uuid;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_discovery_status
    check (discovery_status is null or discovery_status in ('discovered', 'probation', 'enabled', 'paused', 'rejected', 'needs_permission'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_candidate_fk
    foreign key (candidate_id) references public.source_candidates (id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_discovered_enabled
    check (not enabled or discovery_status is null or discovery_status = 'enabled');
exception when duplicate_object then null; end $$;
create unique index if not exists feed_sources_candidate_key on public.feed_sources (candidate_id) where candidate_id is not null;
comment on column public.feed_sources.discovery_status is
  'Discovered sources only (D-042 slice 7): the candidate''s lifecycle status. Null for hand-written seeds, API sources and import-feed sources. A discovered source can be enabled only while this is enabled.';
comment on column public.feed_sources.candidate_id is
  'The source_candidates row a discovered source came from (slug disc-<12 hex of its id>).';

-- ---------------------------------------------------------------------------
-- 5. place_rate_log: kind 'calendar'
-- ---------------------------------------------------------------------------
alter table public.place_rate_log drop constraint if exists place_rate_log_kind;
alter table public.place_rate_log add constraint place_rate_log_kind check (kind in ('add', 'edit', 'calendar'));
comment on table public.place_rate_log is
  'Member rate limits (D-041 design 7 rule 9, migration 36; D-042 slice 7, migration 46): one row per member place added (add), per place edit (edit) and per calendar suggestion (calendar), kept a day. add_place, places_guard, suggest_place_edit and suggest_calendar count it. No client access; removed on account deletion.';

-- ---------------------------------------------------------------------------
-- 6. source_url_check
-- ---------------------------------------------------------------------------
create or replace function public.source_url_check(p_url text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s     text := btrim(coalesce(p_url, ''));
  auth  text;
  host  text;
  port  text;
  rest  text;
  tld   text;
  v_why text;
begin
  if s = '' then
    return jsonb_build_object('ok', false, 'error', 'url_invalid');
  end if;
  if char_length(s) > 500 then
    return jsonb_build_object('ok', false, 'error', 'url_too_long');
  end if;
  if s ~ '[[:space:][:cntrl:]]' then
    return jsonb_build_object('ok', false, 'error', 'url_invalid');
  end if;
  -- The collector reads webcal:// as https:// and upgrades http:// (it fetches over TLS only).
  s := regexp_replace(s, '^(webcals?|https?)://', 'https://', 'i');
  if s !~ '^https://' then
    return jsonb_build_object('ok', false, 'error', 'url_not_https');
  end if;
  auth := substring(s from '^https://([^/?#]*)');
  rest := regexp_replace(substring(s from '^https://[^/?#]*(.*)$'), '#.*$', '');
  if auth like '%@%' then
    return jsonb_build_object('ok', false, 'error', 'url_has_credentials');
  end if;
  if auth like '[%' then
    return jsonb_build_object('ok', false, 'error', 'url_private_host');
  end if;
  host := lower(auth);
  if host ~ ':' then
    port := substring(host from ':([^:]*)$');
    host := substring(host from '^([^:]*)');
    if port is distinct from '443' and port is distinct from '' then
      return jsonb_build_object('ok', false, 'error', 'url_port');
    end if;
  end if;
  host := regexp_replace(host, '\.+$', '');
  if host ~ '^[0-9.]+$' or host ~ '^0x' then
    return jsonb_build_object('ok', false, 'error', 'url_private_host');
  end if;
  if char_length(host) > 253
     or host !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' then
    return jsonb_build_object('ok', false, 'error', case when host ~ '\.' then 'url_invalid' else 'url_private_host' end);
  end if;
  tld := substring(host from '([^.]+)$');
  if tld in ('local', 'localhost', 'localdomain', 'internal', 'intranet', 'lan', 'home', 'corp', 'private',
             'arpa', 'test', 'example', 'invalid', 'onion', 'alt')
     or host ~ '(^|\.)(localhost|example\.(com|net|org))$' then
    return jsonb_build_object('ok', false, 'error', 'url_private_host');
  end if;
  v_why := public.collector_host_denied(host);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'error', 'url_denylisted', 'reason', v_why);
  end if;
  if rest = '' or left(rest, 1) = '?' then
    rest := '/' || rest;
  end if;
  return jsonb_build_object('ok', true, 'url', 'https://' || host || rest,
                            'host', regexp_replace(host, '^www\.', ''));
end $$;
comment on function public.source_url_check(text) is
  'D-040 URL rules for a candidate calendar (migration 46): {ok, url, host} or {ok: false, error, reason?}. https only (http:// and webcal:// read as https://), at most 500 characters, no spaces, no user name or password (url_has_credentials), port 443 only (url_port), a public DNS name (url_private_host for IP literals, localhost, .local, .internal, .onion and the like), not denylisted (url_denylisted with the reason). The fragment is dropped; host is the dedupe key (lower case, no leading www.). Internal.';

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
-- The host of a stored https URL, as source_candidates keys it.
create or replace function public.source_url_host(p_url text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(regexp_replace(lower(substring(p_url from '^https://([^/?#:@]+)')), '\.+$', ''), '^www\.', '');
$$;
comment on function public.source_url_host(text) is
  'The dedupe host of an https URL (lower case, no port, no leading www.). Internal (migration 46).';

-- The feed_sources slug of a discovered source.
create or replace function public.source_candidate_slug(p_id uuid)
returns text language sql immutable set search_path = '' as $$
  select 'disc-' || substr(replace(p_id::text, '-', ''), 1, 12);
$$;
comment on function public.source_candidate_slug(uuid) is
  'The feed_sources slug (and collector seed id) of a discovered source: disc-<first 12 hex of the candidate id>. Internal (migration 46).';

-- Whether automatic discovery may probe a candidate from this country.
create or replace function public.source_discovery_allowed(p_origin text, p_country text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_origin = 'member'
      or coalesce((select m.value from public.meta m where m.key = 'eu_discovery'), 'off') = 'on'
      or p_country is null
      or p_country not in ('AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR', 'HU', 'IE',
                           'IT', 'LV', 'LT', 'LU', 'MT', 'NL', 'PL', 'PT', 'RO', 'SK', 'SI', 'ES', 'SE',
                           'IS', 'LI', 'NO', 'GB');
$$;
comment on function public.source_discovery_allowed(text, text) is
  'D-042 EU gate (migration 46): automatic (osm, wikidata) candidates in the EU, the EEA and the UK are not probed while meta.eu_discovery is off (the attorney read on the database right, FOUNDER-TODO item 12). Member suggestions are always allowed. Internal.';

insert into public.meta (key, value) values ('eu_discovery', 'off')
  on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 7. suggest_calendar
-- ---------------------------------------------------------------------------
create or replace function public.suggest_calendar(p_url text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_chk    jsonb;
  v_host   text;
  v_url    text;
  v_region uuid;
  v_home   extensions.geography;
  v_known  boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_chk := public.source_url_check(p_url);
  if not (v_chk ->> 'ok')::boolean then
    raise exception '%', v_chk ->> 'error' using errcode = 'check_violation', hint = coalesce(v_chk ->> 'reason', '');
  end if;
  v_url := v_chk ->> 'url';
  v_host := v_chk ->> 'host';

  -- One member at a time, so two quick taps cannot both pass the limit.
  perform pg_advisory_xact_lock(hashtextextended('suggest_calendar:' || uid::text, 0));
  delete from public.place_rate_log
   where user_id = uid and kind = 'calendar' and created_at < now() - interval '1 day';
  if (select count(*) from public.place_rate_log
       where user_id = uid and kind = 'calendar' and created_at > now() - interval '1 day') >= 5 then
    raise exception 'rate_limited' using errcode = 'check_violation';
  end if;

  v_known := exists (select 1 from public.source_candidates c where c.host = v_host)
          or exists (select 1 from public.feed_sources f where public.source_url_host(f.url) = v_host
                                                            or public.source_url_host(f.homepage_url) = v_host);
  if not v_known then
    if (select count(*) from public.source_candidates c where c.review_status = 'pending') >= 500 then
      raise exception 'queue_full' using errcode = 'check_violation';
    end if;
    select pp.home_point into v_home from public.profile_private pp where pp.user_id = uid;
    if v_home is not null then
      select r.id into v_region
        from public.collector_regions r
       where extensions.ST_DWithin(r.point, v_home, r.radius_km * 1000.0)
       order by extensions.ST_Distance(r.point, v_home), r.id
       limit 1;
    end if;
    insert into public.source_candidates (host, url, region_id, origin, review_status, suggest_count)
    values (v_host, v_url, v_region, 'member', 'pending', 1)
    on conflict (host) do update set suggest_count = public.source_candidates.suggest_count + 1;
  else
    update public.source_candidates set suggest_count = suggest_count + 1 where host = v_host;
  end if;

  insert into public.place_rate_log (user_id, kind) values (uid, 'calendar');
  return jsonb_build_object('status', case when v_known then 'already_known' else 'received' end, 'host', v_host);
end $$;
comment on function public.suggest_calendar(text) is
  '"Suggest a calendar" (D-042 slice 7, design 6.1 item 3), for onboarded active members. Checks the URL with source_url_check (errors url_invalid, url_too_long, url_not_https, url_has_credentials, url_port, url_private_host, url_denylisted with the reason as hint), then allows 5 a day per member (rate_limited; place_rate_log kind calendar) and 500 pending suggestions in all (queue_full). A new host becomes a member candidate, review pending, in the collector region holding the member''s saved home (else none); a known host (candidate or collector source) only counts the suggestion. Stores the URL, never who suggested it. Returns {status: received | already_known, host}.';

-- ---------------------------------------------------------------------------
-- 8. mod_review_source_candidate
-- ---------------------------------------------------------------------------
create or replace function public.mod_review_source_candidate(p_id uuid, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_row public.source_candidates%rowtype;
  v_why text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not coalesce(public.is_moderator(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_approve is null then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  select * into v_row from public.source_candidates where id = p_id for update;
  if not found or v_row.origin <> 'member' then
    raise exception 'invalid_item' using errcode = 'check_violation';
  end if;
  if v_row.review_status <> 'pending' then
    raise exception 'item_not_pending' using errcode = 'check_violation';
  end if;
  if p_approve then
    update public.source_candidates
       set review_status = 'approved', reviewed_at = now(), reason = null
     where id = p_id;
  else
    update public.source_candidates
       set review_status = 'rejected', reviewed_at = now(), status = 'rejected', status_at = now(),
           retry_after = null, reason = coalesce(v_why, 'moderator')
     where id = p_id;
  end if;
  return jsonb_build_object('id', p_id, 'review_status', case when p_approve then 'approved' else 'rejected' end);
end $$;
comment on function public.mod_review_source_candidate(uuid, boolean, text) is
  'Moderators (D-042 slice 7): decide a pending member calendar suggestion. Approve lets the probe read it (it stays discovered until a probe and two good days enable it); reject marks it rejected for good (never probed). Errors: not_authenticated, forbidden, invalid_action, invalid_item, item_not_pending.';

-- ---------------------------------------------------------------------------
-- 9a. source_candidates_add (service role)
-- ---------------------------------------------------------------------------
create or replace function public.source_candidates_add(p_candidates jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c        jsonb;
  v_chk    jsonb;
  v_origin text;
  v_region uuid;
  v_name   text;
  v_kind   text;
  v_wd     text;
  v_cc     text;
  v_score  integer;
  v_added  integer := 0;
  v_known  integer := 0;
  v_denied integer := 0;
  v_bad    integer := 0;
  v_ins    boolean;
begin
  if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' or jsonb_array_length(p_candidates) > 500 then
    raise exception 'candidates_invalid' using errcode = 'check_violation';
  end if;
  for c in select value from jsonb_array_elements(p_candidates) loop
    if jsonb_typeof(c) <> 'object' then
      v_bad := v_bad + 1;
      continue;
    end if;
    v_origin := c ->> 'origin';
    if v_origin is null or v_origin not in ('osm', 'wikidata') then
      v_bad := v_bad + 1;
      continue;
    end if;
    v_chk := public.source_url_check(c ->> 'url');
    if not (v_chk ->> 'ok')::boolean then
      if v_chk ->> 'error' = 'url_denylisted' then v_denied := v_denied + 1; else v_bad := v_bad + 1; end if;
      continue;
    end if;
    v_region := null;
    if c ->> 'region_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      select r.id into v_region from public.collector_regions r where r.id = (c ->> 'region_id')::uuid;
    end if;
    v_name := nullif(left(btrim(coalesce(c ->> 'name', '')), 80), '');
    if v_name is not null and char_length(v_name) < 2 then v_name := null; end if;
    v_kind := case when c ->> 'place_kind' ~ '^[a-z0-9_]{1,40}$' then c ->> 'place_kind' end;
    v_wd := case when c ->> 'wikidata_id' ~ '^Q[1-9][0-9]{0,11}$' then c ->> 'wikidata_id' end;
    v_cc := case when c ->> 'country' ~ '^[A-Z]{2}$' then c ->> 'country' end;
    v_score := case when jsonb_typeof(c -> 'score') = 'number' then least(100, greatest(0, round((c ->> 'score')::numeric)))::integer else 0 end;
    insert into public.source_candidates (host, url, region_id, origin, name, place_kind, wikidata_id, country, score)
    values (v_chk ->> 'host', v_chk ->> 'url', v_region, v_origin, v_name, v_kind, v_wd, v_cc, v_score)
    on conflict (host) do update
      set score = greatest(public.source_candidates.score, excluded.score),
          region_id = coalesce(public.source_candidates.region_id, excluded.region_id),
          name = coalesce(public.source_candidates.name, excluded.name),
          place_kind = coalesce(public.source_candidates.place_kind, excluded.place_kind),
          wikidata_id = coalesce(public.source_candidates.wikidata_id, excluded.wikidata_id),
          country = coalesce(public.source_candidates.country, excluded.country)
    returning (xmax = 0) into v_ins;
    if v_ins then
      v_added := v_added + 1;
    else
      v_known := v_known + 1;
    end if;
  end loop;
  return jsonb_build_object('added', v_added, 'known', v_known, 'denied', v_denied, 'invalid', v_bad);
end $$;
comment on function public.source_candidates_add(jsonb) is
  'Service role (D-042 slice 7; POST /collector/candidates): adds osm and wikidata candidates [{url, origin, region_id?, name?, place_kind?, wikidata_id?, country?, score?}] (at most 500), one per host worldwide; a known host keeps its row (the higher score, and region, name, kind, Wikidata id and country where they were empty). URLs go through source_url_check. Returns counts added, known, denied (denylist) and invalid. Error: candidates_invalid.';

-- ---------------------------------------------------------------------------
-- 9b. source_candidates_due (service role)
-- ---------------------------------------------------------------------------
create or replace function public.source_candidates_due(p_limit integer default 150, p_regions uuid[] default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'url', q.url, 'host', q.host, 'origin', q.origin, 'region_id', q.region_id,
           'name', q.name, 'place_kind', q.place_kind, 'wikidata_id', q.wikidata_id, 'country', q.country,
           'score', q.score, 'status', q.status) order by q.ord), '[]'::jsonb)
    from (select c.*, row_number() over (order by c.score desc, c.created_at, c.id) as ord
            from public.source_candidates c
           where not c.locked
             and c.review_status in ('none', 'approved')
             and (c.status = 'discovered' or (c.status = 'rejected' and c.retry_after is not null))
             and (c.retry_after is null or c.retry_after <= now())
             and (p_regions is null or c.region_id = any (p_regions))
             and public.source_discovery_allowed(c.origin, c.country)
             and public.collector_host_denied(c.host) is null
           order by c.score desc, c.created_at, c.id
           limit least(500, greatest(1, coalesce(p_limit, 150)))) q;
$$;
comment on function public.source_candidates_due(integer, uuid[]) is
  'Service role (D-042 slice 7; GET /collector/candidates): candidates to probe, by score: discovered ones and rejected ones whose retry_after has passed, not locked, member suggestions only once approved, not denylisted, and not osm or wikidata candidates in the EU, EEA or UK while meta.eu_discovery is off. Optional region filter; at most 500. No user ids.';

-- ---------------------------------------------------------------------------
-- 9c. source_candidates_record (service role): the lifecycle
-- ---------------------------------------------------------------------------
create or replace function public.source_candidates_record(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r          jsonb;
  v_c        public.source_candidates%rowtype;
  v_today    date := (now() at time zone 'UTC')::date;
  v_id       uuid;
  v_run      text;
  v_out      text;
  v_kind     text;
  v_url      text;
  v_plat     text;
  v_items    integer;
  v_inreg    integer;
  v_req      integer;
  v_err      integer;
  v_complete boolean;
  v_good     boolean;
  v_status   text;
  v_reason   text;
  v_retry    timestamptz;
  v_lock     boolean;
  v_slug     text;
  v_name     text;
  v_attr     text;
  v_rpoint   extensions.geography;
  v_rradius  smallint;
  v_rlabel   text;
  v_rtz      text;
  v_chk      jsonb;
  v_counts   jsonb := jsonb_build_object('recorded', 0, 'repeat', 0, 'skipped', 0, 'unknown', 0,
                                         'probation', 0, 'enabled', 0, 'paused', 0, 'rejected', 0);
  v_int      text := '^[0-9]{1,7}$';
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 500 then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;
  -- Every entry is checked before anything is written.
  if exists (select 1 from jsonb_array_elements(p_results) e
              where jsonb_typeof(e.value) <> 'object'
                 or coalesce(e.value ->> 'candidate_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                 or coalesce(e.value ->> 'run_id', '') !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'
                 or coalesce(e.value ->> 'outcome', '') not in ('ok', 'empty', 'no_feed', 'error', 'blocked', 'robots', 'noindex', 'needs_permission', 'denylisted')
                 or (e.value ? 'kind' and jsonb_typeof(e.value -> 'kind') <> 'null' and coalesce(e.value ->> 'kind', '') not in ('ics', 'rss', 'page'))
                 or (e.value ? 'platform' and jsonb_typeof(e.value -> 'platform') <> 'null' and coalesce(e.value ->> 'platform', '') !~ '^[a-z0-9_]{1,40}$')
                 or (e.value ? 'complete' and jsonb_typeof(e.value -> 'complete') not in ('boolean', 'null'))
                 or exists (select 1 from unnest(array['items', 'in_region', 'requests', 'errors']) k
                             where e.value ? k and jsonb_typeof(e.value -> k) <> 'null'
                               and (jsonb_typeof(e.value -> k) <> 'number' or (e.value ->> k) !~ v_int))) then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;

  delete from public.source_probe_results where created_at < now() - interval '90 days';

  for r in select value from jsonb_array_elements(p_results) loop
    v_id := (r ->> 'candidate_id')::uuid;
    v_run := r ->> 'run_id';
    select * into v_c from public.source_candidates where id = v_id for update;
    if not found then
      v_counts := jsonb_set(v_counts, '{unknown}', to_jsonb((v_counts ->> 'unknown')::int + 1));
      continue;
    end if;
    if exists (select 1 from public.source_probe_results p where p.candidate_id = v_id and p.run_id = v_run) then
      v_counts := jsonb_set(v_counts, '{repeat}', to_jsonb((v_counts ->> 'repeat')::int + 1));
      continue;
    end if;
    -- Locked, moderator-rejected, unapproved and needs_permission rows take no results.
    if v_c.locked or v_c.status = 'needs_permission' or v_c.review_status in ('pending', 'rejected') then
      v_counts := jsonb_set(v_counts, '{skipped}', to_jsonb((v_counts ->> 'skipped')::int + 1));
      continue;
    end if;

    v_out := r ->> 'outcome';
    v_kind := nullif(r ->> 'kind', '');
    v_plat := nullif(r ->> 'platform', '');
    v_items := (r ->> 'items')::integer;
    v_inreg := (r ->> 'in_region')::integer;
    v_req := (r ->> 'requests')::integer;
    v_err := (r ->> 'errors')::integer;
    v_complete := coalesce((r ->> 'complete')::boolean, true);
    v_url := null;
    if r ? 'url' and jsonb_typeof(r -> 'url') = 'string' then
      v_chk := public.source_url_check(r ->> 'url');
      -- A feed on another host (a calendar vendor) is fine; source_url_check applied the denylist.
      if (v_chk ->> 'ok')::boolean then
        v_url := v_chk ->> 'url';
      elsif v_chk ->> 'error' = 'url_denylisted' then
        v_out := 'denylisted';
      end if;
    end if;
    if public.collector_host_denied(v_c.host) is not null then
      v_out := 'denylisted';
    end if;

    -- A good run (design 6.3): valid in-window items inside the region, a complete read, under
    -- 20% errors, and a feed to read next time.
    v_good := v_out = 'ok' and coalesce(v_items, 0) >= 1 and coalesce(v_inreg, 0) >= 1 and v_complete
              and (coalesce(v_req, 0) = 0 or coalesce(v_err, 0)::numeric / v_req < 0.2)
              and coalesce(v_kind, v_c.feed_kind) is not null and coalesce(v_url, v_c.feed_url) is not null;
    if v_out = 'ok' and not v_good then
      v_out := case when coalesce(v_inreg, 0) = 0 or coalesce(v_items, 0) = 0 then 'empty' else 'error' end;
    end if;

    insert into public.source_probe_results
      (candidate_id, run_id, run_on, outcome, good, feed_kind, platform, items, in_region, requests, errors, complete)
    values (v_id, v_run, v_today, v_out, v_good, v_kind, v_plat, v_items, v_inreg, v_req, v_err, v_complete);

    v_status := v_c.status;
    v_reason := v_c.reason;
    v_retry := v_c.retry_after;
    v_lock := false;

    if v_good then
      v_c.ok_runs := v_c.ok_runs + 1;
      v_c.empty_runs := 0;
      v_c.empty_since := null;
      v_c.feed_kind := coalesce(v_kind, v_c.feed_kind);
      v_c.feed_url := coalesce(v_url, v_c.feed_url);
      v_c.platform := coalesce(v_plat, v_c.platform);
      -- Two separate UTC days: a second good run on the same day does not count.
      if v_c.last_ok_on is distinct from v_today then
        v_c.ok_days := least(32000, v_c.ok_days + 1);
        v_c.last_ok_on := v_today;
      end if;
      v_reason := null;
      v_retry := null;
      if v_c.ok_days >= 2 then
        -- At most 40 enabled discovered sources a region (design 7).
        if v_c.status <> 'enabled' and v_c.region_id is not null
           and (select count(*) from public.source_candidates x
                 where x.region_id = v_c.region_id and x.status = 'enabled' and x.id <> v_id) >= 40 then
          v_status := 'probation';
          v_reason := 'region_cap';
        else
          v_status := 'enabled';
        end if;
      else
        v_status := 'probation';
      end if;
    elsif v_out in ('empty', 'no_feed') then
      v_c.empty_runs := v_c.empty_runs + 1;
      v_c.empty_since := coalesce(v_c.empty_since, v_today);
      if v_c.status in ('discovered', 'rejected') then
        v_status := 'rejected';
        v_reason := case when v_out = 'no_feed' then 'no_feed' else 'no_events_in_region' end;
        v_retry := now() + interval '30 days';
      elsif v_today - v_c.empty_since >= 30 then
        v_status := 'rejected';
        v_reason := 'empty_30_days';
        v_retry := now() + interval '30 days';
      elsif v_c.empty_runs >= 3 then
        v_status := 'paused';
        v_reason := 'empty_runs';
        v_retry := now() + interval '7 days';
      end if;
    elsif v_out = 'error' then
      v_c.error_runs := v_c.error_runs + 1;
      if v_c.status in ('discovered', 'rejected') and v_c.error_runs >= 3 then
        v_status := 'rejected';
        v_reason := 'errors';
        v_retry := now() + interval '30 days';
      end if;
    elsif v_out = 'blocked' then
      -- 401, 403 or a bot challenge: rejected at once, never retried automatically.
      v_status := 'rejected';
      v_reason := 'blocked';
      v_retry := null;
    elsif v_out in ('robots', 'noindex') then
      v_status := 'rejected';
      v_reason := v_out;
      v_retry := now() + interval '30 days';
    elsif v_out = 'needs_permission' then
      v_status := 'needs_permission';
      v_reason := coalesce(v_plat, 'needs_permission');
      v_retry := null;
    elsif v_out = 'denylisted' then
      v_status := 'rejected';
      v_reason := 'denylisted';
      v_retry := null;
      v_lock := true;
    end if;
    if v_status = 'rejected' and v_c.status <> 'rejected' then
      v_c.ok_days := 0;
      v_c.last_ok_on := null;
    end if;

    update public.source_candidates
       set status = v_status, reason = v_reason, retry_after = v_retry, locked = locked or v_lock,
           status_at = case when v_status is distinct from status then now() else status_at end,
           ok_runs = v_c.ok_runs, empty_runs = v_c.empty_runs, error_runs = v_c.error_runs,
           ok_days = v_c.ok_days, last_ok_on = v_c.last_ok_on, empty_since = v_c.empty_since,
           feed_kind = v_c.feed_kind, feed_url = v_c.feed_url, platform = v_c.platform,
           last_probe_at = now()
     where id = v_id;

    -- The feed_sources row: created at probation (off), on only while enabled.
    v_slug := public.source_candidate_slug(v_id);
    if v_status in ('probation', 'enabled') and not exists (select 1 from public.feed_sources f where f.candidate_id = v_id) then
      v_name := coalesce(v_c.name, left(v_c.host, 80));
      v_attr := left(case when v_name = v_c.host then 'Events from ' || v_c.host
                          else 'Events from ' || v_name || ' (' || v_c.host || ')' end, 300);
      v_rpoint := null; v_rradius := null; v_rlabel := null; v_rtz := null;
      if v_c.region_id is not null then
        select g.point, g.radius_km, g.label, g.timezone into v_rpoint, v_rradius, v_rlabel, v_rtz
          from public.collector_regions g where g.id = v_c.region_id;
      end if;
      if not exists (select 1 from public.feed_sources f where f.slug = v_slug) then
        insert into public.feed_sources
          (slug, kind, url, name, attribution, homepage_url, enabled, collector, lane,
           region_point, region_radius_km, region_label, region_timezone, discovered_from,
           discovery_status, candidate_id)
        values
          (v_slug, case v_c.feed_kind when 'page' then 'jsonld' else v_c.feed_kind end, v_c.feed_url,
           case when char_length(v_name) < 2 then v_c.host else v_name end,
           case when char_length(v_attr) < 10 then 'Events from ' || v_c.host || ' (public calendar)' else v_attr end,
           'https://' || v_c.host || '/', false, true, case v_c.feed_kind when 'page' then 'page' else 'feed' end,
           v_rpoint, v_rradius, v_rlabel, v_rtz, v_c.url,
           v_status, v_id);
      end if;
    end if;
    update public.feed_sources
       set discovery_status = v_status,
           enabled = v_status = 'enabled' and not denylisted
     where candidate_id = v_id
       and (discovery_status is distinct from v_status or enabled is distinct from (v_status = 'enabled' and not denylisted));
    if v_lock then
      update public.feed_sources set enabled = false, denylisted = true where candidate_id = v_id;
    end if;

    v_counts := jsonb_set(v_counts, '{recorded}', to_jsonb((v_counts ->> 'recorded')::int + 1));
    if v_status in ('probation', 'enabled', 'paused', 'rejected') and v_status is distinct from v_c.status then
      v_counts := jsonb_set(v_counts, array[v_status], to_jsonb((v_counts ->> v_status)::int + 1));
    end if;
  end loop;
  return v_counts;
end $$;
comment on function public.source_candidates_record(jsonb) is
  'Service role (D-042 slice 7; POST /collector/sources/record): the discovery lifecycle (design 6.3) from probe or nightly-run results [{candidate_id, run_id, outcome ok|empty|no_feed|error|blocked|robots|noindex|needs_permission|denylisted, kind? ics|rss|page, url?, platform?, items?, in_region?, requests?, errors?, complete?}] (at most 500; all checked before any write). A good run (ok with at least 1 in-window item inside the region, complete, under 20% errors) counts its UTC day once: one day is probation (a feed_sources row disc-<id>, off), good runs on two separate days enable it (at most 40 enabled a region, else probation with reason region_cap). Empty or no feed: a not yet live candidate is rejected (retry in 30 days); a live one pauses after 3 empty runs (retry weekly) and is rejected after 30 empty days. 401/403/bot challenge: rejected at once, never retried; robots or noindex: rejected, retry in 30 days; Localist and the like: needs_permission; denylisted: rejected and locked. Rejection resets the good days. A second result for the same candidate and run_id is ignored (repeat). Each result is kept 90 days in source_probe_results. Returns counts. Error: results_invalid.';

-- ---------------------------------------------------------------------------
-- 9d. collector_sources_for_regions (service role)
-- ---------------------------------------------------------------------------
create or replace function public.collector_sources_for_regions(p_regions uuid[])
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'region_id', q.region_id,
           'candidate_id', q.id,
           'status', q.status,
           'seed', jsonb_strip_nulls(jsonb_build_object(
             'id', public.source_candidate_slug(q.id),
             'kind', q.feed_kind,
             'url', q.feed_url,
             'name', q.src_name,
             'attribution', q.src_attr,
             'enabled', true,
             'verified', q.status = 'enabled',
             'discover', case when q.feed_kind = 'page' then true end,
             'maxPages', case when q.feed_kind = 'page' then 5 end,
             'note', 'Discovered (' || q.origin || '), ' || q.status))) order by q.region_id, q.score desc, q.id), '[]'::jsonb)
    from (select c.*,
                 coalesce(f.name, coalesce(c.name, left(c.host, 80))) as src_name,
                 coalesce(f.attribution,
                          left(case when coalesce(c.name, c.host) = c.host then 'Events from ' || c.host
                                    else 'Events from ' || c.name || ' (' || c.host || ')' end, 300)) as src_attr
            from public.source_candidates c
            left join public.feed_sources f on f.candidate_id = c.id
           where c.region_id = any (coalesce(p_regions, '{}'))
             and not c.locked
             and c.feed_url is not null and c.feed_kind is not null
             and c.review_status in ('none', 'approved')
             and (c.status in ('probation', 'enabled') or (c.status = 'paused' and c.retry_after <= now()))
             and public.collector_host_denied(c.host) is null
             and public.collector_host_denied(public.source_url_host(c.feed_url)) is null
             and coalesce(f.denylisted, false) = false
           limit 2000) q;
$$;
comment on function public.collector_sources_for_regions(uuid[]) is
  'Service role (D-042 slice 7; GET /collector/sources?regions=): the discovered sources of the given collector regions as collector seeds [{region_id, candidate_id, status, seed: {id disc-<12 hex>, kind ics|rss|page, url, name, attribution, enabled, verified, discover, maxPages 5 for pages}}]: probation and enabled ones, and paused ones whose weekly retry is due; never locked, denylisted or unapproved ones. At most 2,000. No user ids.';

-- ---------------------------------------------------------------------------
-- Grants for section 6 to 9
-- ---------------------------------------------------------------------------
revoke all on function public.collector_host_denied(text) from public, anon, authenticated;
revoke all on function public.source_url_check(text) from public, anon, authenticated;
revoke all on function public.source_url_host(text) from public, anon, authenticated;
revoke all on function public.source_candidate_slug(uuid) from public, anon, authenticated;
revoke all on function public.source_discovery_allowed(text, text) from public, anon, authenticated;
revoke all on function public.suggest_calendar(text) from public, anon;
revoke all on function public.mod_review_source_candidate(uuid, boolean, text) from public, anon;
revoke all on function public.source_candidates_add(jsonb) from public, anon, authenticated;
revoke all on function public.source_candidates_due(integer, uuid[]) from public, anon, authenticated;
revoke all on function public.source_candidates_record(jsonb) from public, anon, authenticated;
revoke all on function public.collector_sources_for_regions(uuid[]) from public, anon, authenticated;
grant execute on function public.collector_host_denied(text) to service_role;
grant execute on function public.source_url_check(text) to service_role;
grant execute on function public.source_url_host(text) to service_role;
grant execute on function public.source_candidate_slug(uuid) to service_role;
grant execute on function public.source_discovery_allowed(text, text) to service_role;
grant execute on function public.suggest_calendar(text) to authenticated;
grant execute on function public.mod_review_source_candidate(uuid, boolean, text) to authenticated;
grant execute on function public.source_candidates_add(jsonb) to service_role;
grant execute on function public.source_candidates_due(integer, uuid[]) to service_role;
grant execute on function public.source_candidates_record(jsonb) to service_role;
grant execute on function public.collector_sources_for_regions(uuid[]) to service_role;

-- ---------------------------------------------------------------------------
-- 10. collector_ingest_events (migration 39 body,
--     20261203000100_collector_images_licensed_fix.sql)
-- ---------------------------------------------------------------------------
create or replace function public.collector_ingest_events(
  p_source   jsonb,
  p_items    jsonb,
  p_complete boolean default true,
  p_enable   boolean default false,
  p_run_id   text default null,
  p_seen     jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slug     text;
  v_kind     text;
  v_url      text;
  v_name     text;
  v_attr     text;
  v_home     text;
  v_lane     text;
  v_on       boolean;
  v_hubs     text[];
  v_hub      uuid;
  v_lat      double precision;
  v_lng      double precision;
  v_point    extensions.geography;
  v_radius   smallint;
  v_label    text;
  v_tz       text;
  v_row      public.feed_sources%rowtype;
  v_created  boolean := false;
  v_res      jsonb;
  -- Migration 38
  v_licensed boolean;
  v_repeat   boolean := false;
  v_enabled  boolean;
  v_items    jsonb;
begin
  if p_source is null or jsonb_typeof(p_source) <> 'object' then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'source';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items_invalid' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_items) > 2000 then
    raise exception 'batch_too_large' using errcode = 'check_violation';
  end if;
  -- Migration 38: run id and seen ids.
  if p_run_id is not null and p_run_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$' then
    raise exception 'run_id_invalid' using errcode = 'check_violation';
  end if;
  if p_seen is not null and jsonb_typeof(p_seen) <> 'null' then
    if jsonb_typeof(p_seen) <> 'array' or jsonb_array_length(p_seen) > 2000
       or exists (select 1 from jsonb_array_elements(p_seen) s
                   where jsonb_typeof(s.value) <> 'string' or char_length(s.value #>> '{}') not between 1 and 200) then
      raise exception 'items_invalid' using errcode = 'check_violation', hint = 'seen';
    end if;
  end if;

  v_slug := p_source ->> 'slug';
  if v_slug is null or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or char_length(v_slug) not between 3 and 60 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'slug';
  end if;
  v_kind := p_source ->> 'kind';
  if v_kind is null or v_kind not in ('ics', 'rss', 'jsonld', 'localist', 'socrata', 'arcgis', 'ticketmaster', 'seatgeek') then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'kind';
  end if;
  v_url := p_source ->> 'url';
  if v_url is null or v_url !~ '^https://' or char_length(v_url) > 500 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'url';
  end if;
  v_name := btrim(coalesce(p_source ->> 'name', ''));
  if char_length(v_name) not between 2 and 80 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'name';
  end if;
  v_attr := btrim(coalesce(p_source ->> 'attribution', ''));
  if char_length(v_attr) not between 10 and 300 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'attribution';
  end if;
  v_home := nullif(btrim(coalesce(p_source ->> 'homepage_url', '')), '');
  if v_home is not null and (v_home !~ '^https://' or char_length(v_home) > 500) then
    v_home := null;
  end if;
  v_lane := p_source ->> 'lane';
  if v_lane is null or v_lane not in ('api', 'feed', 'page') then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'lane';
  end if;
  if jsonb_typeof(p_source -> 'enabled') <> 'boolean' then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'enabled';
  end if;
  v_on := (p_source ->> 'enabled')::boolean;
  -- Migration 38: images are kept only when the seed says they are licensed.
  -- Migration 39: false, not null, when the source does not say (feed_sources.images_licensed is not null).
  v_licensed := coalesce(jsonb_typeof(p_source -> 'images_licensed') = 'boolean' and (p_source ->> 'images_licensed')::boolean, false);

  if p_source ? 'hubs' and jsonb_typeof(p_source -> 'hubs') <> 'null' then
    if jsonb_typeof(p_source -> 'hubs') <> 'array' or jsonb_array_length(p_source -> 'hubs') > 5
       or exists (select 1 from jsonb_array_elements(p_source -> 'hubs') h
                   where jsonb_typeof(h.value) <> 'string' or h.value #>> '{}' !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                      or char_length(h.value #>> '{}') > 80) then
      raise exception 'source_invalid' using errcode = 'check_violation', hint = 'hubs';
    end if;
    v_hubs := array(select h.value #>> '{}' from jsonb_array_elements(p_source -> 'hubs') with ordinality h(value, o) order by h.o);
  else
    v_hubs := '{}';
  end if;
  -- The first hub tag that is an active 18+ hub; rules still win over it (import_pick_hub).
  select h.id into v_hub
    from unnest(v_hubs) with ordinality t(slug, o)
    join public.hubs h on h.slug = t.slug and h.is_active and h.min_age = 18
   order by t.o
   limit 1;

  if jsonb_typeof(p_source -> 'region') = 'object' then
    v_lat := case when jsonb_typeof(p_source #> '{region,lat}') = 'number' then (p_source #>> '{region,lat}')::double precision end;
    v_lng := case when jsonb_typeof(p_source #> '{region,lng}') = 'number' then (p_source #>> '{region,lng}')::double precision end;
    if v_lat between -90 and 90 and v_lng between -180 and 180 and not (v_lat = 0 and v_lng = 0) then
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
    end if;
    if jsonb_typeof(p_source #> '{region,radius_km}') = 'number' then
      v_radius := least(200, greatest(1, round((p_source #>> '{region,radius_km}')::numeric)))::smallint;
    end if;
    v_label := public.import_clip(nullif(btrim(coalesce(p_source #>> '{region,label}', '')), ''), 120);
    v_tz := nullif(btrim(coalesce(p_source #>> '{region,timezone}', '')), '');
    if v_tz is not null and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
      raise exception 'source_invalid' using errcode = 'check_violation', hint = 'timezone';
    end if;
  end if;

  select * into v_row from public.feed_sources where slug = v_slug for update;
  if found and not v_row.collector then
    raise exception 'source_not_collector' using errcode = 'check_violation';
  end if;

  if not found then
    insert into public.feed_sources
      (slug, kind, url, name, attribution, homepage_url, enabled, default_hub_id, collector, lane,
       region_point, region_radius_km, region_label, region_timezone, hub_tags, collector_seen_at,
       collector_last_run_id, images_licensed)
    values
      -- Migration 46: p_enable never turns on a discovered source (disc- slug); the lifecycle does.
      (v_slug, v_kind, v_url, v_name, v_attr, v_home, coalesce(p_enable, false) and v_on and v_slug !~ '^disc-', v_hub, true, v_lane,
       v_point, v_radius, v_label, v_tz, v_hubs, now(),
       p_run_id, v_licensed);
    v_created := true;
  else
    -- Migration 38: the same run posting the source again is a retry.
    v_repeat := p_run_id is not null and v_row.collector_last_run_id is not distinct from p_run_id;
    -- Migration 38: enabled is not in this update (its trigger reschedules every import-feed job).
    update public.feed_sources
       set kind = v_kind, url = v_url, name = v_name, attribution = v_attr, homepage_url = v_home,
           default_hub_id = v_hub, lane = v_lane, region_point = v_point, region_radius_km = v_radius,
           region_label = v_label, region_timezone = v_tz, hub_tags = v_hubs, collector_seen_at = now(),
           collector_last_run_id = coalesce(p_run_id, collector_last_run_id), images_licensed = v_licensed
     where id = v_row.id;
    -- Migration 38: written only when it changes.
    v_enabled := case when not v_on then false
                      -- Migration 46: a discovered source stays as the lifecycle set it.
                      when v_slug ~ '^disc-' or v_row.discovery_status is not null then v_row.enabled
                      when coalesce(p_enable, false) then not v_row.denylisted
                      else v_row.enabled end;
    if v_enabled is distinct from v_row.enabled then
      update public.feed_sources set enabled = v_enabled where id = v_row.id;
    end if;
  end if;
  select * into v_row from public.feed_sources where slug = v_slug;

  if not v_row.enabled then
    return jsonb_build_object('source', v_slug, 'enabled', false, 'created', v_created,
                              'complete', coalesce(p_complete, false), 'total', jsonb_array_length(p_items),
                              'repeat_run', v_repeat);
  end if;

  -- Migration 38: D-040 item rules (excerpt of at most 300 characters; images only when
  -- licensed), then the seen ids as seen_only items.
  select coalesce(jsonb_agg(
           case when jsonb_typeof(x.value) = 'object' then
             (case when v_licensed then x.value else x.value - 'cover_url' end) - 'seen_only'
             || case when jsonb_typeof(x.value -> 'description') = 'string'
                     then jsonb_build_object('description', left(x.value ->> 'description', 300))
                     else '{}'::jsonb end
           else x.value end
           order by x.o), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(p_items) with ordinality x(value, o);
  if p_seen is not null and jsonb_typeof(p_seen) = 'array' then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object('external_id', s.value #>> '{}', 'seen_only', true) order by s.o)
                                      from jsonb_array_elements(p_seen) with ordinality s(value, o)), '[]'::jsonb);
  end if;

  perform set_config('app.import_partial_run',
    case when coalesce(p_complete, false) and not v_repeat then 'off' else 'on' end, true);
  begin
    v_res := public.import_upsert_batch(v_slug, v_items);
  exception when others then
    perform set_config('app.import_partial_run', 'off', true);
    raise;
  end;
  perform set_config('app.import_partial_run', 'off', true);

  return v_res || jsonb_build_object('enabled', true, 'created', v_created, 'complete', coalesce(p_complete, false),
                                     'repeat_run', v_repeat);
end $$;

comment on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) is
  'Collector ingest (D-040), service_role only (the collector Edge Function, POST /collector/ingest/events). Creates or updates the source''s feed_sources row from the seed (collector = true, kind, url, name, attribution, lane, region, hub tags, images_licensed; the first active 18+ hub tag is default_hub_id), switches it on when p_enable (never a discovered source: a disc- slug or a row with a discovery_status, which only source_candidates_record switches, migration 46) and off when the seed is off (enabled is written only when it changes), then, when the row is enabled, runs import_upsert_batch on p_items (descriptions clipped to 300 characters, cover_url dropped unless images_licensed) plus p_seen ids as seen_only items; p_complete false marks a partial read, and a second post with the same p_run_id is partial too, so no missed runs are counted for it. A slug owned by a non-collector source is refused. Errors: source_invalid (hint names the field), items_invalid, batch_too_large, run_id_invalid, source_not_collector. Returns import_upsert_batch''s counts plus enabled, created, complete and repeat_run.';

revoke all on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.42')
  on conflict (key) do update set value = excluded.value, updated_at = now();
