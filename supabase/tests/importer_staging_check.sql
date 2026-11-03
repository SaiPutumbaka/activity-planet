-- ============================================================================
-- Staging check after the first real import run (D-037): imported events
-- exist from both sources, have hubs, valid times, https links and
-- attribution, stay 18+ with a campus label, and reach Feed v2 for a fresh
-- Atlanta user with no hubs and no campus. Writes only a throwaway user and
-- rolls back. Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

do $$
declare
  v_viewer uuid := gen_random_uuid();
  r        record;
begin
  for r in
    select fs.slug, fs.last_ok_at, fs.last_error,
           count(e.id) filter (where e.status = 'published' and e.starts_at > now()) as upcoming
      from public.feed_sources fs
      left join public.event_imports ei on ei.source_id = fs.id and ei.is_primary
      left join public.events e on e.id = ei.event_id
     where fs.slug in ('gsu-localist', 'gsu-pin')
     group by fs.slug, fs.last_ok_at, fs.last_error
  loop
    raise notice 'source % last_ok_at % upcoming % last_error %', r.slug, r.last_ok_at, r.upcoming, r.last_error;
    if r.last_ok_at is null then
      raise exception 'FAIL % has never completed a run (last_error: %)', r.slug, r.last_error;
    end if;
    if r.upcoming = 0 then
      raise exception 'FAIL % produced no upcoming events', r.slug;
    end if;
  end loop;

  if exists (
    select 1 from public.events e
     where e.kind = 'imported'
       and (e.hub_id is null
            or e.ends_at <= e.starts_at
            or e.ends_at > e.starts_at + interval '3 days'
            or e.external_url !~ '^https://'
            or coalesce(e.source_name, '') = ''
            or e.host_id is not null
            or e.series_id is not null
            or e.visibility <> 'public'
            or (e.campus_id is not null and e.min_age <> 18)
            or char_length(e.location_hint) > 120
            or e.approx_point is null)
  ) then
    raise exception 'FAIL an imported event breaks the importer shape';
  end if;
  if exists (select 1 from public.events e join public.event_imports ei on ei.event_id = e.id
              where e.kind = 'imported' and not exists (select 1 from public.hubs h where h.id = e.hub_id and h.is_active)) then
    raise exception 'FAIL an imported event sits in an inactive hub';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'importer-check-' || substr(v_viewer::text, 1, 8) || '@example.com', now(), now());
  perform set_config('test.viewer', v_viewer::text, true);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.viewer'), 'role', 'authenticated')::text, true);

do $$
declare
  v_imported integer;
  v_sources  integer;
  v_labels   integer;
begin
  select count(*), count(distinct source_name) into v_imported, v_sources
    from public.feed_events_v2(now(), now() + interval '30 days', null, null, null, null, false, 200)
   where is_imported;
  raise notice 'fresh Atlanta user: % imported rows from % sources in the next 30 days', v_imported, v_sources;
  if v_imported = 0 then
    raise exception 'FAIL a fresh Atlanta user sees no imported events in feed_events_v2';
  end if;

  select count(*) into v_labels
    from public.imported_event_labels(array(
      select id from public.feed_events_v2(now(), now() + interval '30 days', null, null, null, null, false, 200)
       where is_imported));
  if v_labels = 0 then
    raise exception 'FAIL imported_event_labels returns nothing for the feed rows';
  end if;
end $$;

reset role;

select 'importer_staging_check: all assertions passed' as result;

rollback;
