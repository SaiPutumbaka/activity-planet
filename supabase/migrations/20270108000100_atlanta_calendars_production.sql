-- ============================================================================
-- Activity Planet schema v2 — migration 76: the Atlanta calendars on
--   production (Sai's yes of Nov 8). Builds on migrations 1 to 75, which
--   reached staging and are not edited. Checks:
--   supabase/tests/atlanta_calendars_production.sql.
--
--   Production creates collector rows switched off and keeps them as the
--   database has them (collector-ingest.yml, migration 37); a source Sai
--   approved is listed in meta.collector_enable_on_create (migration 74) and
--   collector_ingest_events creates it on when its seed is on (migration 75).
--   The Atlanta seeds (packages/collector/data/cities/atl.json, slug = seed
--   id) have run on production since COLLECTOR_PRODUCTION was set, so their
--   rows already exist there, switched off.
--
--     1. meta.collector_enable_on_create gains the Atlanta seeds whose latest
--        staging run (Collector ingest 42493123181, Nov 8) read items with no
--        failing streak:
--          atl-kennesaw-state     (Localist API, 288 listed, complete)
--          atl-botanical-garden   (schema.org pages, 54)
--          atl-marietta-civicplus (CivicPlus iCalendar feeds, 31, complete)
--          atl-piedmont-park      (schema.org pages, 36)
--          atl-history-center     (schema.org event pages, 15)
--          atl-contra-dance       (schema.org pages, 12)
--          atl-park-pride         (schema.org pages, 3)
--          atl-alliance-offstage  (schema.org pages, 8)
--        Left out: atl-artsatl-calendar, failing on the health panel
--        (collector_fail_streak 4: the nightly runs of Nov 5 to 8 read nothing
--        but ended events and multi-day exhibitions; only the manual run of
--        Nov 8 read 22), and atl-beltline (no event markup or feed; its seed
--        is off). Tokens already there are kept; adding one twice is a no-op.
--     2. The rows of those slugs that exist are switched on once, with
--        migration 74's guards (a collector row, not denylisted, not disc- or
--        org-, not an organizer row, not a discovered one). A seed switched
--        off later still switches its row off at the next collector post.
--     3. meta.schema_version 2.72.
--
--   Account deletion: no new table and no user-referencing column.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The approved list
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('collector_enable_on_create', 'ticketmaster,seatgeek,calgary-city-events')
  on conflict (key) do nothing;

do $$
declare
  v_add   text[] := array['atl-kennesaw-state', 'atl-botanical-garden', 'atl-marietta-civicplus', 'atl-piedmont-park',
                          'atl-history-center', 'atl-contra-dance', 'atl-park-pride', 'atl-alliance-offstage'];
  v_have  text[];
  v_token text;
begin
  select coalesce(array_agg(btrim(t.token) order by t.o) filter (where btrim(t.token) <> ''), '{}')
    into v_have
    from public.meta m
   cross join lateral unnest(string_to_array(m.value, ',')) with ordinality as t(token, o)
   where m.key = 'collector_enable_on_create';
  foreach v_token in array v_add loop
    if not (v_token = any (v_have)) then
      v_have := v_have || v_token;
    end if;
  end loop;
  update public.meta
     set value = array_to_string(v_have, ','), updated_at = now()
   where key = 'collector_enable_on_create'
     and value is distinct from array_to_string(v_have, ',');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Existing rows on, once (migration 74's guards)
-- ---------------------------------------------------------------------------
update public.feed_sources fs
   set enabled = true
 where fs.slug in ('atl-kennesaw-state', 'atl-botanical-garden', 'atl-marietta-civicplus', 'atl-piedmont-park',
                   'atl-history-center', 'atl-contra-dance', 'atl-park-pride', 'atl-alliance-offstage')
   and fs.collector and not fs.enabled and not fs.denylisted
   and fs.slug !~ '^(disc|org)-' and fs.origin is distinct from 'organizer'
   and fs.discovery_status is null
   and private.collector_enable_on_create(fs.kind, fs.slug);

-- ---------------------------------------------------------------------------
-- 3. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.72')
  on conflict (key) do update set value = excluded.value, updated_at = now();
