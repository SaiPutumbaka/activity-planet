-- ============================================================================
-- Counts after a collector ingest run (D-040; .github/workflows/collector-ingest.yml
-- runs it on staging after posting). One transaction, rolled back: it writes
-- nothing that survives (a throwaway adult user for the feed and map checks).
-- Prints counts only, by source slug and hub slug, never titles, ids, points
-- or member data (the repo and its Action logs are public).
--   * per collector source: enabled, lane, kind, the last run's stats, and its
--     upcoming published events (primary import rows)
--   * upcoming published collector events by hub
--   * as an Atlanta user (no hubs): imported collector events in
--     feed_events_v2 (next 7 days, 50 km, at most 200 rows) and imported plans in map_in_view
--     over the Atlanta metro (next 7 and 31 days)
-- ============================================================================
begin;

create temp table cic_lines (n serial, line text);
grant insert, select on cic_lines to authenticated;
grant usage on sequence cic_lines_n_seq to authenticated;

insert into cic_lines (line)
select format('source %s enabled=%s lane=%s kind=%s hub=%s last_run=%s total=%s inserted=%s updated=%s unchanged=%s linked=%s missed=%s cancelled=%s partial=%s upcoming_events=%s',
              fs.slug, fs.enabled, coalesce(fs.lane, '-'), fs.kind,
              coalesce((select h.slug from public.hubs h where h.id = fs.default_hub_id), '-'),
              coalesce(to_char(fs.last_run_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI"Z"'), '-'),
              coalesce(fs.last_stats ->> 'total', '-'), coalesce(fs.last_stats ->> 'inserted', '-'),
              coalesce(fs.last_stats ->> 'updated', '-'), coalesce(fs.last_stats ->> 'unchanged', '-'),
              coalesce(fs.last_stats ->> 'linked_duplicates', '-'), coalesce(fs.last_stats ->> 'missed', '-'),
              coalesce(fs.last_stats ->> 'cancelled', '-'), coalesce(fs.last_stats ->> 'partial', '-'),
              (select count(*) from public.event_imports ei join public.events e on e.id = ei.event_id
                where ei.source_id = fs.id and ei.is_primary and e.status = 'published' and e.ends_at > now()))
  from public.feed_sources fs
 where fs.collector
 order by fs.slug;

insert into cic_lines (line)
select format('hub %s upcoming_events=%s', h.slug, count(*))
  from public.events e
  join public.hubs h on h.id = e.hub_id
 where e.kind = 'imported' and e.status = 'published' and e.ends_at > now()
   and exists (select 1 from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
                where ei.event_id = e.id and ei.is_primary and fs.collector)
 group by h.slug
 order by count(*) desc, h.slug;

insert into cic_lines (line)
select format('totals collector_sources=%s enabled=%s upcoming_events=%s with_source_point=%s linked_copies=%s cancelled_upcoming=%s',
  (select count(*) from public.feed_sources where collector),
  (select count(*) from public.feed_sources where collector and enabled),
  (select count(distinct e.id) from public.events e join public.event_imports ei on ei.event_id = e.id and ei.is_primary
     join public.feed_sources fs on fs.id = ei.source_id and fs.collector
    where e.status = 'published' and e.ends_at > now()),
  (select count(distinct e.id) from public.events e join public.event_imports ei on ei.event_id = e.id and ei.is_primary
     join public.feed_sources fs on fs.id = ei.source_id and fs.collector
    where e.status = 'published' and e.ends_at > now() and ei.point_source = 'source'),
  (select count(*) from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id and fs.collector
    where not ei.is_primary),
  (select count(distinct e.id) from public.events e join public.event_imports ei on ei.event_id = e.id and ei.is_primary
     join public.feed_sources fs on fs.id = ei.source_id and fs.collector
    where e.status = 'cancelled' and e.starts_at > now()));

-- A throwaway adult with an Atlanta home and no hubs.
do $$
declare
  v_u uuid := gen_random_uuid();
  v_ids uuid[];
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'cic-' || substr(v_u::text, 1, 8) || '@example.com', now(), now());
  update public.profile_private set birth_date = date '1990-05-05' where user_id = v_u;
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id = v_u;
  select array_agg(e.id) into v_ids
    from public.events e
   where e.kind = 'imported' and e.status = 'published'
     and exists (select 1 from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
                  where ei.event_id = e.id and ei.is_primary and fs.collector);
  perform set_config('test.u', v_u::text, true);
  perform set_config('test.ids', coalesce(v_ids, '{}')::text, true);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  v_ids uuid[] := current_setting('test.ids')::uuid[];
  v_feed integer;
  v_feed_all integer;
  v_feed_imp integer;
  r7 jsonb;
  r31 jsonb;
begin
  select count(*) filter (where f.id = any (v_ids)), count(*), count(*) filter (where f.kind = 'imported')
    into v_feed, v_feed_all, v_feed_imp
    from public.feed_events_v2(now(), now() + interval '7 days', 33.749, -84.388, 50, null, false, 200) f;
  r7 := public.map_in_view(-84.95, 33.25, -83.85, 34.25, null, array['plans', 'shows']);
  r31 := public.map_in_view(-84.95, 33.25, -83.85, 34.25, null, array['plans', 'shows'], now(), now() + interval '31 days');
  insert into cic_lines (line) values (format(
    'atlanta_user feed_events_v2_7d rows=%s imported=%s collector=%s | map_in_view_7d plans=%s imported=%s collector=%s | map_in_view_31d plans=%s imported=%s collector=%s truncated=%s',
    v_feed_all, v_feed_imp, v_feed,
    jsonb_array_length(r7 -> 'plans'),
    (select count(*) from jsonb_array_elements(r7 -> 'plans') p where ((p.value ->> 5)::integer & 1) <> 0),
    (select count(*) from jsonb_array_elements(r7 -> 'plans') p where (p.value ->> 0)::uuid = any (v_ids)),
    jsonb_array_length(r31 -> 'plans'),
    (select count(*) from jsonb_array_elements(r31 -> 'plans') p where ((p.value ->> 5)::integer & 1) <> 0),
    (select count(*) from jsonb_array_elements(r31 -> 'plans') p where (p.value ->> 0)::uuid = any (v_ids)),
    r31 ->> 'truncated'));
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

select line as collector_ingest_counts from cic_lines order by n;

rollback;
