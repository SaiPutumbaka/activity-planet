-- ============================================================================
-- Activity Planet schema v2 — migration 65: collector completion, Slice 2 reads.
--   docs/design/collector/COLLECTOR_COMPLETION.md section 4, Slice 2 (the app,
--   web and admin UI). Builds on migrations 62 to 64, which reached staging and
--   are not edited. Only reads the new pages need:
--
--     * imported_event_labels (latest body: 20261112000100_importer.sql) gains
--       two columns at the end, marked "Migration 65": organizer_listed (the
--       primary source has a verified owner, so the event page says "Listed by
--       the organizer") and geocode_provider (for a geocoded item, the
--       venue_geocodes provider, so the page credits OpenStreetMap or
--       Geoapify). The return type changes, so the function is dropped and
--       created again with the same grants.
--     * organizer_claim_target(p_event): authenticated; for the "Are you the
--       organizer?" page: the source's name and kind, the hosts a claim may
--       name (the source page's and homepage's hosts and registrable domains,
--       never a shared calendar host), the feed URL for an ICS source (the
--       feed proof), and whether it is claimed (by the caller or someone
--       else).
--     * organizer_source_detail(p_source): the source's verified owner, the
--       owner of the claim a connected feed belongs to, or a moderator: the
--       source settings and its next 100 upcoming items with hidden flags.
--     * mod_organizer_claims(p_closed, p_limit): moderators; organizer claims
--       for /admin/claims, with the person, the source and connected feeds.
--     * meta.schema_version 2.61.
--
--   Account deletion: no new table or column; nothing here stores a person.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. imported_event_labels (migration 11 body; the two new columns are marked)
-- ---------------------------------------------------------------------------
drop function if exists public.imported_event_labels(uuid[]);
create or replace function public.imported_event_labels(p_event_ids uuid[])
returns table (
  event_id             uuid,
  source_slug          text,
  source_kind          text,
  source_name          text,
  attribution          text,
  homepage_url         text,
  item_label           text,
  host_org             text,
  open_to_public       boolean,
  approximate_location boolean,
  affiliated_org_name  text,
  organizer_listed     boolean,   -- Migration 65
  geocode_provider     text       -- Migration 65
)
language sql stable security definer set search_path = '' as $$
  select e.id, fs.slug, fs.kind, fs.name, fs.attribution, fs.homepage_url, fs.item_label,
         ei.host_org, ei.open_to_public, (ei.point_source <> 'source'),
         o.name,
         -- Migration 65: a verified owner, and the geocoder that placed the item.
         (fs.organizer_id is not null and fs.organizer_verified_at is not null),
         case when ei.point_source = 'geocoded' then
           (select g.provider from public.venue_geocodes g
             where g.key = public.import_location_key(e.location_hint, fs.region_point) and g.status = 'ok')
         end
    from public.events e
    join public.event_imports ei on ei.event_id = e.id and ei.is_primary
    join public.feed_sources fs on fs.id = ei.source_id
    left join public.org_campuses c on c.id = fs.campus_id
    left join public.organizations o on o.id = c.org_id
   where e.id = any ((coalesce(p_event_ids, '{}'::uuid[]))[1:200])
     and e.kind = 'imported'
     and public.can_read_event(e.id)
$$;
comment on function public.imported_event_labels(uuid[]) is
  'For up to 200 imported events the caller can read: source attribution, the per-source chip (PIN: "Georgia State student org event"), the hosting organization, whether the source says the event is open to the public, whether the point is a centroid approximation, and the organization the source belongs to (shown as the D-022 not-affiliated line). Migration 65: organizer_listed (the source has a verified owner) and geocode_provider (place | venue | geoapify | nominatim | photon for a geocoded item, else null), for the event page''s "Listed by the organizer" and map credit.';

-- ---------------------------------------------------------------------------
-- 2. organizer_claim_target
-- ---------------------------------------------------------------------------
create or replace function public.organizer_claim_target(p_event uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_src  public.feed_sources%rowtype;
  v_hosts text[];
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select f.* into v_src
    from public.event_imports ei
    join public.feed_sources f on f.id = ei.source_id
    join public.events e on e.id = ei.event_id and e.kind = 'imported'
   where ei.event_id = p_event and public.can_read_event(e.id)
   order by ei.is_primary desc, ei.first_seen_at
   limit 1;
  if not found then
    raise exception 'not_imported' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct h order by h), '{}') into v_hosts
    from (select public.source_url_host(v_src.url) as h
          union all select public.source_url_host(v_src.homepage_url)
          union all select public.registrable_domain(public.source_url_host(v_src.url))
          union all select public.registrable_domain(public.source_url_host(v_src.homepage_url))) x
   where h is not null and h <> '' and not public.collector_shared_host(h)
     and public.collector_host_denied(h) is null;
  return jsonb_build_object(
    'source_name', v_src.name,
    'source_kind', v_src.kind,
    'origin', v_src.origin,
    'hosts', to_jsonb(v_hosts),
    'feed_url', case when v_src.kind = 'ics' and v_src.url ~ '^https://' then v_src.url end,
    'claimed', v_src.organizer_id is not null,
    'mine', v_src.organizer_id is not distinct from uid and v_src.organizer_id is not null,
    'source_id', case when v_src.organizer_id = uid then v_src.id end);
end $$;
comment on function public.organizer_claim_target(uuid) is
  'Migration 65, authenticated: for an imported event the caller can read, what a claim of its source may name: {source_name, source_kind, origin, hosts (the source page''s and homepage''s hosts and registrable domains, without shared calendar hosts or denylisted ones), feed_url (an ICS source''s https URL, for the feed proof), claimed, mine, source_id (only when the caller owns it)}. Errors: not_authenticated, not_imported.';

-- ---------------------------------------------------------------------------
-- 3. organizer_source_detail
-- ---------------------------------------------------------------------------
create or replace function public.organizer_source_detail(p_source uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_src   public.feed_sources%rowtype;
  v_mod   boolean := coalesce(public.is_moderator(), false);
  v_claim boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_src from public.feed_sources where id = p_source;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_claim := exists (select 1 from public.organizer_claims c
                      where c.id = v_src.organizer_claim_id and c.user_id = uid
                        and c.status in ('pending', 'verified'));
  if not (v_src.organizer_id = uid or v_claim or v_mod) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'id', v_src.id,
    'name', v_src.name,
    'kind', v_src.kind,
    'origin', v_src.origin,
    'url', case when v_src.origin = 'organizer' or v_src.organizer_id = uid or v_mod then v_src.url end,
    'homepage_url', v_src.homepage_url,
    'enabled', v_src.enabled,
    'stopped', v_src.organizer_stopped_at is not null,
    'verified', v_src.organizer_id is not null and v_src.organizer_verified_at is not null,
    'can_manage', v_src.organizer_id = uid or v_mod,
    'default_hub', (select h.slug from public.hubs h where h.id = v_src.organizer_hub_id),
    'images_licensed', coalesce(v_src.images_licensed, false),
    'refresh_requested_at', v_src.organizer_refresh_requested_at,
    'last_ok_at', v_src.last_ok_at,
    'collector_seen_at', v_src.collector_seen_at,
    'has_error', v_src.last_error is not null,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'event_id', x.id, 'title', x.title, 'starts_at', x.starts_at, 'status', x.status,
               'hidden', x.hidden) order by x.starts_at, x.id)
        from (select e.id, e.title, e.starts_at, e.status::text as status,
                     (ei.removed_reason = 'organizer_hidden') as hidden
                from public.event_imports ei
                join public.events e on e.id = ei.event_id
               where ei.source_id = p_source and ei.is_primary and e.kind = 'imported'
                 and e.starts_at > now()
                 and (ei.removed_at is null or ei.removed_reason = 'organizer_hidden')
                 and e.moderation_state is distinct from 'removed'
               order by e.starts_at, e.id
               limit 100) x), '[]'::jsonb));
end $$;
comment on function public.organizer_source_detail(uuid) is
  'Migration 65, the source''s verified owner, the owner of the (pending or verified) claim a connected feed belongs to, or a moderator: {id, name, kind, origin, url (connected feeds, the owner and moderators), homepage_url, enabled, stopped, verified, can_manage (owner or moderator: organizer_source_update), default_hub (slug), images_licensed, refresh_requested_at, last_ok_at, collector_seen_at, has_error, items [{event_id, title, starts_at, status, hidden}] (the next 100 upcoming items it lists as primary, hidden ones included, removed ones not)}. Anyone else: not_found.';

-- ---------------------------------------------------------------------------
-- 4. mod_organizer_claims
-- ---------------------------------------------------------------------------
create or replace function public.mod_organizer_claims(p_closed boolean default false, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not coalesce(public.is_moderator(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'status', c.status, 'method', c.method, 'host', c.host, 'feed_url', c.feed_url,
             'attempts', c.attempts, 'failure', c.failure, 'created_at', c.created_at,
             'verified_at', c.verified_at, 'reviewed_at', c.reviewed_at,
             'user', (select jsonb_build_object('id', p.id, 'handle', p.handle, 'first_name', p.first_name)
                        from public.profiles p where p.id = c.user_id),
             'source', (select jsonb_build_object('id', f.id, 'slug', f.slug, 'name', f.name, 'url', f.url,
                                                  'origin', f.origin, 'enabled', f.enabled)
                          from public.feed_sources f where f.id = c.source_id),
             'connected', (select count(*) from public.feed_sources f where f.organizer_claim_id = c.id),
             'can_act', c.user_id <> uid)
           order by c.updated_at desc, c.id)
      from (select * from public.organizer_claims x
             where case when coalesce(p_closed, false) then x.status in ('failed', 'revoked')
                        else x.status in ('pending', 'verified') end
             order by x.updated_at desc, x.id
             limit greatest(1, least(coalesce(p_limit, 100), 300))) c), '[]'::jsonb);
end $$;
comment on function public.mod_organizer_claims(boolean, integer) is
  'Migration 65, moderators (/admin/claims, Organizers): organizer claims, newest change first: pending and verified by default, failed and revoked with p_closed. Each: id, status, method, host, feed_url, attempts, failure, created_at, verified_at, reviewed_at, user {id, handle, first_name}, source {id, slug, name, url, origin, enabled}, connected (feeds), can_act (not the moderator''s own claim). Never the token. Errors: not_authenticated, forbidden.';

-- ---------------------------------------------------------------------------
-- 5. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.imported_event_labels(uuid[]) from public, anon;
grant execute on function public.imported_event_labels(uuid[]) to authenticated;
revoke all on function public.organizer_claim_target(uuid) from public, anon;
grant execute on function public.organizer_claim_target(uuid) to authenticated;
revoke all on function public.organizer_source_detail(uuid) from public, anon;
grant execute on function public.organizer_source_detail(uuid) to authenticated;
revoke all on function public.mod_organizer_claims(boolean, integer) from public, anon;
grant execute on function public.mod_organizer_claims(boolean, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.61')
  on conflict (key) do update set value = excluded.value, updated_at = now();
