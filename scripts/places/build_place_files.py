#!/usr/bin/env python3
"""Static place tile files (D-042 slices 3 and 4, docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md 4.4).

One gzipped JSON file per 0.5-degree place tile, built from the places table, plus the hub rule
table the app filters them with. Run by .github/workflows/places-files.yml.

  build    reads the files queue (GET /collector/files/queue, saved by the job), pages every
           queued tile's active public OpenStreetMap rows (GET /collector/tiles/{id}/rows) and writes
           into --out:
             places/v{rules_version}/{tile}.{hash16}.json.gz   one per tile
             rules/v{rules_version}.{hash16}.json.gz           hub -> rule ids
             build.json   what was built (tiles, rules, drops), the body of POST /collector/files/record
             stats.json   counts and sizes only
           hash16 is the first 16 hex of the sha256 of the uncompressed JSON, so unchanged rows give
           the same name and devices keep their cached copy. gzip has a fixed mtime, so the bytes are
           reproducible too.
  publish  merges a build into a GitHub Pages tree (the gh-pages branch checkout): copies the new
           files, updates places/manifest.json, keeps a replaced file for --keep-days so a device
           holding the previous answer can still fetch it, deletes dropped tiles' files, and writes
           .nojekyll, index.html and LICENSE.md (ODbL 1.0, © OpenStreetMap contributors).

File layout (format v1), compact arrays:
  tile:  {"v":1,"tile":198375,"rules_version":1,"license":"ODbL-1.0",
          "attribution":"© OpenStreetMap contributors","cols":[...COLS],"rows":[[...], ...]}
         a row is [osm_ref, lng, lat, kind, name, rule_ids, address, locality, hours, website, tags]
  rules: {"v":1,"rules_version":1,"cols":["id","slug","name","emoji","mode","rules"],"hubs":[...]}

Prints counts and sizes only; the rows are public ODbL facts but are not printed. `--rows-dir`
builds from saved pages instead of the network (tests and local checks).
"""
import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

USER_AGENT = "ActivityPlanet-places-files/1 (+https://github.com/SaiPutumbaka/activity-planet)"
FORMAT = 1
COLS = ["osm_ref", "lng", "lat", "kind", "name", "rule_ids", "address", "locality", "hours", "website", "tags"]
RULE_COLS = ["id", "slug", "name", "emoji", "mode", "rules"]
TAG_KEYS = {"sport", "religion", "denomination", "lgbtq", "access", "fee", "lit", "indoor", "surface",
            "hoops", "wheelchair", "wikidata", "phone", "brand"}
ATTRIBUTION = "© OpenStreetMap contributors"
PAGE = 5000
MAX_PAGES = 100            # 500k rows: far past the 60k-row tile guard
MAX_TILE_ROWS = 200000
WARN_FILE_BYTES = 3 * 1024 * 1024    # design 4.4: split into 0.25-degree subtiles past about 3 MB
MAX_FILE_BYTES = 50 * 1024 * 1024
OSM_REF = re.compile(r"^[nwr][0-9]{1,15}$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
UUID_ANY = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
TILE_PATH = re.compile(r"^places/v[0-9]{1,4}/([0-9]{1,6})\.[0-9a-f]{16}\.json\.gz$")
RULES_PATH = re.compile(r"^rules/v[0-9]{1,4}\.[0-9a-f]{16}\.json\.gz$")


class FilesError(Exception):
    pass


# ---------------------------------------------------------------------------
# Checks and encoding
# ---------------------------------------------------------------------------

def check_row(row, tile, n):
    """Raises FilesError unless row is one file row."""
    if not isinstance(row, list) or len(row) != len(COLS):
        raise FilesError(f"tile {tile} row {n}: not a {len(COLS)}-element array")
    ref, lng, lat, kind, name, rules, addr, loc, hours, web, tags = row
    if not isinstance(ref, str) or not OSM_REF.match(ref):
        raise FilesError(f"tile {tile} row {n}: bad osm_ref")
    for v, lo, hi, what in ((lng, -180, 180, "lng"), (lat, -90, 90, "lat")):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
            raise FilesError(f"tile {tile} row {n}: bad {what}")
    if not isinstance(kind, str) or not kind:
        raise FilesError(f"tile {tile} row {n}: bad kind")
    if not isinstance(name, str) or not 1 <= len(name) <= 120:
        raise FilesError(f"tile {tile} row {n}: bad name")
    if not isinstance(rules, list) or not rules or not all(isinstance(r, int) and not isinstance(r, bool) and r > 0 for r in rules):
        raise FilesError(f"tile {tile} row {n}: bad rule_ids")
    for v, what in ((addr, "address"), (loc, "locality"), (hours, "hours"), (web, "website")):
        if v is not None and not isinstance(v, str):
            raise FilesError(f"tile {tile} row {n}: bad {what}")
    if web is not None and not web.startswith(("http://", "https://")):
        raise FilesError(f"tile {tile} row {n}: bad website")
    if tags is not None and (not isinstance(tags, dict) or not set(tags) <= TAG_KEYS):
        raise FilesError(f"tile {tile} row {n}: tags outside the allowlist")
    # No id of ours: a uuid outside the website (a public OSM URL may hold one) means a leak.
    if UUID_ANY.search(json.dumps([v for i, v in enumerate(row) if i != COLS.index("website")], ensure_ascii=False)):
        raise FilesError(f"tile {tile} row {n}: holds an id")


def check_hubs(hubs):
    if not isinstance(hubs, list):
        raise FilesError("queue has no hubs list")
    for i, h in enumerate(hubs):
        if (not isinstance(h, list) or len(h) != len(RULE_COLS) or not isinstance(h[0], str) or not UUID.match(h[0])
                or not isinstance(h[1], str) or not isinstance(h[2], str) or not isinstance(h[3], str)
                or h[4] not in ("specific", "generic") or not isinstance(h[5], list)
                or not all(isinstance(r, int) and not isinstance(r, bool) and r > 0 for r in h[5])):
            raise FilesError(f"hub {i}: not [id, slug, name, emoji, specific|generic, rule_ids]")


def encode(obj):
    """Canonical JSON bytes, their hash16, and the reproducible gzip."""
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    h16 = hashlib.sha256(raw).hexdigest()[:16]
    gz = gzip.compress(raw, compresslevel=9, mtime=0)
    return raw, h16, gz


def tile_file(tile, rules_version, rows):
    return {"v": FORMAT, "tile": tile, "rules_version": rules_version, "license": "ODbL-1.0",
            "attribution": ATTRIBUTION, "cols": COLS, "rows": rows}


def rules_file(rules_version, hubs):
    return {"v": FORMAT, "rules_version": rules_version, "cols": RULE_COLS, "hubs": hubs}


# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

def http_get_json(url, secret, tries=4):
    req = urllib.request.Request(url, headers={"x-collector-secret": secret, "User-Agent": USER_AGENT})
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=120) as res:
                return json.loads(res.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == tries - 1:
                raise FilesError(f"GET {urllib.parse.urlsplit(url).path}: HTTP {e.code}") from None
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == tries - 1:
                raise FilesError(f"GET {urllib.parse.urlsplit(url).path}: {type(e).__name__}") from None
        time.sleep(10 * (attempt + 1))
    raise FilesError("unreachable")


def fetch_tile_rows(get_page, tile):
    """get_page(tile, after) -> {"rows", "next", "as_of"}. Returns (rows, as_of of the first page)."""
    rows, after, as_of = [], None, None
    for _ in range(MAX_PAGES):
        page = get_page(tile, after)
        if not isinstance(page, dict) or not isinstance(page.get("rows"), list):
            raise FilesError(f"tile {tile}: page has no rows list")
        if as_of is None:
            as_of = page.get("as_of")
        rows.extend(page["rows"])
        if len(rows) > MAX_TILE_ROWS:
            raise FilesError(f"tile {tile}: more than {MAX_TILE_ROWS} rows")
        after = page.get("next")
        if not after:
            return rows, as_of
        if not isinstance(after, str) or not OSM_REF.match(after):
            raise FilesError(f"tile {tile}: bad cursor")
    raise FilesError(f"tile {tile}: more than {MAX_PAGES} pages")


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def build(queue, get_page, out, max_tiles=None, log=print):
    if not isinstance(queue, dict) or not isinstance(queue.get("build"), list):
        raise FilesError("queue has no build list")
    rv = queue.get("rules_version")
    if not isinstance(rv, int) or rv < 1:
        raise FilesError("queue has no rules_version")
    hubs = queue.get("hubs")
    check_hubs(hubs)

    built, stats_tiles = [], {}
    todo = queue["build"][: max_tiles if max_tiles else None]
    for entry in todo:
        tile = entry.get("id") if isinstance(entry, dict) else None
        if not isinstance(tile, int) or not 0 <= tile <= 259199:
            raise FilesError("queue entry without a tile id")
        t0 = time.time()
        rows, as_of = fetch_tile_rows(get_page, tile)
        if not isinstance(as_of, str) or not as_of:
            raise FilesError(f"tile {tile}: no as_of")
        prev = None
        for n, row in enumerate(rows):
            check_row(row, tile, n)
            if prev is not None and not prev < row[0]:
                raise FilesError(f"tile {tile}: rows not in osm_ref order")
            prev = row[0]
        raw, h16, gz = encode(tile_file(tile, rv, rows))
        if len(gz) > MAX_FILE_BYTES:
            raise FilesError(f"tile {tile}: {len(gz)} bytes gzipped, over {MAX_FILE_BYTES}")
        path = f"places/v{rv}/{tile}.{h16}.json.gz"
        write(os.path.join(out, path), gz)
        same = entry.get("file_path") == path
        kinds = {}
        for r in rows:
            kinds[r[3]] = kinds.get(r[3], 0) + 1
        top = dict(sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0]))[:5])
        stats_tiles[str(tile)] = {"rows": len(rows), "json_bytes": len(raw), "gzip_bytes": len(gz),
                                  "bytes_per_row": round(len(gz) / len(rows), 1) if rows else 0,
                                  "unchanged": same, "seconds": round(time.time() - t0, 1), "top_kinds": top}
        built.append({"id": tile, "path": path, "sha256": hashlib.sha256(gz).hexdigest(), "bytes": len(gz),
                      "count": len(rows), "rules_version": rv, "built_from": as_of})
        warn = f" (over {WARN_FILE_BYTES} bytes: split into subtiles)" if len(gz) > WARN_FILE_BYTES else ""
        log(f"tile {tile}: {len(rows)} rows, {len(raw)} JSON bytes, {len(gz)} gzip bytes"
            f"{' (unchanged name)' if same else ''}{warn}")

    raw, h16, gz = encode(rules_file(rv, hubs))
    rpath = f"rules/v{rv}.{h16}.json.gz"
    write(os.path.join(out, rpath), gz)
    rules = {"path": rpath, "sha256": hashlib.sha256(gz).hexdigest(), "bytes": len(gz), "rules_version": rv}
    log(f"rules: {len(hubs)} hubs, {len(raw)} JSON bytes, {len(gz)} gzip bytes")

    drop = [t for t in queue.get("drop") or [] if isinstance(t, int) and 0 <= t <= 259199]
    result = {"rules": rules, "tiles": built, "drop": drop}
    write(os.path.join(out, "build.json"), json.dumps(result, indent=1).encode())
    stats = {"tiles": stats_tiles, "rules": {"hubs": len(hubs), "json_bytes": len(raw), "gzip_bytes": len(gz)},
             "total_rows": sum(t["count"] for t in built), "total_gzip_bytes": sum(t["bytes"] for t in built),
             "queued": len(queue["build"]), "built": len(built), "drop": len(drop)}
    write(os.path.join(out, "stats.json"), json.dumps(stats, indent=1).encode())
    return result, stats


def record_body(build_result, published):
    """The POST /collector/files/record body: built (or published) tiles and rules, cleared drops."""
    tiles = list(build_result["tiles"]) + [{"id": t, "clear": True} for t in build_result.get("drop", [])]
    return {"published": bool(published), "rules": build_result["rules"], "tiles": tiles}


# ---------------------------------------------------------------------------
# publish (GitHub Pages tree)
# ---------------------------------------------------------------------------

INDEX_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Activity Planet place files</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem">
<h1>Activity Planet place files</h1>
<p>Public places for the Activity Planet hub map: one gzipped JSON file per 0.5-degree tile
(<code>places/manifest.json</code> lists them) and the hub rule table (<code>rules/</code>).</p>
<p>Data © OpenStreetMap contributors, available under the
<a href="https://opendatacommons.org/licenses/odbl/1-0/">Open Database License 1.0</a>. See LICENSE.md.</p>
</body></html>
"""

LICENSE_MD = """# Activity Planet place files

These files are a derivative database of OpenStreetMap data, made available under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL).
Any rights in individual contents of the database are licensed under the
[Database Contents License](https://opendatacommons.org/licenses/dbcl/1-0/).

Data © OpenStreetMap contributors (https://www.openstreetmap.org/copyright).

Built by `scripts/places/build_place_files.py` in https://github.com/SaiPutumbaka/activity-planet.
Each tile file is `{"v", "tile", "rules_version", "license", "attribution", "cols", "rows"}`; a row is
`[osm_ref, lng, lat, kind, name, rule_ids, address, locality, hours, website, tags]`. No member data.
"""


def utcnow():
    return datetime.now(timezone.utc).replace(microsecond=0)


def publish(site, build_dir, keep_days=7, now=None, log=print):
    now = now or utcnow()
    with open(os.path.join(build_dir, "build.json")) as f:
        result = json.load(f)
    man_path = os.path.join(site, "places", "manifest.json")
    manifest = {"v": FORMAT, "tiles": {}, "retired": []}
    if os.path.exists(man_path):
        with open(man_path) as f:
            manifest = json.load(f)
    manifest.setdefault("tiles", {})
    manifest.setdefault("retired", [])

    def retire(path):
        if path and not any(r["path"] == path for r in manifest["retired"]):
            manifest["retired"].append({"path": path, "replaced_at": now.isoformat()})

    added = 0
    for t in result["tiles"]:
        if not TILE_PATH.match(t["path"]) or TILE_PATH.match(t["path"]).group(1) != str(t["id"]):
            raise FilesError(f"bad tile path {t['path']}")
        src = os.path.join(build_dir, t["path"])
        dst = os.path.join(site, t["path"])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        old = manifest["tiles"].get(str(t["id"]), {}).get("path")
        if old != t["path"]:
            retire(old)
            added += 1
        manifest["tiles"][str(t["id"])] = {"path": t["path"], "sha256": t["sha256"], "bytes": t["bytes"],
                                           "count": t["count"], "rules_version": t["rules_version"],
                                           "built_from": t["built_from"], "published_at": now.isoformat()}
    rules = result["rules"]
    if not RULES_PATH.match(rules["path"]):
        raise FilesError(f"bad rules path {rules['path']}")
    os.makedirs(os.path.join(site, "rules"), exist_ok=True)
    shutil.copyfile(os.path.join(build_dir, rules["path"]), os.path.join(site, rules["path"]))
    if manifest.get("rules", {}).get("path") != rules["path"]:
        retire(manifest.get("rules", {}).get("path"))
    manifest["rules"] = dict(rules, published_at=now.isoformat())

    for t in result.get("drop", []):
        old = manifest["tiles"].pop(str(t), None)
        if old:
            p = os.path.join(site, old["path"])
            if os.path.exists(p):
                os.remove(p)
            log(f"dropped tile {t}")
    current = {e["path"] for e in manifest["tiles"].values()} | {manifest["rules"]["path"]}
    keep, removed = [], 0
    for r in manifest["retired"]:
        if r["path"] in current:
            continue
        age = now - datetime.fromisoformat(r["replaced_at"])
        if age > timedelta(days=keep_days):
            p = os.path.join(site, r["path"])
            if os.path.exists(p):
                os.remove(p)
            removed += 1
        else:
            keep.append(r)
    manifest["retired"] = keep
    manifest["v"] = FORMAT
    manifest["updated_at"] = now.isoformat()
    manifest["attribution"] = ATTRIBUTION
    manifest["license"] = "ODbL-1.0"
    os.makedirs(os.path.dirname(man_path), exist_ok=True)
    with open(man_path, "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
    for name, body in ((".nojekyll", ""), ("index.html", INDEX_HTML), ("LICENSE.md", LICENSE_MD)):
        with open(os.path.join(site, name), "w") as f:
            f.write(body)
    total = sum(e["bytes"] for e in manifest["tiles"].values())
    log(f"published {len(result['tiles'])} tiles ({added} new names), {len(manifest['tiles'])} in the manifest, "
        f"{total} bytes; {removed} replaced files removed, {len(keep)} kept for {keep_days} days")
    return manifest


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--queue", required=True, help="the saved GET /collector/files/queue answer")
    b.add_argument("--out", required=True)
    b.add_argument("--base-url", help="https://<ref>.supabase.co/functions/v1/collector")
    b.add_argument("--rows-dir", help="read rows_{tile}.json pages instead of the network")
    b.add_argument("--max-tiles", type=int, default=0)
    r = sub.add_parser("record-body")
    r.add_argument("--build-dir", required=True)
    r.add_argument("--published", action="store_true")
    p = sub.add_parser("publish")
    p.add_argument("--site", required=True, help="the gh-pages checkout")
    p.add_argument("--build-dir", required=True)
    p.add_argument("--keep-days", type=int, default=7)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "build":
            with open(a.queue) as f:
                queue = json.load(f)
            if a.rows_dir:
                def get_page(tile, after):
                    with open(os.path.join(a.rows_dir, f"rows_{tile}.json")) as f:
                        rows = json.load(f)
                    return {"rows": rows, "next": None, "as_of": "2026-11-04T00:00:00Z"}
            else:
                secret = os.environ.get("COLLECTOR_SECRET", "")
                if not a.base_url or len(secret) < 32:
                    raise FilesError("--base-url and COLLECTOR_SECRET are needed")

                def get_page(tile, after):
                    q = {"limit": str(PAGE)}
                    if after:
                        q["after"] = after
                    return http_get_json(f"{a.base_url}/tiles/{tile}/rows?{urllib.parse.urlencode(q)}", secret)
            build(queue, get_page, a.out, a.max_tiles or None)
        elif a.cmd == "record-body":
            with open(os.path.join(a.build_dir, "build.json")) as f:
                print(json.dumps(record_body(json.load(f), a.published), separators=(",", ":")))
        else:
            publish(a.site, a.build_dir, a.keep_days)
    except FilesError as e:
        print(f"places files: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
