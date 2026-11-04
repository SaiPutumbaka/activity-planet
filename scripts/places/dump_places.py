#!/usr/bin/env python3
"""Monthly ODbL dump of public place facts (D-041 slice 14, docs/design/hub-map/HUB_MAP_DESIGN.md 8).

Pages through GET /collector/places/export (places_odbl_page, migration 35) with the collector
secret, checks that every row holds exactly the export columns (no id, no member data), and
writes into --out:

  places-YYYY-MM.ndjson.gz  one JSON object per line, sorted, gzip with a fixed mtime
  README.md                 the licence (ODbL 1.0), credits, columns and counts
  SHA256SUMS                sha256 of the two files above
  stats.json                rows, bytes, sha256 and counts by source (what the job records)

Prints counts only. Run by .github/workflows/places-dump.yml; `--from-file` builds from a saved
JSON list instead of the network (tests and local checks).
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "ActivityPlanet-places-dump/1 (+https://github.com/SaiPutumbaka/activity-planet)"
COLUMNS = ("source", "osm_ref", "name", "kind", "lat", "lng", "tags", "opening_hours", "website")
SOURCES = ("osm", "geoapify", "user", "venue")
TAG_KEYS = {"sport", "religion", "denomination", "lgbtq", "access", "fee", "lit", "indoor", "surface",
            "hoops", "wheelchair", "wikidata", "phone", "brand"}
PAGE = 5000
MAX_PAGES = 2000
MONTH = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])$")
OSM_REF = re.compile(r"^[nwr][0-9]{1,15}$")
UUID_LIKE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


class DumpError(Exception):
    pass


def check_row(row, n):
    """Raises DumpError unless the row is exactly one export row."""
    if not isinstance(row, dict):
        raise DumpError(f"row {n}: not an object")
    if set(row) != set(COLUMNS):
        raise DumpError(f"row {n}: keys {sorted(row)} are not the export columns")
    if row["source"] not in SOURCES:
        raise DumpError(f"row {n}: unknown source")
    if not isinstance(row["name"], str) or not 1 <= len(row["name"]) <= 120:
        raise DumpError(f"row {n}: bad name")
    if not isinstance(row["kind"], str) or not row["kind"]:
        raise DumpError(f"row {n}: bad kind")
    for k, lo, hi in (("lat", -90, 90), ("lng", -180, 180)):
        v = row[k]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
            raise DumpError(f"row {n}: bad {k}")
    if row["osm_ref"] is not None and not (isinstance(row["osm_ref"], str) and OSM_REF.match(row["osm_ref"])):
        raise DumpError(f"row {n}: bad osm_ref")
    if not isinstance(row["tags"], dict) or not set(row["tags"]) <= TAG_KEYS:
        raise DumpError(f"row {n}: tags outside the allowlist")
    for k in ("opening_hours", "website"):
        if row[k] is not None and not isinstance(row[k], str):
            raise DumpError(f"row {n}: bad {k}")
    # No id of any kind: a uuid anywhere in the row means something leaked into it.
    if UUID_LIKE.search(json.dumps(row)):
        raise DumpError(f"row {n}: holds an id")


def fetch_all(get_page):
    """get_page(after) -> {"rows": [...], "next": cursor|None}. Returns every row."""
    rows, after = [], None
    for _ in range(MAX_PAGES):
        page = get_page(after)
        if not isinstance(page, dict) or not isinstance(page.get("rows"), list):
            raise DumpError("export page has no rows list")
        rows.extend(page["rows"])
        after = page.get("next")
        if not after:
            return rows
    raise DumpError("export did not end")


def http_pager(base_url, secret, limit=PAGE):
    def get_page(after):
        q = {"limit": str(limit)}
        if after:
            q["after"] = after
        url = f"{base_url.rstrip('/')}/places/export?{urllib.parse.urlencode(q)}"
        req = urllib.request.Request(url, headers={"x-collector-secret": secret, "User-Agent": USER_AGENT})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=120) as res:
                    return json.loads(res.read().decode("utf-8"))
            except urllib.error.HTTPError as err:
                if err.code < 500 or attempt == 3:
                    raise DumpError(f"export: HTTP {err.code}") from None
            except (urllib.error.URLError, TimeoutError, OSError):
                if attempt == 3:
                    raise DumpError("export: network error") from None
            time.sleep(5 * (attempt + 1))
        raise DumpError("export: gave up")

    return get_page


def sort_key(row):
    return (row["source"], row["osm_ref"] or "", row["name"], row["kind"], row["lat"], row["lng"])


def ndjson_gz(rows):
    """Deterministic bytes: sorted rows, sorted keys, gzip with mtime 0."""
    text = "".join(json.dumps(r, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
                   for r in sorted(rows, key=sort_key))
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0, compresslevel=9) as gz:
        gz.write(text.encode("utf-8"))
    return buf.getvalue()


def readme(month, counts, total, data_name):
    lines = [
        f"# Activity Planet places, {month}",
        "",
        f"`{data_name}` holds {total:,} public places from the Activity Planet hub map, one JSON object per line.",
        "",
        "## Licence",
        "",
        "This database is made available under the Open Database License (ODbL) 1.0:",
        "https://opendatacommons.org/licenses/odbl/1-0/. Any rights in individual contents of the",
        "database are licensed under the Database Contents License: https://opendatacommons.org/licenses/dbcl/1-0/.",
        "If you use, share or adapt it, credit \"© OpenStreetMap contributors, Activity Planet\" and keep",
        "anything you make from it under the ODbL.",
        "",
        "## Where the facts come from",
        "",
        "- `osm`: OpenStreetMap, © OpenStreetMap contributors (https://www.openstreetmap.org/copyright).",
        "- `geoapify`: Geoapify Places (https://www.geoapify.com), built on OpenStreetMap data.",
        "- `user`: places members added or corrected on Activity Planet and moderators reviewed. Members",
        "  agree in the Terms that these facts are published under the ODbL.",
        "- `venue`: public meeting spots where public plans happen.",
        "",
        "Corrections to OpenStreetMap places belong on OpenStreetMap: https://www.openstreetmap.org/fixthemap.",
        "",
        "## Columns",
        "",
        "| column | meaning |",
        "|---|---|",
        "| source | osm, geoapify, user or venue |",
        "| osm_ref | the OpenStreetMap element (n123 node, w456 way, r789 relation), or null |",
        "| name | the place's name |",
        "| kind | the display kind (court_field, park, cafe, ...) |",
        "| lat, lng | WGS 84, 6 decimals |",
        "| tags | allowlisted OpenStreetMap tags (sport, access, fee, surface, wheelchair, ...) |",
        "| opening_hours | OpenStreetMap opening_hours syntax, or null |",
        "| website | the place's website, or null |",
        "",
        "There are no ids, accounts, reviews, reports, private pins or places waiting for review in this file.",
        "",
        "## Rows by source",
        "",
    ]
    for s in SOURCES:
        lines.append(f"- {s}: {counts.get(s, 0):,}")
    lines += ["", "Check the download with `sha256sum -c SHA256SUMS`.", ""]
    return "\n".join(lines)


def build(rows, month, out_dir):
    if not MONTH.match(month):
        raise DumpError("month must be YYYY-MM")
    for n, row in enumerate(rows):
        check_row(row, n)
    os.makedirs(out_dir, exist_ok=True)
    data_name = f"places-{month}.ndjson.gz"
    data = ndjson_gz(rows)
    counts = {s: sum(1 for r in rows if r["source"] == s) for s in SOURCES}
    text = readme(month, counts, len(rows), data_name).encode("utf-8")
    with open(os.path.join(out_dir, data_name), "wb") as f:
        f.write(data)
    with open(os.path.join(out_dir, "README.md"), "wb") as f:
        f.write(text)
    sha = hashlib.sha256(data).hexdigest()
    with open(os.path.join(out_dir, "SHA256SUMS"), "w", encoding="utf-8") as f:
        f.write(f"{sha}  {data_name}\n{hashlib.sha256(text).hexdigest()}  README.md\n")
    stats = {"month": month, "rows": len(rows), "bytes": len(data), "sha256": sha, "counts": counts,
             "file": data_name}
    with open(os.path.join(out_dir, "stats.json"), "w", encoding="utf-8") as f:
        json.dump(stats, f, indent=2, sort_keys=True)
    return stats


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--month", required=True, help="YYYY-MM")
    ap.add_argument("--out", required=True)
    ap.add_argument("--base-url", help="https://<ref>.supabase.co/functions/v1/collector")
    ap.add_argument("--from-file", help="a JSON list of rows instead of the network")
    ap.add_argument("--min-rows", type=int, default=1, help="fail below this many rows")
    a = ap.parse_args(argv)
    try:
        if a.from_file:
            with open(a.from_file, encoding="utf-8") as f:
                rows = json.load(f)
        else:
            secret = os.environ.get("COLLECTOR_SECRET", "")
            if len(secret) < 32 or not a.base_url:
                raise DumpError("needs --base-url and COLLECTOR_SECRET")
            rows = fetch_all(http_pager(a.base_url, secret))
        if len(rows) < a.min_rows:
            raise DumpError(f"only {len(rows)} rows (at least {a.min_rows} expected)")
        stats = build(rows, a.month, a.out)
    except DumpError as err:
        print(f"dump failed: {err}", file=sys.stderr)
        return 1
    print(f"rows={stats['rows']} bytes={stats['bytes']} sha256={stats['sha256']} "
          + " ".join(f"{k}={v}" for k, v in stats["counts"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
