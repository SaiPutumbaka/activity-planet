-- ============================================================================
-- Staging smoke check for the collector Edge Function (D-041 slice 4). Run as
-- the staging_file of a staging_only migrate.yml run that deploys collector
-- (staging_functions: collector), or of any later run. It sends read-only or
-- refused requests through pg_net (the same path pg_cron uses for
-- import-feed), waits for the answers and checks status codes and error
-- names. Writes nothing to public tables: the only ingest call names a tile
-- that does not exist, so ingest_places refuses it before writing. Prints
-- pass/fail only; never the secret, response bodies or rows.
--   * no secret, a wrong secret -> 401 unauthorized
--   * the right secret: GET /collector/tiles -> 200 with a tiles array
--   * POST /collector/ingest/places for an unknown tile -> 404 tile_unknown
--   * POST /collector/tiles/{id}/done with a bad body -> 400 invalid_run_id
--   * an unknown path -> 404 not_found
-- ============================================================================
begin;
create temp table collector_smoke (label text primary key, req bigint, want integer, want_error text)
  on commit preserve rows;

do $$
declare
  v_base   text := public.project_url() || '/functions/v1/collector';
  v_secret text;
  v_tile   integer;
  v_ok     jsonb;
begin
  if public.project_url() is null then
    raise exception 'FAIL meta.project_url is not set';
  end if;
  select ds.decrypted_secret into v_secret from vault.decrypted_secrets ds where ds.name = 'collector_secret';
  if v_secret is null then
    raise exception 'FAIL collector_secret missing';
  end if;
  select min(g) into v_tile from generate_series(0, 2000) as g
   where not exists (select 1 from public.place_tiles t where t.id = g);
  v_ok := jsonb_build_object('Content-Type', 'application/json', 'x-collector-secret', v_secret);

  insert into collector_smoke values
    ('no_secret', net.http_get(url := v_base || '/tiles', timeout_milliseconds := 60000), 401, 'unauthorized'),
    ('wrong_secret', net.http_get(url := v_base || '/tiles',
        headers := jsonb_build_object('x-collector-secret', repeat('0', 64)), timeout_milliseconds := 60000),
     401, 'unauthorized'),
    ('tiles', net.http_get(url := v_base || '/tiles?status=wanted,refresh&limit=5', headers := v_ok,
        timeout_milliseconds := 60000), 200, null),
    ('ingest_unknown_tile', net.http_post(url := v_base || '/ingest/places',
        body := jsonb_build_object('tile_id', v_tile, 'run_id', 'smoke-check', 'rows', '[]'::jsonb),
        headers := v_ok, timeout_milliseconds := 60000), 404, 'tile_unknown'),
    ('done_bad_body', net.http_post(url := v_base || '/tiles/' || v_tile || '/done',
        body := '{}'::jsonb, headers := v_ok, timeout_milliseconds := 60000), 400, 'invalid_run_id'),
    ('unknown_path', net.http_get(url := v_base || '/nope', headers := v_ok, timeout_milliseconds := 60000),
     404, 'not_found');
end $$;
commit;

-- pg_net sends after the commit; wait for every answer (at most about 90 s).
do $$
declare
  i integer := 0;
begin
  loop
    exit when (select count(*) from collector_smoke s join net._http_response r on r.id = s.req) = 6 or i >= 45;
    perform pg_sleep(2);
    i := i + 1;
  end loop;
end $$;

select s.label,
       r.status_code is not distinct from s.want
         and (s.want_error is null or (r.content::jsonb ->> 'error') is not distinct from s.want_error)
         and (s.label <> 'tiles' or jsonb_typeof(r.content::jsonb -> 'tiles') = 'array') as pass,
       r.status_code
  from collector_smoke s left join net._http_response r on r.id = s.req
 order by s.label;

do $$
begin
  if exists (select 1 from collector_smoke s left join net._http_response r on r.id = s.req
              where r.status_code is distinct from s.want
                 or (s.want_error is not null and (r.content::jsonb ->> 'error') is distinct from s.want_error)
                 or (s.label = 'tiles' and jsonb_typeof(r.content::jsonb -> 'tiles') is distinct from 'array')) then
    raise exception 'FAIL collector smoke: see the table above';
  end if;
end $$;

select 'collector_smoke: all checks passed' as result;
