-- ============================================================================
-- Activity Planet schema v2 — migration 62: collector completion, part 1
--   (docs/design/collector/COLLECTOR_COMPLETION.md sections 2.1 to 2.4 and
--   2.8, Slice 1 item 1). Listing removal for imported items, organizer
--   claims with automatic ownership proof, organizer-connected ICS feeds and
--   the Eventbrite connection's state rows (key-gated). Rebuilt functions
--   start from their latest bodies (named below) and each change is marked
--   "Migration 62". Checks: supabase/tests/listing_removal.sql,
--   supabase/tests/organizer_claims.sql, supabase/tests/organizer_feeds.sql.
--
--   What this file does
--     1. moderation_actions accepts listing_remove, listing_reject,
--        listing_reopen, source_remove, organizer_review, organizer_revoke,
--        organizer_hide, organizer_unhide and organizer_update, and the
--        target kinds listing, source and organizer_claim.
--     2. feed_sources gains origin ('collector' | 'organizer'), organizer_id,
--        organizer_verified_at, organizer_claim_id, organizer_hub_id,
--        organizer_stopped_at, organizer_refresh_requested_at,
--        organizer_images_at and collector_region_id, and kind 'eventbrite'.
--     3. listing_removal_requests and submit_listing_removal (service role:
--        the site's form route after a Turnstile check, as NCII since
--        migration 54; no account needed; 3 a day per email, 5 per client
--        hash, 200 an hour overall), the
--        moderator queue and resolve RPCs (item: removed_at on every import
--        row of the event, so no copy republishes it; source: the row off,
--        its host denylisted unless it is a shared calendar host, its
--        candidate rejected and locked) and the yearly contact purge.
--     4. organizer_claims: start_organizer_claim, organizer_claim_check,
--        my_organizer_claims, collector_claims_due and collector_claims_record
--        (the verification job), mod_organizer_claim_review (a look after the
--        fact, or revoke), organizer_source_update (default hub, hide and
--        unhide an upcoming item, stop or resume, connected feed URL, image
--        licence, refresh now).
--     5. connect_organizer_feed: a connected ICS feed as an organizer-origin
--        feed_sources row (org-<12 hex>) in the owner's collector region,
--        off until its first good run; at most 3 per person.
--     6. organizer_oauth_states and the service-role Eventbrite helpers
--        (state start and single-use take, token kept in Supabase Vault,
--        never in a table column). The Edge Function eventbrite-connect
--        answers skipped: no key without EVENTBRITE_CLIENT_ID and
--        EVENTBRITE_CLIENT_SECRET.
--     7. Rebuilt: mod_sla_hours (migration 53, 20261217000100_admin_panel.sql;
--        keys listing_removal 72 hours and organizer_claim 168 hours),
--        mod_queue (migration 60, 20261224000100_coaching.sql; listing removals
--        and verified organizer claims nobody looked at),
--        collector_sources_for_regions (migration 46,
--        20261210000100_source_discovery.sql; connected feeds of the regions),
--        collector_ingest_events (migration 46, same file; organizer rows:
--        first good run enables, stop holds, the owner's hub and image licence
--        stand, refresh flag cleared) and request_account_deletion (migration
--        60, 20261224000100_coaching.sql).
--     8. pg_cron listing-removal-contacts-purge daily; meta.schema_version 2.58.
--
--   Account deletion: organizer_claims and organizer_oauth_states rows of the
--   caller go; connected feeds the caller owned are stopped (upcoming items
--   withdrawn) and lose the owner; claimed sources the collector found itself
--   stay on without an owner; the caller's Eventbrite secret leaves the
--   vault; resolver stamps on listing removals are cleared. Listing removal
--   requests hold no account link (like NCII requests). The delete-account
--   Edge Function needs no change (nothing in Storage); its comment names
--   these tables.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. moderation_actions: new actions and target kinds
-- ---------------------------------------------------------------------------
alter table public.moderation_actions drop constraint if exists moderation_actions_kind;
alter table public.moderation_actions add constraint moderation_actions_kind
  check (target_kind in ('profile', 'event', 'chapter', 'hub', 'takedown', 'image', 'message',
                         'coach_listing', 'coach_review', 'coach_review_reply', 'booking',
                         'listing', 'source', 'organizer_claim'));
alter table public.moderation_actions drop constraint if exists moderation_actions_action;
alter table public.moderation_actions add constraint moderation_actions_action
  check (action in ('auto_hide', 'dismiss', 'hide', 'remove', 'restore', 'ban', 'unban', 'grant_moderator',
                    'revoke_moderator', 'ncii_remove', 'ncii_reject', 'ncii_update', 'image_block', 'image_remove',
                    'coach_suspend', 'coach_restore', 'cancel_refund', 'uphold_no_show', 'reject_no_show',
                    'complete',
                    -- Migration 62
                    'listing_remove', 'listing_reject', 'listing_reopen', 'source_remove',
                    'organizer_review', 'organizer_revoke', 'organizer_hide', 'organizer_unhide',
                    'organizer_update'));

-- ---------------------------------------------------------------------------
-- 2. feed_sources: organizer columns and the eventbrite kind
-- ---------------------------------------------------------------------------
alter table public.feed_sources drop constraint if exists feed_sources_kind;
alter table public.feed_sources
  add constraint feed_sources_kind check (kind in (
    'localist', 'engage_rss', 'ics', 'rss', 'jsonld', 'ticketmaster', 'seatgeek', 'socrata', 'arcgis',
    'eventbrite'));

alter table public.feed_sources
  add column if not exists origin                         text not null default 'collector',
  add column if not exists organizer_id                   uuid,
  add column if not exists organizer_verified_at          timestamptz,
  add column if not exists organizer_claim_id             uuid,
  add column if not exists organizer_hub_id               uuid,
  add column if not exists organizer_stopped_at           timestamptz,
  add column if not exists organizer_refresh_requested_at timestamptz,
  add column if not exists organizer_images_at            timestamptz,
  add column if not exists collector_region_id            uuid;

do $$ begin
  alter table public.feed_sources add constraint feed_sources_origin check (origin in ('collector', 'organizer'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_organizer_fk
    foreign key (organizer_id) references public.profiles (id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_organizer_hub_fk
    foreign key (organizer_hub_id) references public.hubs (id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_collector_region_fk
    foreign key (collector_region_id) references public.collector_regions (id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_organizer_slug
    check (origin = 'collector' or slug ~ '^org-[0-9a-f]{12}$');
exception when duplicate_object then null; end $$;
create index if not exists feed_sources_organizer_idx on public.feed_sources (organizer_id) where organizer_id is not null;
create index if not exists feed_sources_organizer_claim_idx on public.feed_sources (organizer_claim_id)
  where organizer_claim_id is not null;
create index if not exists feed_sources_collector_region_idx on public.feed_sources (collector_region_id)
  where origin = 'organizer';

comment on column public.feed_sources.origin is
  'Migration 62: collector (found by the collector: city files, discovery, APIs) or organizer (a feed the organizer connected, slug org-<12 hex>; connect_organizer_feed, or the Eventbrite connection).';
comment on column public.feed_sources.organizer_id is
  'Migration 62: the verified owner (organizer_claims). Set by collector_claims_record; null when nobody has proved ownership or the owner deleted their account.';
comment on column public.feed_sources.organizer_claim_id is
  'Migration 62: the claim a connected feed belongs to (organizer origin only).';
comment on column public.feed_sources.organizer_hub_id is
  'Migration 62: the owner''s default hub; collector_ingest_events keeps it over the seed''s hub tags.';
comment on column public.feed_sources.organizer_stopped_at is
  'Migration 62: the owner (or account deletion, or a moderator revoke) stopped the listing; the source stays off and is not collected until the owner resumes it.';
comment on column public.feed_sources.organizer_refresh_requested_at is
  'Migration 62: the owner pressed Refresh now; the verify job collects the source (at most once an hour) and the ingest clears it.';
comment on column public.feed_sources.organizer_images_at is
  'Migration 62: when the owner ticked that they license their images (images_licensed on a connected feed); null when not.';
comment on column public.feed_sources.collector_region_id is
  'Migration 62: the collector region a connected feed is read with (the region holding the owner''s home, else the point they picked).';

-- ---------------------------------------------------------------------------
-- 3. Internal helpers
-- ---------------------------------------------------------------------------
-- The registrable domain of a host, the same rule as collector_host_denied's site label: the
-- last two labels, or three under a two-letter second-level suffix (co.uk, com.au).
create or replace function public.registrable_domain(p_host text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  h      text := regexp_replace(regexp_replace(lower(btrim(coalesce(p_host, ''))), '\.+$', ''), '^www\.', '');
  labels text[];
  n      integer;
begin
  if h = '' then
    return null;
  end if;
  labels := array(select l from unnest(string_to_array(h, '.')) l where l <> '');
  n := cardinality(labels);
  if n <= 2 then
    return array_to_string(labels, '.');
  elsif char_length(labels[n]) = 2 and labels[n - 1] in ('co', 'com', 'org', 'net', 'gov', 'ac', 'edu') then
    return array_to_string(labels[n - 2:n], '.');
  end if;
  return array_to_string(labels[n - 1:n], '.');
end $$;
comment on function public.registrable_domain(text) is
  'Migration 62: the registrable domain of a host (lower case, no www.): the last two labels, or three under a two-letter second-level suffix. Internal.';

-- Hosts that serve many unrelated people's calendars: a removal on request switches the source
-- off and marks it denylisted, but never denylists the whole host.
create or replace function public.collector_shared_host(p_host text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(lower(p_host), '') in ('calendar.google.com', 'www.google.com', 'outlook.office365.com',
                                         'outlook.office.com', 'outlook.live.com', 'calendar.yahoo.com',
                                         'www.eventbriteapi.com')
      or coalesce(lower(p_host), '') ~ '(^|\.)icloud\.com$';
$$;
comment on function public.collector_shared_host(text) is
  'Migration 62: true for calendar hosts shared by many publishers (Google Calendar, Outlook, Yahoo, iCloud, the Eventbrite API). Internal.';

-- An organizer verification token: ap-verify- plus 24 random base32 characters.
create or replace function public.organizer_token()
returns text language plpgsql volatile set search_path = '' as $$
declare
  b   bytea := extensions.gen_random_bytes(24);
  a   text := 'abcdefghijklmnopqrstuvwxyz234567';
  out text := 'ap-verify-';
  i   integer;
begin
  for i in 0..23 loop
    out := out || substr(a, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return out;
end $$;
comment on function public.organizer_token() is 'Migration 62: a fresh claim token (ap-verify- and 24 base32 characters). Internal.';

-- Takes a source's upcoming items down. 'stop': cancelled as no longer listed (they come back by
-- themselves if the source is read again); 'remove': removed_at on every import row of each
-- event (linked copies included) and the event removed by moderation, so nothing republishes it.
create or replace function public.feed_source_withdraw(p_source uuid, p_mode text, p_reason text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer := 0;
begin
  if p_mode = 'stop' then
    with c as (
      update public.events e
         set status = 'cancelled', cancelled_at = now(), cancel_reason = 'No longer listed by the source.'
        from public.event_imports ei
       where ei.source_id = p_source and ei.is_primary and ei.removed_at is null
         and e.id = ei.event_id and e.kind = 'imported' and e.status = 'published' and e.starts_at > now()
         and not exists (select 1 from public.event_imports s
                          where s.event_id = e.id and s.source_id <> p_source and s.removed_at is null
                            and s.missed_runs = 0)
      returning e.id)
    select count(*) into v_n from c;
  elsif p_mode = 'remove' then
    with ev as (
      select distinct ei.event_id from public.event_imports ei
       where ei.source_id = p_source and ei.event_id is not null
    ), r as (
      update public.event_imports ei
         set removed_at = coalesce(ei.removed_at, now()),
             removed_reason = coalesce(ei.removed_reason, left(coalesce(p_reason, 'owner request'), 500))
        from ev where ei.event_id = ev.event_id
      returning ei.id)
    select count(*) into v_n from r;
    update public.events e
       set moderation_state = 'removed', moderated_at = now()
      from public.event_imports ei
     where ei.source_id = p_source and e.id = ei.event_id and e.kind = 'imported'
       and e.moderation_state is distinct from 'removed';
  else
    raise exception 'invalid_mode' using errcode = '22023';
  end if;
  return v_n;
end $$;
comment on function public.feed_source_withdraw(uuid, text, text) is
  'Migration 62: takes a source''s items down. stop: its upcoming published events (where no other live source lists them) are cancelled as no longer listed, so they return if the source is read again; remove: every import row of every event it produced is marked removed (linked copies too) and the events are removed by moderation. Returns the rows changed. Internal.';

-- ---------------------------------------------------------------------------
-- 4. listing_removal_requests
-- ---------------------------------------------------------------------------
create table if not exists public.listing_removal_requests (
  id                 uuid primary key default gen_random_uuid(),
  reference          text not null unique,
  event_id           uuid references public.events (id) on delete set null,
  source_id          uuid references public.feed_sources (id) on delete set null,
  url                text,
  scope              text not null default 'item',
  requester_name     text not null,
  requester_email    text not null,
  email_hash         text not null,
  relationship       text not null,
  reason             text not null default '',
  status             text not null default 'open',
  resolved_by        uuid references public.profiles (id) on delete set null,
  resolved_at        timestamptz,
  resolution_note    text not null default '',
  contact_cleared_at timestamptz,
  client_hash        text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint listing_removal_requests_client_hash check (client_hash is null or client_hash ~ '^[0-9a-f]{64}$'),
  constraint listing_removal_requests_reference check (reference ~ '^RM-[0-9A-F]{8}$'),
  constraint listing_removal_requests_scope check (scope in ('item', 'source')),
  constraint listing_removal_requests_relationship check (relationship in ('organizer', 'venue', 'rights_holder', 'other')),
  constraint listing_removal_requests_status check (status in ('open', 'removed', 'rejected')),
  constraint listing_removal_requests_url check (url is null or (url ~ '^https://' and char_length(url) <= 2000)),
  constraint listing_removal_requests_lengths check (
    char_length(requester_name) <= 200 and char_length(requester_email) <= 254
    and char_length(reason) <= 2000 and char_length(resolution_note) <= 1000),
  constraint listing_removal_requests_target check (contact_cleared_at is not null or event_id is not null
                                                    or source_id is not null or url is not null),
  constraint listing_removal_requests_required check (
    contact_cleared_at is not null or (requester_name <> '' and requester_email <> ''))
);
create index if not exists listing_removal_requests_queue_idx on public.listing_removal_requests (created_at)
  where status = 'open';
create index if not exists listing_removal_requests_email_idx on public.listing_removal_requests (email_hash, created_at);
create index if not exists listing_removal_requests_created_idx on public.listing_removal_requests (created_at);
create index if not exists listing_removal_requests_client_idx on public.listing_removal_requests (client_hash, created_at)
  where client_hash is not null;
create index if not exists listing_removal_requests_event_idx on public.listing_removal_requests (event_id)
  where event_id is not null;
create index if not exists listing_removal_requests_source_idx on public.listing_removal_requests (source_id)
  where source_id is not null;
create index if not exists listing_removal_requests_resolved_by_idx on public.listing_removal_requests (resolved_by)
  where resolved_by is not null;
create or replace trigger listing_removal_requests_set_updated_at before update on public.listing_removal_requests
  for each row execute function public.set_updated_at();
comment on table public.listing_removal_requests is
  'Migration 62 (D-040 "Request removal" on every imported item): public requests to take down an imported listing (scope item) or everything from its source (scope source). No account needed and nothing links the requester to one. Service role only; moderators read through mod_listing_removal_queue. Contact, name and reason are cleared a year after the request closes; reference, dates and outcome stay.';

alter table public.listing_removal_requests enable row level security;
revoke all on public.listing_removal_requests from public, anon, authenticated;
grant all on public.listing_removal_requests to service_role;

create or replace function public.submit_listing_removal(
  p_event uuid, p_url text, p_scope text, p_name text, p_email text, p_relationship text, p_reason text,
  p_client_hash text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_client text := nullif(lower(btrim(coalesce(p_client_hash, ''))), '');
  v_name   text := left(btrim(coalesce(p_name, '')), 200);
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_url    text := nullif(btrim(coalesce(p_url, '')), '');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_scope  text := coalesce(nullif(btrim(coalesce(p_scope, '')), ''), 'item');
  v_hash   text;
  v_ref    text;
  v_source uuid;
begin
  if char_length(v_name) < 2 then
    raise exception 'name_required' using errcode = '22023';
  end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  if coalesce(p_relationship, '') not in ('organizer', 'venue', 'rights_holder', 'other') then
    raise exception 'invalid_relationship' using errcode = '22023';
  end if;
  if v_scope not in ('item', 'source') then
    raise exception 'invalid_scope' using errcode = '22023';
  end if;
  if char_length(v_reason) > 2000 then
    raise exception 'too_long' using errcode = '22023';
  end if;
  if v_url is not null and (v_url !~ '^https://' or char_length(v_url) > 2000 or v_url ~ '[[:space:][:cntrl:]]') then
    raise exception 'invalid_url' using errcode = '22023';
  end if;
  if p_event is null and v_url is null then
    raise exception 'listing_required' using errcode = '22023';
  end if;
  if v_client is not null and v_client !~ '^[0-9a-f]{64}$' then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if p_event is not null then
    if not exists (select 1 from public.events e where e.id = p_event and e.kind = 'imported') then
      raise exception 'not_imported' using errcode = '22023';
    end if;
    select ei.source_id into v_source
      from public.event_imports ei
     where ei.event_id = p_event
     order by ei.is_primary desc, ei.first_seen_at
     limit 1;
  end if;

  v_hash := encode(extensions.digest(v_email, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('submit_listing_removal:' || v_hash, 0));
  if v_client is not null then
    perform pg_advisory_xact_lock(hashtextextended('submit_listing_removal:' || v_client, 0));
  end if;
  if (select count(*) from public.listing_removal_requests t
       where t.email_hash = v_hash and t.created_at > now() - interval '1 day') >= 3
     or (v_client is not null and (select count(*) from public.listing_removal_requests t
                                    where t.client_hash = v_client and t.created_at > now() - interval '1 day') >= 5)
     or (select count(*) from public.listing_removal_requests t where t.created_at > now() - interval '1 hour') >= 200 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  loop
    v_ref := 'RM-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.listing_removal_requests t where t.reference = v_ref);
  end loop;
  insert into public.listing_removal_requests (reference, event_id, source_id, url, scope, requester_name,
                                               requester_email, email_hash, relationship, reason, client_hash)
  values (v_ref, p_event, v_source, v_url, v_scope, v_name, v_email, v_hash, p_relationship, v_reason, v_client);
  return jsonb_build_object('reference', v_ref);
end $$;
comment on function public.submit_listing_removal(uuid, text, text, text, text, text, text, text) is
  'Migration 62, service role only (the site''s removal form route, after its Turnstile check, as for NCII requests since migration 54): asks for an imported listing (scope item) or its whole source (scope source) to be taken down. p_event must be an imported event (not_imported; a member''s plan goes through reports) or p_url the listing or source page (https). Needs a name, an email and relationship organizer | venue | rights_holder | other; reason at most 2,000 characters. 3 a day per email, 5 a day per p_client_hash (an HMAC of the caller''s IP made by the route; cleared after two days), 200 an hour overall (rate_limited). Returns {reference}. Errors: bad_request, name_required, invalid_email, invalid_relationship, invalid_scope, too_long, invalid_url, listing_required, not_imported, rate_limited.';

create or replace function public.mod_listing_removal_queue(p_limit integer default 100, p_closed boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id,
             'reference', t.reference,
             'status', t.status,
             'scope', t.scope,
             'received_at', t.created_at,
             'due_at', t.created_at + make_interval(hours => public.mod_sla_hours('listing_removal')),
             'requester', jsonb_build_object('name', t.requester_name, 'email', t.requester_email,
                                             'relationship', t.relationship),
             'reason', t.reason,
             'url', t.url,
             'event', (select jsonb_build_object('id', e.id, 'title', e.title, 'starts_at', e.starts_at,
                                                 'external_url', e.external_url, 'moderation_state', e.moderation_state)
                         from public.events e where e.id = t.event_id),
             'source', (select jsonb_build_object('id', f.id, 'slug', f.slug, 'name', f.name, 'url', f.url,
                                                  'enabled', f.enabled, 'origin', f.origin)
                          from public.feed_sources f where f.id = t.source_id),
             'resolution_note', t.resolution_note,
             'resolved_at', t.resolved_at
           ) order by t.created_at)
      from (select * from public.listing_removal_requests r
             where case when coalesce(p_closed, false) then r.status in ('removed', 'rejected') else r.status = 'open' end
             order by r.created_at
             limit greatest(1, least(coalesce(p_limit, 100), 500))) t), '[]'::jsonb);
end $$;
comment on function public.mod_listing_removal_queue(integer, boolean) is
  'Migration 62, moderators: listing removal requests, oldest first (open by default, closed with p_closed). Each item: id, reference, status, scope, received_at, due_at (72 hours), requester {name, email, relationship}, reason, url, event {id, title, starts_at, external_url, moderation_state}, source {id, slug, name, url, enabled, origin}, resolution_note, resolved_at.';

create or replace function public.mod_listing_removal_resolve(p_request uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_req   public.listing_removal_requests%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 1000);
  v_src   public.feed_sources%rowtype;
  v_host  text;
  v_n     integer := 0;
  v_deny  boolean := false;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('removed', 'rejected', 'reopen') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if p_action = 'rejected' and v_note = '' then
    raise exception 'note_required' using errcode = '22023';
  end if;
  select * into v_req from public.listing_removal_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_req.contact_cleared_at is not null then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if p_action = 'reopen' then
    if v_req.status = 'open' then
      raise exception 'request_open' using errcode = 'P0001';
    end if;
  elsif v_req.status <> 'open' then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;

  if p_action = 'removed' then
    if v_req.scope = 'item' then
      if v_req.event_id is null then
        raise exception 'no_listing' using errcode = '22023';
      end if;
      -- The column's first writer: every import row of the event, so a linked copy from another
      -- source can never republish it.
      update public.event_imports
         set removed_at = coalesce(removed_at, now()),
             removed_reason = coalesce(removed_reason, 'owner request ' || v_req.reference)
       where event_id = v_req.event_id;
      get diagnostics v_n = row_count;
      update public.events set moderation_state = 'removed', moderated_at = now()
       where id = v_req.event_id and kind = 'imported';
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
      values (uid, 'listing_remove', 'listing', v_req.id,
              left(v_req.reference || ': item, ' || v_n || ' import rows' || case when v_note <> '' then '; ' || v_note else '' end, 500));
    else
      if v_req.source_id is null then
        raise exception 'no_source' using errcode = '22023';
      end if;
      select * into v_src from public.feed_sources where id = v_req.source_id for update;
      v_n := public.feed_source_withdraw(v_src.id, 'remove', 'owner request ' || v_req.reference);
      update public.feed_sources set enabled = false, denylisted = true where id = v_src.id;
      v_host := public.source_url_host(v_src.url);
      if v_host is not null and v_host ~ '^[a-z0-9]([a-z0-9.-]{0,98}[a-z0-9])?$'
         and not public.collector_shared_host(v_host) then
        insert into public.collector_denylist (name, match, reason)
        values (v_host, 'domain', 'owner request ' || v_req.reference)
        on conflict (name, match) do nothing;
        v_deny := true;
      end if;
      update public.source_candidates
         set status = 'rejected', status_at = now(), locked = true, retry_after = null,
             reason = left('owner request ' || v_req.reference, 200)
       where id = v_src.candidate_id or (v_deny and host = v_host);
      update public.feed_sources set enabled = false, denylisted = true
       where v_deny and public.source_url_host(url) = v_host and id <> v_src.id;
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
      values (uid, 'source_remove', 'source', v_src.id,
              left(v_req.reference || ': source ' || v_src.slug || ', ' || v_n || ' import rows'
                   || case when v_deny then ', host denylisted' else ', shared host kept' end
                   || case when v_note <> '' then '; ' || v_note else '' end, 500));
    end if;
  elsif p_action = 'rejected' then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
    values (uid, 'listing_reject', 'listing', v_req.id, left(v_req.reference || ': ' || v_note, 500));
  else
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
    values (uid, 'listing_reopen', 'listing', v_req.id,
            left(v_req.reference || case when v_note <> '' then ': ' || v_note else '' end, 500));
  end if;

  update public.listing_removal_requests
     set status          = case p_action when 'reopen' then 'open' else p_action end,
         resolution_note = case when v_note <> '' then v_note else resolution_note end,
         resolved_by     = case when p_action = 'reopen' then null else uid end,
         resolved_at     = case when p_action = 'reopen' then null else now() end
   where id = p_request;
  return jsonb_build_object('id', p_request, 'status', case p_action when 'reopen' then 'open' else p_action end,
                            'rows', v_n, 'host_denylisted', v_deny);
end $$;
comment on function public.mod_listing_removal_resolve(uuid, text, text) is
  'Migration 62, moderators: removed (scope item: removed_at on every import row of the event and the event removed, so neither source nor a linked copy republishes it; scope source: the same for everything the source produced, the row off and denylisted, its host added to collector_denylist with reason "owner request <reference>" unless it is a shared calendar host, its discovery candidate rejected and locked), rejected (note required) or reopen (the request is open again; a removal stays). Logged in moderation_actions (listing_remove, source_remove, listing_reject, listing_reopen). Returns {id, status, rows, host_denylisted}.';

create or replace function public.purge_listing_removal_contacts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  update public.listing_removal_requests
     set requester_name = '', requester_email = '', email_hash = '', reason = '', resolution_note = '',
         client_hash = null, contact_cleared_at = now()
   where status in ('removed', 'rejected') and resolved_at < now() - interval '365 days'
     and contact_cleared_at is null;
  get diagnostics v_n = row_count;
  update public.listing_removal_requests set client_hash = null
   where client_hash is not null and created_at < now() - interval '2 days';
  return v_n;
end $$;
comment on function public.purge_listing_removal_contacts() is
  'Migration 62, pg_cron listing-removal-contacts-purge daily: clears the name, email, email hash, reason and note of listing removal requests closed more than a year ago, and client hashes after two days. Reference, dates, scope and outcome stay.';

-- ---------------------------------------------------------------------------
-- 5. organizer_claims
-- ---------------------------------------------------------------------------
create table if not exists public.organizer_claims (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  source_id          uuid references public.feed_sources (id) on delete set null,
  event_id           uuid references public.events (id) on delete set null,
  host               text not null,
  method             text not null default 'meta',
  feed_url           text,
  token              text not null,
  status             text not null default 'pending',
  attempts           smallint not null default 0,
  check_requested_at timestamptz,
  last_checked_at    timestamptz,
  verified_at        timestamptz,
  reviewed_at        timestamptz,
  failure            text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint organizer_claims_host_format check (host ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$'
                                                 and char_length(host) <= 253),
  constraint organizer_claims_method check (method in ('meta', 'well_known', 'dns_txt', 'feed')),
  constraint organizer_claims_feed_url check (feed_url is null or (feed_url ~ '^https://' and char_length(feed_url) <= 500)),
  constraint organizer_claims_feed_needs_url check (method <> 'feed' or feed_url is not null),
  constraint organizer_claims_token_format check (token ~ '^ap-verify-[a-z2-7]{24}$'),
  constraint organizer_claims_status check (status in ('pending', 'verified', 'failed', 'revoked')),
  constraint organizer_claims_attempts check (attempts between 0 and 100),
  constraint organizer_claims_failure check (failure is null or failure ~ '^[a-z_:]{1,60}$')
);
create index if not exists organizer_claims_user_idx on public.organizer_claims (user_id, created_at);
create index if not exists organizer_claims_source_idx on public.organizer_claims (source_id) where source_id is not null;
create index if not exists organizer_claims_event_idx on public.organizer_claims (event_id) where event_id is not null;
create index if not exists organizer_claims_due_idx on public.organizer_claims (status, last_checked_at) where status = 'pending';
create or replace trigger organizer_claims_set_updated_at before update on public.organizer_claims
  for each row execute function public.set_updated_at();
comment on table public.organizer_claims is
  'Migration 62: a person''s claim to own an imported source (or the source of an imported event), proved automatically: a meta tag or .well-known file with the token on the claimed host (method meta or well_known; checked by the collector verify job), a DNS TXT record at _activityplanet.<registrable domain> (dns_txt; the organizer-verify Edge Function over DNS-over-HTTPS), or the token in a connected calendar (feed). Fails after 10 checks or 7 days. The owner reads their rows (the token only through my_organizer_claims); moderators read every row without the token. Written only through the RPCs.';

alter table public.organizer_claims enable row level security;
revoke all on public.organizer_claims from public, anon, authenticated;
grant select (id, user_id, source_id, event_id, host, method, feed_url, status, attempts, last_checked_at,
              verified_at, reviewed_at, failure, created_at, updated_at)
  on public.organizer_claims to authenticated;
grant all on public.organizer_claims to service_role;
drop policy if exists "organizer_claims_select" on public.organizer_claims;
create policy "organizer_claims_select" on public.organizer_claims for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));

do $$ begin
  alter table public.feed_sources add constraint feed_sources_organizer_claim_fk
    foreign key (organizer_claim_id) references public.organizer_claims (id) on delete set null;
exception when duplicate_object then null; end $$;

-- What the owner needs to prove the claim, by method.
create or replace function public.organizer_claim_proofs(p_host text, p_token text)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'meta', '<meta name="activityplanet-verification" content="' || p_token || '">',
    'well_known', jsonb_build_object('url', 'https://' || p_host || '/.well-known/activityplanet-verification.txt',
                                     'content', p_token),
    'dns_txt', jsonb_build_object('name', '_activityplanet.' || public.registrable_domain(p_host), 'value', p_token),
    'feed', 'Add ' || p_token || ' to the calendar''s description or to the description of one upcoming event.');
$$;
comment on function public.organizer_claim_proofs(text, text) is 'Migration 62: the three proofs for a claim (meta tag, .well-known file, DNS TXT) and the feed proof. Internal.';

create or replace function public.start_organizer_claim(
  p_source uuid default null, p_event uuid default null, p_host text default null,
  p_method text default 'meta', p_feed_url text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_method text := coalesce(nullif(btrim(coalesce(p_method, '')), ''), 'meta');
  v_src    public.feed_sources%rowtype;
  v_host   text := regexp_replace(regexp_replace(lower(btrim(coalesce(p_host, ''))), '\.+$', ''), '^www\.', '');
  v_feed   text;
  v_chk    jsonb;
  v_hosts  text[];
  v_claim  public.organizer_claims%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.status = 'active' and p.deleted_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.created_at <= now() - interval '24 hours') then
    raise exception 'account_too_new' using errcode = 'P0001';
  end if;
  if v_method not in ('meta', 'well_known', 'dns_txt', 'feed') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;

  if p_event is not null then
    select f.* into v_src
      from public.event_imports ei
      join public.feed_sources f on f.id = ei.source_id
      join public.events e on e.id = ei.event_id and e.kind = 'imported'
     where ei.event_id = p_event
     order by ei.is_primary desc, ei.first_seen_at
     limit 1;
    if not found then
      raise exception 'not_imported' using errcode = '22023';
    end if;
  elsif p_source is not null then
    select * into v_src from public.feed_sources where id = p_source;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;

  if v_method = 'feed' then
    v_chk := public.source_url_check(p_feed_url);
    if not (v_chk ->> 'ok')::boolean then
      raise exception '%', v_chk ->> 'error' using errcode = '22023';
    end if;
    v_feed := v_chk ->> 'url';
    if v_host = '' then
      v_host := v_chk ->> 'host';
    end if;
  elsif v_src.id is null then
    raise exception 'source_required' using errcode = '22023';
  end if;

  if v_host = '' or v_host !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' then
    raise exception 'invalid_host' using errcode = '22023';
  end if;
  if v_src.id is not null and v_method <> 'feed' then
    v_hosts := array_remove(array[public.source_url_host(v_src.url), public.source_url_host(v_src.homepage_url)], null);
    if not (v_host = any (v_hosts)
            or v_host = any (array(select public.registrable_domain(h) from unnest(v_hosts) h))) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    if public.collector_shared_host(v_host) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  end if;
  if public.collector_host_denied(v_host) is not null then
    raise exception 'host_denied' using errcode = '22023';
  end if;
  if v_src.id is not null and v_src.organizer_id is not null and v_src.organizer_id <> uid then
    raise exception 'already_claimed' using errcode = 'P0001';
  end if;

  -- One person at a time, so two quick taps cannot both pass the limit.
  perform pg_advisory_xact_lock(hashtextextended('start_organizer_claim:' || uid::text, 0));
  select * into v_claim from public.organizer_claims c
   where c.user_id = uid and c.status = 'pending' and c.host = v_host and c.method = v_method
     and c.source_id is not distinct from v_src.id and c.feed_url is not distinct from v_feed
   order by c.created_at desc limit 1;
  if not found then
    if (select count(*) from public.organizer_claims c
         where c.user_id = uid and c.created_at > now() - interval '1 day') >= 5 then
      raise exception 'rate_limited' using errcode = 'P0001';
    end if;
    insert into public.organizer_claims (user_id, source_id, event_id, host, method, feed_url, token)
    values (uid, v_src.id, p_event, v_host, v_method, v_feed, public.organizer_token())
    returning * into v_claim;
  end if;
  return jsonb_build_object('claim_id', v_claim.id, 'status', v_claim.status, 'method', v_claim.method,
                            'host', v_claim.host, 'token', v_claim.token,
                            'proofs', public.organizer_claim_proofs(v_claim.host, v_claim.token));
end $$;
comment on function public.start_organizer_claim(uuid, uuid, text, text, text) is
  'Migration 62, authenticated: starts a claim on an imported source (p_source, or p_event, which resolves to its source) for p_host, which must be the source URL''s or homepage''s host or registrable domain (not a shared calendar host). p_method meta | well_known | dns_txt | feed (feed: p_feed_url is the calendar to connect; the host defaults to its host and no source is needed). Account at least 24 hours old (account_too_new), 5 claims a day (rate_limited); a pending claim for the same thing is returned again. Errors: not_authenticated, forbidden, invalid_method, not_imported, not_found, source_required, invalid_host, host_mismatch, host_denied, already_claimed, the url_* errors of source_url_check. Returns {claim_id, status, method, host, token, proofs}.';

create or replace function public.my_organizer_claims()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'claim_id', c.id, 'status', c.status, 'method', c.method, 'host', c.host, 'feed_url', c.feed_url,
             'token', case when c.status = 'pending' then c.token end,
             'proofs', case when c.status = 'pending' then public.organizer_claim_proofs(c.host, c.token) end,
             'attempts', c.attempts, 'last_checked_at', c.last_checked_at, 'verified_at', c.verified_at,
             'failure', c.failure, 'created_at', c.created_at,
             'source', (select jsonb_build_object('id', f.id, 'name', f.name, 'enabled', f.enabled, 'origin', f.origin)
                          from public.feed_sources f where f.id = c.source_id),
             'connected', (select coalesce(jsonb_agg(jsonb_build_object(
                                     'id', f.id, 'name', f.name, 'url', f.url, 'kind', f.kind,
                                     'enabled', f.enabled, 'stopped', f.organizer_stopped_at is not null,
                                     'last_ok_at', f.last_ok_at, 'images_licensed', f.images_licensed)
                                     order by f.created_at), '[]'::jsonb)
                             from public.feed_sources f where f.organizer_claim_id = c.id))
           order by c.created_at desc)
      from public.organizer_claims c where c.user_id = uid), '[]'::jsonb);
end $$;
comment on function public.my_organizer_claims() is
  'Migration 62, authenticated: the caller''s organizer claims, newest first, with the token and proofs while pending, the claimed source and the connected feeds.';

create or replace function public.organizer_claim_check(p_claim uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_claim public.organizer_claims%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_claim from public.organizer_claims where id = p_claim for update;
  if not found or v_claim.user_id <> uid then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_claim.status = 'pending' and v_claim.method <> 'dns_txt' then
    update public.organizer_claims set check_requested_at = now() where id = p_claim;
  end if;
  return jsonb_build_object('claim_id', v_claim.id, 'status', v_claim.status, 'method', v_claim.method,
                            'host', v_claim.host,
                            'dns_name', case when v_claim.method = 'dns_txt' and v_claim.status = 'pending'
                                             then '_activityplanet.' || public.registrable_domain(v_claim.host) end,
                            'token', case when v_claim.status = 'pending' then v_claim.token end);
end $$;
comment on function public.organizer_claim_check(uuid) is
  'Migration 62, the claim''s owner: asks for a check now. dns_txt: returns the record name and token, which the organizer-verify Edge Function looks up at once; the other methods are marked due for the next verify run (every 30 minutes). Errors: not_authenticated, not_found.';

create or replace function public.collector_claims_due(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_out jsonb;
begin
  -- Claims past 7 days or 10 checks fail.
  update public.organizer_claims
     set status = 'failed', failure = coalesce(failure, 'expired')
   where status = 'pending' and (created_at < now() - interval '7 days' or attempts >= 10);
  select coalesce(jsonb_agg(jsonb_build_object(
           'claim_id', q.id, 'method', q.method, 'host', q.host, 'token', q.token,
           'urls', q.urls) order by q.ord), '[]'::jsonb)
    into v_out
    from (select c.id, c.method, c.host, c.token,
                 row_number() over (order by c.check_requested_at nulls last, c.last_checked_at nulls first, c.id) as ord,
                 case c.method
                   when 'feed' then jsonb_build_array(c.feed_url)
                   when 'well_known' then jsonb_build_array('https://' || c.host || '/.well-known/activityplanet-verification.txt')
                   else (select coalesce(jsonb_agg(distinct u), '[]'::jsonb) from unnest(array_remove(array[
                           'https://' || c.host || '/',
                           case when public.source_url_host(f.homepage_url) = c.host then f.homepage_url end,
                           case when f.kind = 'jsonld' and public.source_url_host(f.url) = c.host then f.url end], null)) u)
                 end as urls
            from public.organizer_claims c
            left join public.feed_sources f on f.id = c.source_id
           where c.status = 'pending' and c.method <> 'dns_txt'
             and (c.check_requested_at is not null or c.last_checked_at is null
                  or c.last_checked_at < now() - interval '6 hours')
           order by c.check_requested_at nulls last, c.last_checked_at nulls first, c.id
           limit greatest(1, least(coalesce(p_limit, 50), 200))) q;
  return v_out;
end $$;
comment on function public.collector_claims_due(integer) is
  'Migration 62, service role (GET /collector/claims/due): fails claims older than 7 days or with 10 checks, then lists pending meta, well_known and feed claims due a check (asked for now, never checked, or not checked for 6 hours) with the URLs to read (at most 3: the host''s home page and the source''s homepage or page for meta, the .well-known file, or the feed) and the token to look for. At most 200.';

-- Sets the verified owner on the claimed source and the claim's connected feeds.
create or replace function public.organizer_claim_apply(p_claim uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_claim public.organizer_claims%rowtype;
begin
  select * into v_claim from public.organizer_claims where id = p_claim;
  if v_claim.status <> 'verified' then
    return;
  end if;
  update public.feed_sources
     set organizer_id = v_claim.user_id, organizer_verified_at = coalesce(v_claim.verified_at, now())
   where (id = v_claim.source_id or organizer_claim_id = v_claim.id)
     and (organizer_id is null or organizer_id = v_claim.user_id);
end $$;
comment on function public.organizer_claim_apply(uuid) is 'Migration 62: copies a verified claim''s owner onto its source and connected feeds. Internal.';

create or replace function public.collector_claims_record(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r         jsonb;
  v_claim   public.organizer_claims%rowtype;
  v_outcome text;
  v_method  text;
  v_counts  jsonb := jsonb_build_object('recorded', 0, 'verified', 0, 'failed', 0, 'pending', 0, 'ignored', 0);
  v_key     text;
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 200
     or exists (select 1 from jsonb_array_elements(p_results) x
                 where jsonb_typeof(x.value) <> 'object'
                    or coalesce(x.value ->> 'claim_id', '') !~ '^[0-9a-f-]{36}$'
                    or coalesce(x.value ->> 'outcome', '') not in ('verified', 'token_not_found', 'dns_no_txt', 'fetch_failed')
                    or (x.value ? 'method' and coalesce(x.value ->> 'method', '') not in ('meta', 'well_known', 'dns_txt', 'feed'))
                    or (x.value ? 'reason' and coalesce(x.value ->> 'reason', '') !~ '^[a-z_]{1,40}$')) then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;
  for r in select value from jsonb_array_elements(p_results) loop
    select * into v_claim from public.organizer_claims where id = (r ->> 'claim_id')::uuid for update;
    if not found or v_claim.status <> 'pending' then
      v_counts := jsonb_set(v_counts, '{ignored}', to_jsonb((v_counts ->> 'ignored')::int + 1));
      continue;
    end if;
    v_outcome := r ->> 'outcome';
    v_method := coalesce(r ->> 'method', v_claim.method);
    if v_outcome = 'verified' then
      -- Another person already owns the source: this claim cannot take it over.
      if exists (select 1 from public.feed_sources f
                  where f.id = v_claim.source_id and f.organizer_id is not null and f.organizer_id <> v_claim.user_id) then
        update public.organizer_claims
           set status = 'failed', failure = 'already_claimed', attempts = least(attempts + 1, 100),
               last_checked_at = now(), check_requested_at = null
         where id = v_claim.id;
        v_key := 'failed';
      else
        update public.organizer_claims
           set status = 'verified', verified_at = now(), method = v_method, failure = null,
               attempts = least(attempts + 1, 100), last_checked_at = now(), check_requested_at = null
         where id = v_claim.id;
        perform public.organizer_claim_apply(v_claim.id);
        v_key := 'verified';
      end if;
    else
      update public.organizer_claims
         set attempts = least(attempts + 1, 100), last_checked_at = now(), check_requested_at = null,
             failure = left(v_outcome || coalesce(':' || (r ->> 'reason'), ''), 60),
             status = case when attempts + 1 >= 10 or created_at < now() - interval '7 days' then 'failed' else 'pending' end
       where id = v_claim.id
      returning status into v_key;
    end if;
    v_counts := jsonb_set(v_counts, array[v_key], to_jsonb((v_counts ->> v_key)::int + 1));
    v_counts := jsonb_set(v_counts, '{recorded}', to_jsonb((v_counts ->> 'recorded')::int + 1));
  end loop;
  return v_counts;
end $$;
comment on function public.collector_claims_record(jsonb) is
  'Migration 62, service role (POST /collector/claims/record, and organizer-verify for DNS): results [{claim_id, outcome verified | token_not_found | dns_no_txt | fetch_failed, method?, reason?}] (at most 200). verified: the claim is verified (by the method that found the token) and its source and connected feeds get the owner, unless someone else already owns the source (failed: already_claimed). Otherwise one more attempt; the 10th, or one after 7 days, fails the claim with the outcome as failure. Claims that are not pending are ignored. Returns counts. Error: results_invalid.';

create or replace function public.mod_organizer_claim_review(p_claim uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_claim public.organizer_claims%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 400);
  v_src   uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('ok', 'revoke') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  select * into v_claim from public.organizer_claims where id = p_claim for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_claim.user_id = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  if p_action = 'ok' then
    update public.organizer_claims set reviewed_at = now() where id = p_claim;
  else
    if v_claim.status not in ('pending', 'verified') then
      raise exception 'claim_closed' using errcode = 'P0001';
    end if;
    update public.organizer_claims set status = 'revoked', reviewed_at = now(), failure = 'revoked' where id = p_claim;
    -- Connected feeds of the claim stop; a found source loses its owner and stays as it was.
    for v_src in select f.id from public.feed_sources f where f.organizer_claim_id = p_claim and f.origin = 'organizer' loop
      perform public.feed_source_withdraw(v_src, 'stop');
      update public.feed_sources set enabled = false, organizer_stopped_at = coalesce(organizer_stopped_at, now()),
                                     organizer_id = null, organizer_verified_at = null
       where id = v_src;
    end loop;
    update public.feed_sources
       set organizer_id = null, organizer_verified_at = null, organizer_hub_id = null
     where id = v_claim.source_id and organizer_id = v_claim.user_id;
  end if;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, case p_action when 'ok' then 'organizer_review' else 'organizer_revoke' end, 'organizer_claim',
          p_claim, v_claim.user_id, nullif(v_note, ''));
  return jsonb_build_object('claim_id', p_claim, 'status', case p_action when 'ok' then v_claim.status else 'revoked' end);
end $$;
comment on function public.mod_organizer_claim_review(uuid, text, text) is
  'Migration 62, moderators: ok (looked at; the verified claim leaves the queue) or revoke (the claim is revoked, its connected feeds stop and lose the owner, the claimed source loses the owner and the owner''s hub). Logged. Second-moderator rule: own_item for the moderator''s own claim.';

create or replace function public.organizer_source_update(p_source uuid, p_args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_src   public.feed_sources%rowtype;
  v_mod   boolean := coalesce(public.is_moderator(), false);
  v_hub   uuid;
  v_event uuid;
  v_chk   jsonb;
  v_n     integer;
  v_done  text[] := '{}';
  v_claim public.organizer_claims%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_args is null or jsonb_typeof(p_args) <> 'object' then
    raise exception 'invalid_args' using errcode = '22023';
  end if;
  select * into v_src from public.feed_sources where id = p_source for update;
  if not found or not (v_src.organizer_id = uid or v_mod) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_args ? 'default_hub' then
    if jsonb_typeof(p_args -> 'default_hub') = 'null' then
      v_hub := null;
    else
      select h.id into v_hub from public.hubs h
       where h.slug = p_args ->> 'default_hub' and h.is_active and h.min_age = 18;
      if v_hub is null then
        raise exception 'invalid_hub' using errcode = '22023';
      end if;
    end if;
    update public.feed_sources set organizer_hub_id = v_hub, default_hub_id = coalesce(v_hub, default_hub_id)
     where id = p_source;
    v_done := array_append(v_done, 'default_hub');
  end if;

  if p_args ? 'hide' or p_args ? 'unhide' then
    begin
      v_event := coalesce(p_args ->> 'hide', p_args ->> 'unhide')::uuid;
    exception when others then
      raise exception 'invalid_event' using errcode = '22023';
    end;
    if not exists (select 1 from public.event_imports ei join public.events e on e.id = ei.event_id
                    where ei.event_id = v_event and ei.source_id = p_source and ei.is_primary
                      and e.kind = 'imported' and e.starts_at > now()) then
      raise exception 'invalid_event' using errcode = '22023';
    end if;
    if p_args ? 'hide' then
      update public.event_imports set removed_at = now(), removed_reason = 'organizer_hidden'
       where event_id = v_event and source_id = p_source and removed_at is null;
      update public.events set status = 'cancelled', cancelled_at = now(), cancel_reason = 'Hidden by the organizer.'
       where id = v_event and kind = 'imported' and status = 'published';
      v_done := array_append(v_done, 'hide');
    else
      update public.event_imports set removed_at = null, removed_reason = null, content_hash = ''
       where event_id = v_event and source_id = p_source and removed_reason = 'organizer_hidden';
      get diagnostics v_n = row_count;
      if v_n > 0 then
        update public.events set status = 'published', cancelled_at = null, cancel_reason = null
         where id = v_event and kind = 'imported' and cancel_reason = 'Hidden by the organizer.';
      end if;
      v_done := array_append(v_done, 'unhide');
    end if;
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
    values (uid, case when p_args ? 'hide' then 'organizer_hide' else 'organizer_unhide' end, 'event', v_event,
            left('source ' || v_src.slug, 500));
  end if;

  if p_args ? 'stop' then
    if jsonb_typeof(p_args -> 'stop') <> 'boolean' then
      raise exception 'invalid_args' using errcode = '22023';
    end if;
    if (p_args ->> 'stop')::boolean then
      perform public.feed_source_withdraw(p_source, 'stop');
      update public.feed_sources set enabled = false, organizer_stopped_at = now() where id = p_source;
    else
      -- Back to the collector: a connected feed is switched on by its next good run.
      update public.feed_sources set organizer_stopped_at = null where id = p_source;
    end if;
    v_done := array_append(v_done, 'stop');
  end if;

  if p_args ? 'feed_url' then
    if v_src.origin <> 'organizer' or v_src.kind <> 'ics' then
      raise exception 'not_connected' using errcode = '22023';
    end if;
    select * into v_claim from public.organizer_claims where id = v_src.organizer_claim_id;
    v_chk := public.source_url_check(p_args ->> 'feed_url');
    if not (v_chk ->> 'ok')::boolean then
      raise exception '%', v_chk ->> 'error' using errcode = '22023';
    end if;
    if v_claim.method = 'feed' and (v_chk ->> 'url') is distinct from v_claim.feed_url then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    if v_claim.method <> 'feed' and not (v_chk ->> 'host' = v_claim.host
         or public.registrable_domain(v_chk ->> 'host') = public.registrable_domain(v_claim.host)) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    update public.feed_sources set url = v_chk ->> 'url', last_error = null where id = p_source;
    v_done := array_append(v_done, 'feed_url');
  end if;

  if p_args ? 'images_licensed' then
    if v_src.origin <> 'organizer' or jsonb_typeof(p_args -> 'images_licensed') <> 'boolean' then
      raise exception 'not_connected' using errcode = '22023';
    end if;
    update public.feed_sources
       set images_licensed = (p_args ->> 'images_licensed')::boolean,
           organizer_images_at = case when (p_args ->> 'images_licensed')::boolean then now() end
     where id = p_source;
    v_done := array_append(v_done, 'images_licensed');
  end if;

  if p_args ? 'refresh' then
    if v_src.origin <> 'organizer' then
      raise exception 'not_connected' using errcode = '22023';
    end if;
    if v_src.organizer_refresh_requested_at is null
       and (v_src.collector_seen_at is null or v_src.collector_seen_at < now() - interval '1 hour') then
      update public.feed_sources set organizer_refresh_requested_at = now() where id = p_source;
    end if;
    v_done := array_append(v_done, 'refresh');
  end if;

  if cardinality(v_done) = 0 then
    raise exception 'invalid_args' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_done) d where d not in ('hide', 'unhide')) then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
    values (uid, 'organizer_update', 'source', p_source, left(array_to_string(v_done, ', '), 500));
  end if;
  return jsonb_build_object('source_id', p_source, 'changed', to_jsonb(v_done));
end $$;
comment on function public.organizer_source_update(uuid, jsonb) is
  'Migration 62, the source''s verified owner or a moderator: p_args {default_hub: hub slug (active, 18+) or null, hide: event id, unhide: event id (an upcoming item the source lists as primary; hidden items are cancelled "Hidden by the organizer." and never republished until unhidden), stop: true (off, upcoming items withdrawn) | false (back to the collector), feed_url (a connected feed only: same host or registrable domain as the claim, or the claimed feed), images_licensed (a connected feed only; stored with the time), refresh: true (a connected feed: collected by the next verify run, once an hour)}. Logged. Imported items still rank below plans, and a claim never makes them RSVP-able. Errors: not_authenticated, forbidden, invalid_args, invalid_hub, invalid_event, not_connected, host_mismatch, the url_* errors.';

-- ---------------------------------------------------------------------------
-- 6. connect_organizer_feed
-- ---------------------------------------------------------------------------
-- The collector region for a connected feed: the one holding the point, else a new one (rounded
-- to 0.1 degree, 25 km), within the 10-a-day cap of new regions.
create or replace function public.organizer_region_for(p_point extensions.geography)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_region uuid;
begin
  select r.id into v_region from public.collector_regions r
   where extensions.ST_DWithin(r.point, p_point, r.radius_km * 1000.0)
   order by extensions.ST_Distance(r.point, p_point), r.id limit 1;
  if v_region is not null then
    return v_region;
  end if;
  perform pg_advisory_xact_lock(hashtext('public.collector_regions'));
  if (select count(*) from public.collector_regions r
       where r.first_user_at is not null and r.created_at >= date_trunc('day', now(), 'UTC')) >= 10 then
    return null;
  end if;
  insert into public.collector_regions (point, radius_km, label, first_user_at, priority, home_count)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(
            round(extensions.ST_X(p_point::extensions.geometry)::numeric, 1)::double precision,
            round(extensions.ST_Y(p_point::extensions.geometry)::numeric, 1)::double precision), 4326)::extensions.geography,
          25, null, date_trunc('day', now(), 'UTC'), 10, 0)
  returning id into v_region;
  return v_region;
end $$;
comment on function public.organizer_region_for(extensions.geography) is
  'Migration 62: the collector region that holds a point, or a new one (point rounded to 0.1 degree, 25 km) while fewer than 10 regions were added today; else null. Internal.';

create or replace function public.connect_organizer_feed(p_url text, p_claim uuid,
                                                        p_lat double precision default null,
                                                        p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_claim  public.organizer_claims%rowtype;
  v_chk    jsonb;
  v_url    text;
  v_host   text;
  v_point  extensions.geography;
  v_region public.collector_regions%rowtype;
  v_rid    uuid;
  v_src    public.feed_sources%rowtype;
  v_id     uuid := gen_random_uuid();
  v_name   text;
  v_parent public.feed_sources%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_claim from public.organizer_claims where id = p_claim for update;
  if not found or v_claim.user_id <> uid then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_chk := public.source_url_check(p_url);
  if not (v_chk ->> 'ok')::boolean then
    raise exception '%', v_chk ->> 'error' using errcode = '22023', hint = coalesce(v_chk ->> 'reason', '');
  end if;
  v_url := v_chk ->> 'url';
  v_host := v_chk ->> 'host';
  if v_claim.status = 'verified' and v_claim.method <> 'feed' then
    if not (v_host = v_claim.host or public.registrable_domain(v_host) = public.registrable_domain(v_claim.host)) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  elsif v_claim.method = 'feed' and v_claim.status in ('pending', 'verified') then
    if v_url is distinct from v_claim.feed_url then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  else
    raise exception 'claim_not_verified' using errcode = 'P0001';
  end if;

  select * into v_src from public.feed_sources f where f.organizer_claim_id = v_claim.id and f.origin = 'organizer'
     and f.kind = 'ics' order by f.created_at limit 1 for update;
  if found then
    update public.feed_sources set url = v_url, last_error = null where id = v_src.id;
    return jsonb_build_object('source_id', v_src.id, 'slug', v_src.slug, 'created', false, 'enabled', v_src.enabled);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('connect_organizer_feed:' || uid::text, 0));
  if (select count(*) from public.feed_sources f
        join public.organizer_claims c on c.id = f.organizer_claim_id
       where f.origin = 'organizer' and c.user_id = uid and f.organizer_stopped_at is null) >= 3 then
    raise exception 'feed_limit' using errcode = 'P0001';
  end if;

  -- The region: the owner's saved home, else the point they picked (rounded to 0.1 degree).
  select pp.home_point into v_point from public.profile_private pp where pp.user_id = uid;
  if v_point is null and p_lat between -90 and 90 and p_lng between -180 and 180 then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(round(p_lng::numeric, 1)::double precision,
                                                             round(p_lat::numeric, 1)::double precision), 4326)::extensions.geography;
  end if;
  if v_point is null then
    raise exception 'region_required' using errcode = '22023';
  end if;
  v_rid := public.organizer_region_for(v_point);
  if v_rid is null then
    raise exception 'region_unavailable' using errcode = 'P0001';
  end if;
  select * into v_region from public.collector_regions where id = v_rid;

  select * into v_parent from public.feed_sources where id = v_claim.source_id;
  v_name := left(coalesce(v_parent.name, 'Calendar from ' || v_claim.host), 80);
  insert into public.feed_sources
    (slug, kind, url, name, attribution, homepage_url, enabled, collector, lane, origin,
     organizer_id, organizer_verified_at, organizer_claim_id, collector_region_id,
     region_point, region_radius_km, region_label, region_timezone)
  values
    ('org-' || substr(replace(v_id::text, '-', ''), 1, 12), 'ics', v_url, v_name,
     left('Listed by the organizer (' || v_claim.host || ').', 300),
     coalesce(v_parent.homepage_url, 'https://' || v_claim.host || '/'), false, true, 'feed', 'organizer',
     case when v_claim.status = 'verified' then uid end,
     case when v_claim.status = 'verified' then v_claim.verified_at end,
     v_claim.id, v_rid, v_region.point, v_region.radius_km, v_region.label, v_region.timezone)
  returning * into v_src;
  return jsonb_build_object('source_id', v_src.id, 'slug', v_src.slug, 'created', true, 'enabled', false);
end $$;
comment on function public.connect_organizer_feed(text, uuid, double precision, double precision) is
  'Migration 62, the claim''s owner: connects an ICS feed (https or webcal, public host, not denylisted: source_url_check) to a verified claim (the feed''s host or registrable domain must match the claim''s) or to a pending or verified feed claim for that same URL (verified when the verify job finds the token in it). Creates (or, for the same claim, re-points) an organizer-origin feed_sources row org-<12 hex>, kind ics, lane feed, collector, in the collector region holding the owner''s saved home, else the p_lat/p_lng they picked (rounded to 0.1 degree; a new region when none holds it). The row starts off and the first good run switches it on (collector_ingest_events). At most 3 live connected feeds a person (feed_limit). Errors: not_authenticated, not_found, the url_* errors, host_mismatch, claim_not_verified, feed_limit, region_required, region_unavailable. Returns {source_id, slug, created, enabled}.';

-- ---------------------------------------------------------------------------
-- 7. Eventbrite connection (key-gated in the Edge Function)
-- ---------------------------------------------------------------------------
create table if not exists public.organizer_oauth_states (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  provider   text not null default 'eventbrite',
  state_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  used_at    timestamptz,
  constraint organizer_oauth_states_provider check (provider in ('eventbrite')),
  constraint organizer_oauth_states_hash check (state_hash ~ '^[0-9a-f]{64}$')
);
create index if not exists organizer_oauth_states_user_idx on public.organizer_oauth_states (user_id, created_at);
comment on table public.organizer_oauth_states is
  'Migration 62: one row per OAuth start (Eventbrite organizer connection), bound to the person, single use, 10-minute expiry. Only the SHA-256 of the state is stored. Service role only.';
alter table public.organizer_oauth_states enable row level security;
revoke all on public.organizer_oauth_states from public, anon, authenticated;
grant all on public.organizer_oauth_states to service_role;

create or replace function public.organizer_oauth_start(p_user uuid, p_state_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or not exists (select 1 from public.profiles p where p.id = p_user and p.status = 'active'
                                                                    and p.deleted_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if coalesce(p_state_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_state' using errcode = '22023';
  end if;
  delete from public.organizer_oauth_states where expires_at < now() - interval '1 day';
  if (select count(*) from public.organizer_oauth_states s
       where s.user_id = p_user and s.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.organizer_oauth_states (user_id, state_hash) values (p_user, p_state_hash);
  return jsonb_build_object('expires_in', 600);
end $$;
comment on function public.organizer_oauth_start(uuid, text) is
  'Migration 62, service role (eventbrite-connect start): stores the SHA-256 of a fresh OAuth state for the person, 10 minutes, at most 10 an hour (rate_limited).';

create or replace function public.organizer_oauth_take(p_user uuid, p_state_hash text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  update public.organizer_oauth_states
     set used_at = now()
   where state_hash = p_state_hash and user_id = p_user and used_at is null and expires_at > now()
  returning id into v_id;
  return v_id is not null;
end $$;
comment on function public.organizer_oauth_take(uuid, text) is
  'Migration 62, service role (eventbrite-connect callback): true once for an unused, unexpired state issued to this person; false for another person''s state, a used one or an expired one.';

create or replace function public.organizer_eventbrite_store(p_user uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_name   text := 'eventbrite:' || p_user::text;
  v_secret uuid;
  v_src    public.feed_sources%rowtype;
  v_point  extensions.geography;
  v_rid    uuid;
  v_region public.collector_regions%rowtype;
  v_id     uuid := gen_random_uuid();
begin
  if p_user is null or not exists (select 1 from public.profiles p where p.id = p_user and p.status = 'active') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if coalesce(p_token, '') !~ '^[A-Za-z0-9._-]+$' or char_length(p_token) not between 8 and 500 then
    raise exception 'invalid_token' using errcode = '22023';
  end if;
  select s.id into v_secret from vault.secrets s where s.name = v_name;
  if v_secret is null then
    perform vault.create_secret(p_token, v_name, 'Eventbrite organizer token (migration 62)');
  else
    perform vault.update_secret(v_secret, p_token);
  end if;
  select * into v_src from public.feed_sources f
   where f.origin = 'organizer' and f.kind = 'eventbrite' and f.organizer_id = p_user;
  if found then
    update public.feed_sources set organizer_stopped_at = null, last_error = null where id = v_src.id;
    return jsonb_build_object('source_id', v_src.id, 'created', false);
  end if;
  select pp.home_point into v_point from public.profile_private pp where pp.user_id = p_user;
  if v_point is not null then
    v_rid := public.organizer_region_for(v_point);
    select * into v_region from public.collector_regions where id = v_rid;
  end if;
  insert into public.feed_sources
    (slug, kind, url, name, attribution, homepage_url, enabled, collector, lane, origin,
     organizer_id, organizer_verified_at, collector_region_id, region_point, region_radius_km, region_label,
     region_timezone)
  values ('org-' || substr(replace(v_id::text, '-', ''), 1, 12), 'eventbrite',
          'https://www.eventbriteapi.com/v3/users/me/organizations/', 'Eventbrite events',
          'Listed by the organizer from their Eventbrite account.', null, false, true, 'api', 'organizer',
          p_user, now(), v_rid, v_region.point, v_region.radius_km, v_region.label, v_region.timezone)
  returning * into v_src;
  return jsonb_build_object('source_id', v_src.id, 'created', true);
end $$;
comment on function public.organizer_eventbrite_store(uuid, text) is
  'Migration 62, service role (eventbrite-connect callback): keeps the person''s Eventbrite token in Supabase Vault (secret eventbrite:<user id>, never a table column) and creates their organizer-origin source (kind eventbrite, lane api, off until its first good run) in the region of their saved home.';

create or replace function public.organizer_eventbrite_sources(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'source_id', f.id, 'slug', f.slug, 'token', ds.decrypted_secret,
           'region', jsonb_build_object('lat', extensions.ST_Y(f.region_point::extensions.geometry),
                                        'lng', extensions.ST_X(f.region_point::extensions.geometry),
                                        'radius_km', f.region_radius_km, 'label', f.region_label,
                                        'timezone', f.region_timezone)) order by f.collector_seen_at nulls first), '[]'::jsonb)
    from (select * from public.feed_sources f
           where f.origin = 'organizer' and f.kind = 'eventbrite' and f.organizer_id is not null
             and f.organizer_stopped_at is null and not f.denylisted
           order by f.collector_seen_at nulls first
           limit greatest(1, least(coalesce(p_limit, 20), 100))) f
    join vault.decrypted_secrets ds on ds.name = 'eventbrite:' || f.organizer_id::text;
$$;
comment on function public.organizer_eventbrite_sources(integer) is
  'Migration 62, service role only (eventbrite-connect sync, inside Supabase): the connected Eventbrite sources with their tokens from the vault. The token never leaves the Edge Function.';

-- ---------------------------------------------------------------------------
-- 8. mod_sla_hours and mod_queue (rebuilt)
-- ---------------------------------------------------------------------------
create or replace function public.mod_sla_hours(p_source text)
returns integer language sql immutable set search_path = '' as $$
  select case p_source
           when 'place_report' then 24
           when 'place'        then 72
           when 'place_edit'   then 72
           when 'claim'        then 72
           when 'calendar'     then 168
           -- Migration 62
           when 'listing_removal' then 72
           when 'organizer_claim' then 168
         end;
$$;

create or replace function public.mod_queue(p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return coalesce((
    with q as (
      -- Reports on people, plans, chapters and hubs, one item per target.
      select 'report'::text as source,
             g.target_kind || ':' || g.target_id::text as id,
             coalesce(case g.target_kind
                        when 'profile' then (select p.first_name from public.profiles p where p.id = g.target_id)
                        when 'event'   then (select e.title from public.events e where e.id = g.target_id)
                        when 'chapter' then (select c.name from public.hub_chapters c where c.id = g.target_id)
                        when 'message' then 'Message'   -- Migration 58
                        -- Migration 60
                        when 'coach_listing' then (select l.title from public.coach_listings l where l.id = g.target_id)
                        when 'coach_review' then 'Review'
                        when 'coach_review_reply' then 'Review reply'
                        when 'booking' then (select b.title from public.bookings b where b.id = g.target_id)
                        else (select h.name from public.hubs h where h.id = g.target_id) end, '') as title,
             g.target_kind as detail,
             g.priority::integer as priority, g.first_at as received_at, g.due_at, g.n as count,
             not public.moderation_is_own(g.target_kind, g.target_id, g.target_user_id) as can_act,
             jsonb_build_object('kind', g.target_kind, 'target_id', g.target_id,
                                'reasons', (select coalesce(jsonb_agg(distinct r2.reason), '[]'::jsonb)
                                              from public.reports r2
                                             where r2.target_kind = g.target_kind and r2.target_id = g.target_id
                                               and r2.status = 'open')) as ref
        from (select r.target_kind, r.target_id, min(r.priority) as priority, min(r.due_at) as due_at,
                     min(r.created_at) as first_at, count(*)::integer as n,
                     (array_agg(r.target_user_id) filter (where r.target_user_id is not null))[1] as target_user_id
                from public.reports r
               where r.status = 'open'
               group by r.target_kind, r.target_id) g
      union all
      -- NCII takedown requests.
      select 'takedown', t.id::text, t.reference,
             case when t.status = 'waiting' then 'waiting' else 'ncii' end,
             t.priority::integer, t.created_at, t.due_at, 1,
             t.target_user_id is distinct from uid,
             jsonb_build_object('request_id', t.id, 'involves_minor', t.involves_minor, 'status', t.status)
        from public.takedown_requests t
       where t.status in ('open', 'waiting')
      union all
      -- Places with open reports.
      select 'place_report', pr.place_id::text, coalesce(pl.name, ''), 'place',
             case when bool_or(pr.reason in ('private_residence', 'unsafe')) then 1 else 2 end,
             min(pr.created_at), min(pr.created_at) + make_interval(hours => public.mod_sla_hours('place_report')),
             count(*)::integer,
             not coalesce(bool_or(pr.reporter_id = uid), false),   -- Migration 54: any report the moderator filed
             jsonb_build_object('place_id', pr.place_id)
        from public.place_reports pr
        join public.places pl on pl.id = pr.place_id
       where pr.status = 'open'
       group by pr.place_id, pl.name
      union all
      -- Pending public member places.
      select 'place', pl.id::text, pl.name, 'place', 2,
             pl.created_at, pl.created_at + make_interval(hours => public.mod_sla_hours('place')), 1,
             pl.created_by is distinct from uid,
             jsonb_build_object('place_id', pl.id)
        from public.places pl
       where pl.source = 'user' and pl.is_public and pl.status = 'pending'
      union all
      -- Pending corrections on places that still exist.
      select 'place_edit', pe.id::text, pl.name, 'place', 2,
             pe.created_at, pe.created_at + make_interval(hours => public.mod_sla_hours('place_edit')), 1,
             pe.proposed_by is distinct from uid,
             jsonb_build_object('place_id', pe.place_id, 'edit_id', pe.id)
        from public.place_edits pe
        join public.places pl on pl.id = pe.place_id
       where pe.status = 'pending' and pl.status <> 'removed'
      union all
      -- Pending chapter claims.
      select 'claim', cc.id::text, cc.proposed_name, cc.kind, 2,
             cc.created_at, cc.created_at + make_interval(hours => public.mod_sla_hours('claim')), 1,
             cc.user_id <> uid,
             jsonb_build_object('claim_id', cc.id)
        from public.chapter_claims cc
       where cc.status = 'pending'
      union all
      -- Member calendar suggestions.
      select 'calendar', sc.id::text, sc.host, 'calendar', 2,
             sc.created_at, sc.created_at + make_interval(hours => public.mod_sla_hours('calendar')),
             greatest(sc.suggest_count, 1),
             true,
             jsonb_build_object('candidate_id', sc.id)
        from public.source_candidates sc
       where sc.review_status = 'pending'
      union all
      -- Migration 62: listing removal requests for imported items.
      select 'listing_removal', lr.id::text, lr.reference, lr.scope, 2,
             lr.created_at, lr.created_at + make_interval(hours => public.mod_sla_hours('listing_removal')), 1,
             true,
             jsonb_build_object('request_id', lr.id, 'scope', lr.scope, 'event_id', lr.event_id)
        from public.listing_removal_requests lr
       where lr.status = 'open'
      union all
      -- Migration 62: verified organizer claims nobody has looked at yet (verification is automatic).
      select 'organizer_claim', oc.id::text, oc.host, oc.method, 2,
             oc.verified_at, oc.verified_at + make_interval(hours => public.mod_sla_hours('organizer_claim')), 1,
             oc.user_id <> uid,
             jsonb_build_object('claim_id', oc.id, 'source_id', oc.source_id)
        from public.organizer_claims oc
       where oc.status = 'verified' and oc.reviewed_at is null
    ), picked as (
      select * from q order by q.priority, q.due_at, q.received_at, q.source, q.id limit v_limit
    )
    select jsonb_agg(jsonb_build_object(
             'source', x.source,
             'id', x.id,
             'title', x.title,
             'detail', x.detail,
             'priority', x.priority,
             'received_at', x.received_at,
             'due_at', x.due_at,
             'overdue', x.due_at < now(),
             'minutes_left', floor(extract(epoch from (x.due_at - now())) / 60)::integer,
             'count', x.count,
             'can_act', x.can_act,
             'ref', x.ref
           ) order by x.priority, x.due_at, x.received_at, x.source, x.id)
      from picked x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 9. collector_sources_for_regions (migration 46 body, rebuilt)
-- ---------------------------------------------------------------------------
create or replace function public.collector_sources_for_regions(p_regions uuid[])
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x.v order by x.o1, x.o2, x.o3), '[]'::jsonb) from (
  select jsonb_build_object(
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
             'note', 'Discovered (' || q.origin || '), ' || q.status))) as v,
         q.region_id::text as o1, (100 - q.score)::text as o2, q.id::text as o3
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
           limit 2000) q
  union all
  -- Migration 62: organizer-connected ICS feeds of the regions (verified owner, not stopped).
  select jsonb_build_object(
           'region_id', f.collector_region_id,
           'candidate_id', null,
           'status', 'organizer',
           'seed', jsonb_build_object(
             'id', f.slug, 'kind', 'ics', 'url', f.url, 'name', f.name, 'attribution', f.attribution,
             'enabled', true, 'verified', true, 'imagesLicensed', f.images_licensed,
             'note', 'Organizer-connected feed')),
         f.collector_region_id::text, 'zz', f.slug
    from public.feed_sources f
   where f.origin = 'organizer' and f.kind = 'ics'
     and f.collector_region_id = any (coalesce(p_regions, '{}'))
     and f.organizer_id is not null and f.organizer_stopped_at is null and not f.denylisted
     and public.collector_host_denied(public.source_url_host(f.url)) is null
  ) x;
$$;
comment on function public.collector_sources_for_regions(uuid[]) is
  'Service role (D-042 slice 7; GET /collector/sources?regions=): the discovered sources of the given collector regions as collector seeds [{region_id, candidate_id, status, seed: {id disc-<12 hex>, kind ics|rss|page, url, name, attribution, enabled, verified, discover, maxPages 5 for pages}}]: probation and enabled ones, and paused ones whose weekly retry is due; never locked, denylisted or unapproved ones. At most 2,000. Migration 62: plus the organizer-connected ICS feeds of those regions (status organizer, candidate_id null, seed id org-<12 hex>, imagesLicensed as the owner set it) whose owner is verified and that are not stopped or denylisted. No user ids.';

-- ---------------------------------------------------------------------------
-- 10. collector_ingest_events (migration 46 body, rebuilt)
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
  -- Migration 62: eventbrite (organizer-connected accounts).
  if v_kind is null or v_kind not in ('ics', 'rss', 'jsonld', 'localist', 'socrata', 'arcgis', 'ticketmaster', 'seatgeek',
                                      'eventbrite') then
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
  -- Migration 62: organizer rows are made only by connect_organizer_feed and the Eventbrite connection.
  if not found and v_slug ~ '^org-' then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'slug';
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
    -- Migration 62: an organizer row keeps its URL, name, attribution, homepage and the owner's image
    -- licence; any claimed row keeps the owner's default hub.
    if v_row.origin = 'organizer' then
      v_url := v_row.url;
      v_name := v_row.name;
      v_attr := v_row.attribution;
      v_home := v_row.homepage_url;
      v_licensed := v_row.images_licensed;
    end if;
    -- Migration 38: enabled is not in this update (its trigger reschedules every import-feed job).
    update public.feed_sources
       set kind = v_kind, url = v_url, name = v_name, attribution = v_attr, homepage_url = v_home,
           default_hub_id = coalesce(v_row.organizer_hub_id, v_hub), lane = v_lane, region_point = v_point, region_radius_km = v_radius,
           region_label = v_label, region_timezone = v_tz, hub_tags = v_hubs, collector_seen_at = now(),
           collector_last_run_id = coalesce(p_run_id, collector_last_run_id), images_licensed = v_licensed,
           organizer_refresh_requested_at = null   -- Migration 62
     where id = v_row.id;
    -- Migration 38: written only when it changes.
    v_enabled := case when not v_on then false
                      -- Migration 62: stopped by the owner, or an organizer row without a verified owner.
                      when v_row.organizer_stopped_at is not null then false
                      when v_row.origin = 'organizer' and (v_row.organizer_id is null or v_row.denylisted) then false
                      -- Migration 62: a connected feed is switched on by its first good run (a complete read with items).
                      when v_row.origin = 'organizer' and not v_row.enabled then
                        coalesce(p_complete, false) and not v_repeat and jsonb_array_length(p_items) > 0
                      when v_row.origin = 'organizer' then v_row.enabled
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
  'Collector ingest (D-040), service_role only (the collector Edge Function, POST /collector/ingest/events). Creates or updates the source''s feed_sources row from the seed (collector = true, kind, url, name, attribution, lane, region, hub tags, images_licensed; the first active 18+ hub tag is default_hub_id), switches it on when p_enable (never a discovered source: a disc- slug or a row with a discovery_status, which only source_candidates_record switches, migration 46) and off when the seed is off (enabled is written only when it changes), then, when the row is enabled, runs import_upsert_batch on p_items (descriptions clipped to 300 characters, cover_url dropped unless images_licensed) plus p_seen ids as seen_only items; p_complete false marks a partial read, and a second post with the same p_run_id is partial too, so no missed runs are counted for it. A slug owned by a non-collector source is refused. Migration 62: kind eventbrite; an org- slug is never created here; an organizer row keeps its URL, name, attribution and the owner''s image licence, is switched on by its first good run (complete, not a repeat, at least one item) once its owner is verified, and stays off while stopped; any row keeps the owner''s default hub (organizer_hub_id); the Refresh now flag is cleared. Errors: source_invalid (hint names the field), items_invalid, batch_too_large, run_id_invalid, source_not_collector. Returns import_upsert_batch''s counts plus enabled, created, complete and repeat_run.';

-- ---------------------------------------------------------------------------
-- 11. request_account_deletion (migration 60 body, rebuilt)
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
-- 12. pg_cron
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; listing-removal-contacts-purge not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'listing-removal-contacts-purge') then
    perform cron.unschedule('listing-removal-contacts-purge');
  end if;
  perform cron.schedule('listing-removal-contacts-purge', '29 5 * * *', 'select public.purge_listing_removal_contacts()');
end $$;

-- ---------------------------------------------------------------------------
-- 13. Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
-- Internal helpers.
revoke all on function public.registrable_domain(text) from public, anon, authenticated;
grant execute on function public.registrable_domain(text) to service_role;
revoke all on function public.collector_shared_host(text) from public, anon, authenticated;
grant execute on function public.collector_shared_host(text) to service_role;
revoke all on function public.organizer_token() from public, anon, authenticated;
revoke all on function public.feed_source_withdraw(uuid, text, text) from public, anon, authenticated;
revoke all on function public.organizer_claim_proofs(text, text) from public, anon, authenticated;
revoke all on function public.organizer_claim_apply(uuid) from public, anon, authenticated;
revoke all on function public.organizer_region_for(extensions.geography) from public, anon, authenticated;
revoke all on function public.purge_listing_removal_contacts() from public, anon, authenticated;
-- The public form goes through the site's route with the service role (as NCII requests since migration 54).
revoke all on function public.submit_listing_removal(uuid, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.submit_listing_removal(uuid, text, text, text, text, text, text, text) to service_role;
-- Members (each checks auth.uid()).
revoke all on function public.start_organizer_claim(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.start_organizer_claim(uuid, uuid, text, text, text) to authenticated;
revoke all on function public.my_organizer_claims() from public, anon;
grant execute on function public.my_organizer_claims() to authenticated;
revoke all on function public.organizer_claim_check(uuid) from public, anon;
grant execute on function public.organizer_claim_check(uuid) to authenticated;
revoke all on function public.organizer_source_update(uuid, jsonb) from public, anon;
grant execute on function public.organizer_source_update(uuid, jsonb) to authenticated;
revoke all on function public.connect_organizer_feed(text, uuid, double precision, double precision) from public, anon;
grant execute on function public.connect_organizer_feed(text, uuid, double precision, double precision) to authenticated;
-- Moderators (each refuses others with forbidden).
revoke all on function public.mod_listing_removal_queue(integer, boolean) from public, anon;
grant execute on function public.mod_listing_removal_queue(integer, boolean) to authenticated;
revoke all on function public.mod_listing_removal_resolve(uuid, text, text) from public, anon;
grant execute on function public.mod_listing_removal_resolve(uuid, text, text) to authenticated;
revoke all on function public.mod_organizer_claim_review(uuid, text, text) from public, anon;
grant execute on function public.mod_organizer_claim_review(uuid, text, text) to authenticated;
-- Service role (the collector and eventbrite-connect Edge Functions).
revoke all on function public.collector_claims_due(integer) from public, anon, authenticated;
grant execute on function public.collector_claims_due(integer) to service_role;
revoke all on function public.collector_claims_record(jsonb) from public, anon, authenticated;
grant execute on function public.collector_claims_record(jsonb) to service_role;
revoke all on function public.organizer_oauth_start(uuid, text) from public, anon, authenticated;
grant execute on function public.organizer_oauth_start(uuid, text) to service_role;
revoke all on function public.organizer_oauth_take(uuid, text) from public, anon, authenticated;
grant execute on function public.organizer_oauth_take(uuid, text) to service_role;
revoke all on function public.organizer_eventbrite_store(uuid, text) from public, anon, authenticated;
grant execute on function public.organizer_eventbrite_store(uuid, text) to service_role;
revoke all on function public.organizer_eventbrite_sources(integer) from public, anon, authenticated;
grant execute on function public.organizer_eventbrite_sources(integer) to service_role;
-- Rebuilt.
revoke all on function public.mod_sla_hours(text) from public, anon, authenticated;
grant execute on function public.mod_sla_hours(text) to service_role;
revoke all on function public.mod_queue(integer) from public, anon;
grant execute on function public.mod_queue(integer) to authenticated;
revoke all on function public.collector_sources_for_regions(uuid[]) from public, anon, authenticated;
grant execute on function public.collector_sources_for_regions(uuid[]) to service_role;
revoke all on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) to service_role;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.58')
  on conflict (key) do update set value = excluded.value, updated_at = now();
