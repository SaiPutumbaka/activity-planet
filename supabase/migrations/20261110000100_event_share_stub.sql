-- ============================================================================
-- Activity Planet schema v2 — migration 9: share stub for campus and 21+ plans
--
--   event_share_card from migration 6 returned null for anything not
--   published, public and 18+, so a shared link to a campus or 21+ plan was a
--   bare "not found". It now has three answers:
--     * published, public, 18+  -> the full card, unchanged in shape;
--     * published, campus or 21+ -> a stub, {id, restricted, hub_name}, with
--       restricted 'campus' or 'age' (campus wins; D-027 keeps campus plans
--       18+, so both never apply). The stub carries nothing the anon policy
--       hides: no title, time, place, host or counts;
--     * anything else (unknown id, cancelled) -> null.
--   Both the card and the stub also need an active hub (anon's hubs_read
--   hides inactive ones) and a host whose account is active, so a suspended,
--   banned or deleted host's plans stop resolving. Imported plans have no host
--   (events_imported_shape) and are unaffected by the host check.
--
--   Grants are restated as migration 6 wrote them (anon, authenticated), and
--   meta.schema_version goes to 2.9. Return type is still jsonb, so the
--   generated database types do not change.
--
--   Idempotent: safe to re-run.
-- ============================================================================

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
     and h.is_active
     and (e.host_id is null or p.status = 'active');
$$;

comment on function public.event_share_card(uuid) is
  'Logged-out share page and OG image. Published, public, 18+: the event fields anon may read plus host (handle, first name, avatar), hub and chapter. Published campus or 21+: {id, restricted: campus|age, hub_name}. Null for anything else, when the hub is not active, or when the host''s account is not active.';

revoke all on function public.event_share_card(uuid) from public;
grant execute on function public.event_share_card(uuid) to anon, authenticated;

insert into public.meta (key, value) values ('schema_version', '2.9')
  on conflict (key) do update set value = excluded.value, updated_at = now();
