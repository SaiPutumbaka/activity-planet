"""Count worldwide OSM uses of every tag in hub_place_rules.json on taginfo.

Run by .github/workflows/places-taginfo.yml (workflow_dispatch). Not needed locally, and the Claude
cloud environment blocks taginfo.openstreetmap.org unless it is allowed (FOUNDER-TODO).

  python3 -I scripts/places/taginfo_check.py OUT_DIR

Writes OUT_DIR/taginfo_counts.json (the file gen_place_rules.py reads; commit it to
scripts/places/) and OUT_DIR/taginfo_report.md. Only public tag statistics are fetched and printed.
Polite: one request at a time with a pause between them, retries with backoff, and an identifying
User-Agent.
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RULES_JSON = os.path.join(HERE, "hub_place_rules.json")
API = "https://taginfo.openstreetmap.org/api/4"
UA = "ActivityPlanet-places/1 (+https://github.com/SaiPutumbaka/activity-planet)"
PAUSE = 0.4
MIN_USES = 50


def research_tags():
    hubs = json.load(open(RULES_JSON, encoding="utf-8"))
    tags = {}  # tag -> research said verified
    for h in hubs:
        for f in h["osm_filters"]:
            unv = set(f.get("unverified_tags", []))
            items = [(f["key"], v) for v in (f.get("values") or [f.get("value")])]
            for ek, ev in (f.get("extra_tags") or {}).items():
                items += [(ek, v) for v in (ev if isinstance(ev, list) else [ev])]
            for k, v in items:
                t = f"{k}=*" if v == "*" else f"{k}={v}"
                tags[t] = tags.get(t, True) and t not in unv
    return tags


def get(path, params):
    url = f"{API}/{path}?" + urllib.parse.urlencode(params)
    delay = 2.0
    for attempt in range(5):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 4:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 4:
                raise
        time.sleep(delay)
        delay *= 2
    raise RuntimeError("unreachable")


def count_for(tag):
    key, value = tag.split("=", 1)
    if value == "*":
        doc = get("key/stats", {"key": key})
    else:
        doc = get("tag/stats", {"key": key, "value": value})
    total = next((row["count"] for row in doc.get("data", []) if row.get("type") == "all"), 0)
    return int(total), doc.get("data_until")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: taginfo_check.py OUT_DIR")
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    tags = research_tags()
    counts, errors, data_until = {}, [], None
    for i, tag in enumerate(sorted(tags)):
        try:
            n, until = count_for(tag)
            counts[tag] = n
            data_until = data_until or until
        except Exception as e:  # noqa: BLE001 - report and continue; the tag stays unchecked
            counts[tag] = None
            errors.append(f"{tag}: {type(e).__name__}")
        if (i + 1) % 100 == 0:
            print(f"checked {i + 1} of {len(tags)} tags", flush=True)
        time.sleep(PAUSE)

    fetched_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {
        "_about": "Worldwide use counts per tag from taginfo.openstreetmap.org, written by "
        "scripts/places/taginfo_check.py (places-taginfo.yml). null = the lookup failed.",
        "source": "https://taginfo.openstreetmap.org",
        "fetched_at": fetched_at,
        "data_until": data_until,
        "min_uses": MIN_USES,
        "counts": dict(sorted(counts.items())),
    }
    with open(os.path.join(out_dir, "taginfo_counts.json"), "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")

    ok = [t for t, n in counts.items() if n is not None and n >= MIN_USES]
    low = sorted((t for t, n in counts.items() if n is not None and n < MIN_USES), key=lambda t: (counts[t], t))
    research_unverified = [t for t, v in tags.items() if not v]
    newly = [t for t in research_unverified if counts.get(t) is not None and counts[t] >= MIN_USES]
    lines = [
        "## Place rule tags on taginfo",
        "",
        f"Fetched {fetched_at}; taginfo data until {data_until}. Threshold: {MIN_USES} uses worldwide.",
        "",
        "| | tags |",
        "|---|---|",
        f"| checked | {len(tags)} |",
        f"| at or above {MIN_USES} uses | {len(ok)} |",
        f"| under {MIN_USES} uses | {len(low)} |",
        f"| lookup failed | {len(errors)} |",
        f"| unverified in the research pass | {len(research_unverified)} |",
        f"| of those, now confirmed (at or above {MIN_USES}) | {len(newly)} |",
        "",
        f"### Under {MIN_USES} uses",
        "",
    ]
    lines += [f"- `{t}`: {counts[t]}" for t in low] or ["- none"]
    if errors:
        lines += ["", "### Lookups that failed", ""] + [f"- `{e}`" for e in errors]
    report = "\n".join(lines) + "\n"
    with open(os.path.join(out_dir, "taginfo_report.md"), "w", encoding="utf-8") as fh:
        fh.write(report)
    print(report)
    # Machine-readable copy for readers of the public log (tag statistics only).
    print("=====BEGIN TAGINFO COUNTS=====")
    print(f"fetched_at {fetched_at}")
    print(f"data_until {data_until}")
    for t, n in sorted(counts.items()):
        print(f"count {t} {'null' if n is None else n}")
    print("=====END TAGINFO COUNTS=====")
    if len(errors) > len(tags) // 10:
        sys.exit(f"{len(errors)} of {len(tags)} lookups failed")


if __name__ == "__main__":
    main()
