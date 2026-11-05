#!/usr/bin/env python3
"""Region trial (D-042 slice 12, docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md 10).

One place a member could live (scripts/places/region_trial.json), run end to end on STAGING by
.github/workflows/region-trial.yml:

  home-sql    SQL that saves the trial's home point the way a member's home save does
              (collector_note_home_point: tile demand, edge neighbours, the event region), with no
              user id. Prints only counts and tile ids.
  report-sql  SQL for one transaction, rolled back: the region (no point), its tiles (status,
              rows, bytes in Postgres, file sizes), the latest OSM run per tile, discovery and
              shows state, events near the home, and map_in_view as a signed-out visitor for each
              view and hub chip, from Postgres (p_files off) and from the static files (p_files on,
              with the trial tiles' built files counted as published inside the transaction only).
              Each result is one line TRIAL:<key>:<base64 JSON>.
  decode      the db query output to <dir>/report.json (never printed: map answers hold public
              place names, nothing else).
  summary     counts and sizes from report.json (and app.json, the app check's result) for the log.

Numbers only are printed: no point, no user id, no place names.
"""

import argparse
import base64
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TILE_DEG = 0.5
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
NAME = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
LINE = re.compile(r"TRIAL:([a-z0-9_:.-]{1,120}):([A-Za-z0-9+/=]+)")


def load_trial(name, path=None):
    with open(path or os.path.join(HERE, "region_trial.json"), encoding="utf-8") as f:
        trials = json.load(f)["trials"]
    if not NAME.match(name) or name not in trials:
        raise SystemExit(f"unknown trial: {name}")
    t = trials[name]
    lat, lng = (float(x) for x in t["home"])
    if not (-85 <= lat <= 85 and -180 <= lng <= 180):
        raise SystemExit("home out of range")
    views = {}
    for k, b in t["views"].items():
        if not NAME.match(k):
            raise SystemExit(f"bad view name: {k}")
        w, s, e, n = (float(x) for x in b)
        if not (-180 <= w < e <= 180 and -85 <= s < n <= 85) or e - w > 1.5 or n - s > 1.0:
            raise SystemExit(f"bad view: {k}")
        views[k] = (w, s, e, n)
    hubs = [h for h in t.get("hubs", [])]
    for h in hubs:
        if not SLUG.match(h):
            raise SystemExit(f"bad hub slug: {h}")
    return {"name": name, "label": t.get("label", name), "lat": lat, "lng": lng,
            "views": views, "hubs": hubs, "searches": list(t.get("searches", []))}


def tile_id(lat, lng):
    row = min(359, max(0, math.floor((lat + 90) / TILE_DEG)))
    col = min(719, max(0, math.floor((lng + 180) / TILE_DEG)))
    return row * 720 + col


def view_tiles(trial):
    """Tile ids the home and every view touch."""
    ids = {tile_id(trial["lat"], trial["lng"])}
    for w, s, e, n in trial["views"].values():
        r0, r1 = math.floor((s + 90) / TILE_DEG), math.floor((n + 90) / TILE_DEG)
        c0, c1 = math.floor((w + 180) / TILE_DEG), math.floor((e + 180) / TILE_DEG)
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                ids.add(r * 720 + c)
    return sorted(ids)


def pt(trial):
    return (f"extensions.ST_SetSRID(extensions.ST_MakePoint({trial['lng']!r}, {trial['lat']!r}), 4326)"
            "::extensions.geography")


def home_sql(trial):
    # Two statements: the second must see what the first wrote (one statement keeps one snapshot).
    return (
        "create temp table trial_home as select public.collector_note_home_point(" + pt(trial)
        + ", null) as region_added;\n"
        "select 'TRIAL:home:' || replace(encode(convert_to(jsonb_build_object("
        "'region_added', (select region_added from trial_home), "
        "'tiles', (select jsonb_agg(jsonb_build_array(t.id, t.status, t.demand) order by t.id) "
        "from public.place_tiles t where t.id = any (array[" + ",".join(str(i) for i in neighbour_tiles(trial)) + "])), "
        "'regions_near', (select count(*) from public.collector_regions r "
        "where extensions.ST_DWithin(r.point, " + pt(trial) + ", r.radius_km * 1000.0))"
        ")::text, 'UTF8'), 'base64'), E'\\n', '') as v;\n"
    )


def neighbour_tiles(trial):
    t = tile_id(trial["lat"], trial["lng"])
    r, c = divmod(t, 720)
    return sorted({(r + dr) * 720 + (c + dc) % 720 for dr in (-1, 0, 1) for dc in (-1, 0, 1)
                   if 0 <= r + dr <= 359})


def _out(key, expr):
    return f"insert into trial_out (k, v) select '{key}', ({expr});\n"


def report_sql(trial):
    p = pt(trial)
    tiles = "array[" + ",".join(str(i) for i in sorted(set(view_tiles(trial)) | set(neighbour_tiles(trial)))) + "]::integer[]"
    hubs = ",".join(f"'{h}'" for h in trial["hubs"])
    s = []
    s.append("begin;\n")
    s.append("create temp table trial_out (k text, v jsonb);\n")
    s.append("grant insert, select on trial_out to anon;\n")
    s.append("create temp table trial_hubs (slug text, id uuid);\n")
    s.append("grant select on trial_hubs to anon;\n")
    if hubs:
        s.append(f"insert into trial_hubs select h.slug, h.id from public.hubs h where h.slug in ({hubs});\n")
    # The region the home falls in (no point).
    s.append("create temp table trial_region as select r.* from public.collector_regions r "
             f"where extensions.ST_DWithin(r.point, {p}, r.radius_km * 1000.0) "
             f"order by extensions.ST_Distance(r.point, {p}) limit 1;\n")
    s.append(_out("region", "select jsonb_build_object('id', r.id, 'radius_km', r.radius_km, 'priority', r.priority, "
                  "'home_count', r.home_count, 'timezone', r.timezone, 'created_at', r.created_at, "
                  "'last_collected_at', r.last_collected_at, 'last_collect_sources', r.last_collect_sources, "
                  "'last_collect_items', r.last_collect_items, 'last_discovery_at', r.last_discovery_at) "
                  "from trial_region r"))
    s.append(_out("tiles", "select coalesce(jsonb_agg(jsonb_build_object("
                  "'id', t.id, 'status', t.status, 'demand', t.demand, 'row_count', t.row_count, "
                  "'osm_run_at', t.osm_run_at, 'queue_reason', t.queue_reason, 'geoapify_run_at', t.geoapify_run_at, "
                  "'file_path', t.file_path, 'file_bytes', t.file_bytes, 'file_count', t.file_count, "
                  "'file_built_at', t.file_built_at, 'file_published_at', t.file_published_at, "
                  "'places', (select jsonb_build_object('rows', count(*), "
                  "  'osm_active_public', count(*) filter (where p.source = 'osm' and p.status = 'active' and p.is_public), "
                  "  'geoapify', count(*) filter (where p.source = 'geoapify'), "
                  "  'with_website', count(*) filter (where p.website is not null), "
                  "  'with_hours', count(*) filter (where p.opening_hours is not null), "
                  "  'row_bytes', coalesce(sum(pg_column_size(p.*)), 0)) "
                  "  from public.places p where p.tile_id = t.id), "
                  "'kinds', (select jsonb_object_agg(k.kind, k.n) from (select p.kind, count(*) as n from public.places p "
                  "  where p.tile_id = t.id and p.status = 'active' group by p.kind order by count(*) desc, p.kind limit 15) k), "
                  "'run', (select r.stats from public.place_tile_runs r where r.tile_id = t.id and r.source = 'osm' "
                  "  and r.finished_at is not null order by r.finished_at desc limit 1)"
                  ") order by t.id), '[]'::jsonb) "
                  f"from public.place_tiles t where t.id = any ({tiles})"))
    s.append(_out("db", "select jsonb_build_object('database_bytes', pg_database_size(current_database()), "
                  "'places_bytes', pg_total_relation_size('public.places'), "
                  "'places_rows', (select count(*) from public.places), "
                  "'rules_file', (select m.value::jsonb from public.meta m where m.key = 'places_rules_file'), "
                  "'places_files', (select m.value from public.meta m where m.key = 'places_files'), "
                  "'eu_discovery', (select m.value from public.meta m where m.key = 'eu_discovery'))"))
    s.append(_out("discovery", "select jsonb_build_object("
                  "'allowed_osm_de', public.source_discovery_allowed('DE', 'osm'), "
                  "'allowed_wikidata_de', public.source_discovery_allowed('DE', 'wikidata'), "
                  "'allowed_member_de', public.source_discovery_allowed('DE', 'member'), "
                  "'candidates', (select coalesce(jsonb_object_agg(c.status, c.n), '{}'::jsonb) from ("
                  "  select sc.status, count(*) as n from public.source_candidates sc, trial_region r "
                  "  where sc.region_id = r.id group by sc.status) c), "
                  "'sources', (select coalesce(jsonb_agg(jsonb_build_object('slug', split_part(f.slug, '-', 1), "
                  "  'enabled', f.enabled, 'last_run_at', f.last_run_at, 'items', f.item_count, "
                  "  'listing_kind', f.listing_kind, 'discovery_status', f.discovery_status)), '[]'::jsonb) "
                  "  from public.feed_sources f, trial_region r where f.slug like '%-' || r.id::text), "
                  "'shows_available', public.shows_available())"))
    s.append(_out("events", "select jsonb_build_object("
                  + ", ".join(
                      f"'within_{km}km', (select coalesce(jsonb_object_agg(x.g, x.n), '{{}}'::jsonb) from ("
                      "select e.listing_kind || ':' || e.kind as g, count(*) as n from public.events e "
                      "where e.status = 'published' and e.ends_at > now() and e.starts_at < now() + interval '30 days' "
                      f"and e.approx_point is not null and extensions.ST_DWithin(e.approx_point, {p}, {km * 1000}) "
                      "group by 1) x)"
                      for km in (10, 25, 50))
                  + ")"))
    # The trial tiles' built files count as published inside this transaction only, so map_in_view
    # names them exactly as it would once Pages serves them.
    s.append("update public.meta set value = jsonb_set(value::jsonb, '{published}', 'true')::text "
             "where key = 'places_rules_file';\n")
    s.append("update public.meta set value = 'on' where key = 'places_files';\n")
    s.append("update public.place_tiles set file_published_at = coalesce(file_published_at, now()) "
             f"where id = any ({tiles}) and file_path is not null;\n")
    s.append("set local role anon;\n")
    s.append("set local request.jwt.claims = '{\"role\": \"anon\"}';\n")
    sets = [("all", "null")] + [(h.replace("-", "_"), f"array(select id from trial_hubs where slug = '{h}')")
                                for h in trial["hubs"]]
    for vname, (w, so, e, n) in trial["views"].items():
        for hname, arr in sets:
            for files in ("false", "true"):
                key = f"view:{vname}:{hname}:{'files' if files == 'true' else 'db'}"
                s.append(_out(key, f"select public.map_in_view({w!r}, {so!r}, {e!r}, {n!r}, {arr}, "
                                   f"array['places', 'plans', 'shows'], null, null, false, 800, {files})"))
    s.append("reset role;\n")
    # Place ids of the Postgres answers to their OSM refs (the files key rows by OSM ref).
    s.append(_out("refs", "select coalesce(jsonb_object_agg(p.id, p.osm_ref), '{}'::jsonb) from public.places p "
                  "where p.id in (select (x.e ->> 0)::uuid from trial_out o, "
                  "jsonb_array_elements(coalesce(o.v -> 'places', '[]'::jsonb)) x(e) where o.k like '%:db')"))
    s.append("select 'TRIAL:' || k || ':' || replace(encode(convert_to(v::text, 'UTF8'), 'base64'), E'\\n', '') as v "
             "from trial_out order by k;\n")
    s.append("rollback;\n")
    return "".join(s)


def decode(text):
    out = {}
    for key, b64 in LINE.findall(text):
        out[key] = json.loads(base64.b64decode(b64).decode("utf-8"))
    return out


def _places(v):
    return len((v or {}).get("places") or [])


def summary(report, app=None):
    lines = []
    region = report.get("region")
    lines.append("region: " + json.dumps(region, sort_keys=True))
    for t in report.get("tiles", []):
        row = {k: t.get(k) for k in ("id", "status", "demand", "row_count", "osm_run_at", "queue_reason",
                                     "file_bytes", "file_count", "file_path", "file_built_at")}
        row["places"] = t.get("places")
        lines.append("tile: " + json.dumps(row, sort_keys=True))
        if t.get("kinds"):
            lines.append(f"tile {t['id']} kinds: " + json.dumps(t["kinds"], sort_keys=True))
        if t.get("run"):
            lines.append(f"tile {t['id']} last run: " + json.dumps(t["run"], sort_keys=True))
    db = dict(report.get("db") or {})
    lines.append("db: " + json.dumps(db, sort_keys=True))
    lines.append("discovery and shows: " + json.dumps(report.get("discovery"), sort_keys=True))
    lines.append("events near the home: " + json.dumps(report.get("events"), sort_keys=True))
    for key in sorted(k for k in report if k.startswith("view:")):
        v = report[key] or {}
        files = v.get("place_files")
        lines.append(f"{key}: " + json.dumps({
            "places": _places(v), "plans": len(v.get("plans") or []), "shows": len(v.get("shows") or []),
            "cells": len(v.get("cells") or []), "hubs": len(v.get("hubs") or []),
            "mapping": v.get("mapping"), "mapping_reason": v.get("mapping_reason"),
            "zoom_in": v.get("zoom_in"), "truncated": v.get("truncated"),
            "files": None if not files else [t[0] for t in files.get("tiles", [])],
            "hidden": None if not files else len(files.get("hidden") or []),
        }, sort_keys=True))
    if app is not None:
        lines.append("app: " + json.dumps(app, sort_keys=True))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("home-sql", "report-sql", "tiles"):
        x = sub.add_parser(c)
        x.add_argument("--trial", required=True)
    d = sub.add_parser("decode")
    d.add_argument("--input", required=True)
    d.add_argument("--out", required=True)
    m = sub.add_parser("summary")
    m.add_argument("--dir", required=True)
    a = ap.parse_args(argv)
    if a.cmd in ("home-sql", "report-sql", "tiles"):
        t = load_trial(a.trial)
        if a.cmd == "home-sql":
            print(home_sql(t))
        elif a.cmd == "report-sql":
            print(report_sql(t), end="")
        else:
            print(",".join(str(i) for i in sorted(set(view_tiles(t)) | set(neighbour_tiles(t)))))
    elif a.cmd == "decode":
        with open(a.input, encoding="utf-8") as f:
            rep = decode(f.read())
        if not rep:
            print("no TRIAL lines in the report output", file=sys.stderr)
            return 1
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "report.json"), "w", encoding="utf-8") as f:
            json.dump(rep, f)
        print(f"decoded {len(rep)} results")
    else:
        with open(os.path.join(a.dir, "report.json"), encoding="utf-8") as f:
            rep = json.load(f)
        app = None
        if os.path.exists(os.path.join(a.dir, "app.json")):
            with open(os.path.join(a.dir, "app.json"), encoding="utf-8") as f:
                app = json.load(f)
        print(summary(rep, app))
    return 0


if __name__ == "__main__":
    sys.exit(main())
