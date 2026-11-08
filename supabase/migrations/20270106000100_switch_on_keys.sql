-- ============================================================================
-- Activity Planet schema v2 — migration 74: switch on what the Nov 8 keys
--   unlock (FOUNDER-TODO, "Keys and variables"). Builds on migrations 1 to
--   73, which reached staging and are not edited. Checks:
--   supabase/tests/switch_on_keys.sql.
--
--   Sai added on Nov 8, on both projects (Edge Function secrets, verified by
--   name only): the VAPID keys, GEOAPIFY_SERVER_KEY, TICKETMASTER_API_KEY,
--   SEATGEEK_CLIENT_ID, SIGHTENGINE_API_USER / SIGHTENGINE_API_SECRET,
--   RESEND_API_KEY and SCORECARD_TO. The Edge Functions read them at run time;
--   what still needed a database switch is here:
--
--     1. meta.chat_images 'on' (migrations 58, 71 to 73): the photo button
--        shows in chats; every photo still passes the pHash check and the
--        Sightengine classifier (4 operations a photo, monthly cap
--        meta.chat_classifier_monthly_cap 1,800) before anyone else sees it.
--     2. Collector sources that Sai approved are on when they are created
--        (production creates collector rows switched off, migration 37, and
--        keeps them as the database has them): meta.collector_enable_on_create
--        lists kinds or slugs ('ticketmaster,seatgeek,calgary-city-events'),
--        and the new trigger feed_sources_enable_on_create switches a new
--        collector row on when its kind or slug is listed (never a discovered
--        disc- row, an organizer row or a denylisted one). Rows that already
--        exist are switched on once here. Without the ticketing keys the API
--        lane never posts, so nothing changes until a key exists. Removing a
--        token from the meta value stops it for new rows; a row is switched
--        off by a data change as before.
--     3. event_share_card, rebuilt from its migration 51 body
--        (20261215000100_trust_safety.sql) with one new key,
--        source_attribution: the attribution of the source that lists an
--        imported event (its primary import, else any), so the public share
--        page shows "Contains information licensed under the Open Government
--        Licence – City of Calgary." for City of Calgary items, as the app's
--        event page already does (imported_event_labels). Nothing else in
--        the function changes.
--     4. meta.schema_version 2.70.
--
--   Account deletion: no new table and no user-referencing column.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Chat images
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('chat_images', 'on')
  on conflict (key) do update set value = excluded.value, updated_at = now();

-- ---------------------------------------------------------------------------
-- 2. Collector sources switched on when created
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('collector_enable_on_create', 'ticketmaster,seatgeek,calgary-city-events')
  on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function private.collector_enable_on_create(p_kind text, p_slug text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.meta m
     cross join lateral unnest(string_to_array(m.value, ',')) as t(token)
     where m.key = 'collector_enable_on_create'
       and btrim(t.token) <> ''
       and btrim(t.token) in (p_kind, p_slug));
$$;
comment on function private.collector_enable_on_create(text, text) is
  'Migration 74, internal: whether meta.collector_enable_on_create (comma-separated kinds or slugs) lists this collector source.';
revoke all on function private.collector_enable_on_create(text, text) from public, anon, authenticated;

create or replace function private.feed_sources_enable_on_create()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.collector and not new.enabled and not coalesce(new.denylisted, false)
     and new.slug !~ '^(disc|org)-' and new.origin is distinct from 'organizer'
     and new.discovery_status is null
     and private.collector_enable_on_create(new.kind, new.slug) then
    new.enabled := true;
  end if;
  return new;
end $$;
comment on function private.feed_sources_enable_on_create() is
  'Migration 74: before insert on feed_sources, a new collector row whose kind or slug meta.collector_enable_on_create lists is created switched on (never a disc- or org- row, an organizer row, a discovered or a denylisted one).';
revoke all on function private.feed_sources_enable_on_create() from public, anon, authenticated;

drop trigger if exists feed_sources_enable_on_create on public.feed_sources;
create trigger feed_sources_enable_on_create before insert on public.feed_sources
  for each row execute function private.feed_sources_enable_on_create();

update public.feed_sources fs
   set enabled = true
 where fs.collector and not fs.enabled and not fs.denylisted
   and fs.slug !~ '^(disc|org)-' and fs.origin is distinct from 'organizer'
   and fs.discovery_status is null
   and private.collector_enable_on_create(fs.kind, fs.slug);

-- ---------------------------------------------------------------------------
-- 3. event_share_card (migration 51 body; source_attribution added)
-- ---------------------------------------------------------------------------
create or replace function public.event_share_card(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
           when e.visibility = 'public' and e.min_age = 18 then
             jsonb_build_object(
               'id', e.id,
               'kind', e.kind,
               'title', e.title,
               'description', e.description,
               'cover_url', e.cover_url,
               'starts_at', e.starts_at,
               'ends_at', e.ends_at,
               'timezone', e.timezone,
               'min_age', e.min_age,
               'capacity', e.capacity,
               'min_headcount', e.min_headcount,
               'is_free', e.is_free,
               'price_text', e.price_text,
               'location_hint', e.location_hint,
               'approx_lat', e.approx_lat,
               'approx_lng', e.approx_lng,
               'going_count', e.going_count,
               'interested_count', e.interested_count,
               'external_url', e.external_url,
               'source_name', e.source_name,
               -- Migration 74: the listing source's attribution (open-data licences).
               'source_attribution', case when e.kind = 'imported' then
                 (select fs.attribution from public.event_imports ei
                    join public.feed_sources fs on fs.id = ei.source_id
                   where ei.event_id = e.id
                   order by ei.is_primary desc, ei.last_seen_at desc
                   limit 1) end,
               'series_id', e.series_id,
               'hub', jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji),
               'chapter', case when ch.id is not null then jsonb_build_object('id', ch.id, 'slug', ch.slug, 'name', ch.name) end,
               'host', case when p.id is not null
                            then jsonb_build_object('handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url) end
             )
           else
             jsonb_build_object(
               'id', e.id,
               'restricted', case when e.visibility = 'campus' then 'campus' else 'age' end,
               'hub_name', h.name
             )
         end
    from public.events e
    join public.hubs h on h.id = e.hub_id
    left join public.hub_chapters ch on ch.id = e.chapter_id
    left join public.profiles p on p.id = e.host_id
   where e.id = p_event_id
     and e.status = 'published'
     and e.moderation_state is null   -- Migration 51
     and h.is_active
     and (e.host_id is null or p.status = 'active');
$$;
revoke all on function public.event_share_card(uuid) from public;
grant execute on function public.event_share_card(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.70')
  on conflict (key) do update set value = excluded.value, updated_at = now();
