"""Generate supabase/seed/place_rules.sql, scripts/places/filters.txt and extract_rules.json from
hub_place_rules.json.

Run:  python3 -I scripts/places/gen_place_rules.py          (writes the files, prints counts)
      python3 -I scripts/places/gen_place_rules.py --check  (CI: fails if the committed files differ)

Inputs, all in scripts/places/:
  hub_place_rules.json  per-hub OSM filters (built from rules/ by build_rules_json.py)
  place_kinds.json      display kinds and the base-tag -> kind map
  taginfo_counts.json   worldwide use counts per tag from the taginfo job (places-taginfo.yml);
                        optional: without it no rule is dropped and nothing is marked verified
  rule_ids.json         append-only registry: rule signature -> smallint id, plus rules_version.
                        Ids are never reused, so rule_ids stored on places stay meaningful.

A rule is one base tag (key=value, or key present) plus optional extra conditions (any of the listed
values per extra key; "*" means the key is present) and an OSM type. A hub filter with several base
values ("leisure=pitch|sports_centre") becomes one rule per value, shared by every hub that uses it.

Taginfo threshold (D-041): a base tag with fewer than MIN_USES uses worldwide drops the rule; an
extra value under MIN_USES is removed from its list, and the rule drops if a list empties. A rule is
verified when every tag in it has at least MIN_USES uses. Tags taginfo has not reported stay, unverified.

Standard library only; no network.
"""
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RULES_JSON = os.path.join(HERE, "hub_place_rules.json")
KINDS_JSON = os.path.join(HERE, "place_kinds.json")
TAGINFO_JSON = os.path.join(HERE, "taginfo_counts.json")
REGISTRY_JSON = os.path.join(HERE, "rule_ids.json")
HUBS_SQL = os.path.join(ROOT, "supabase", "seed", "hubs.sql")
OUT_SQL = os.path.join(ROOT, "supabase", "seed", "place_rules.sql")
OUT_FILTERS = os.path.join(HERE, "filters.txt")
OUT_STATS = os.path.join(HERE, "rules_stats.json")
OUT_EXTRACT = os.path.join(HERE, "extract_rules.json")
MIN_USES = 50
SENSITIVE_CATEGORIES = {"culture-and-identity", "faith-and-spirituality", "wellness-and-support"}


def die(msg):
    sys.exit(f"gen_place_rules: {msg}")


def load(path, default=None):
    if not os.path.exists(path):
        if default is not None:
            return default
        die(f"missing {os.path.relpath(path, ROOT)}")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def q(s):
    return "'" + s.replace("'", "''") + "'"


def text_array(items):
    return "array[" + ", ".join(q(x) for x in items) + "]::text[]" if items else "'{}'::text[]"


def tag_name(key, value):
    return f"{key}=*" if value in (None, "*") else f"{key}={value}"


# ---------------------------------------------------------------------------------------------
# Hub catalog cross-check against supabase/seed/hubs.sql (the hubs table's source of truth).
def catalog_hubs():
    sql = open(HUBS_SQL, encoding="utf-8").read()
    cats = dict(re.findall(r"^\s+\('([a-z0-9-]+)', '(?:[^']|'')*', '[a-z]+', \d+, (true|false),", sql, re.M))
    start = sql.index("insert into public.hubs ")
    hubs = re.findall(r"^\s+\('([a-z0-9-]+)', '(?:[^']|'')*', '([a-z0-9-]+)',", sql[start:], re.M)
    return {s: c for s, c in hubs}, {c: v == "true" for c, v in cats.items()}


# ---------------------------------------------------------------------------------------------
def main():
    check = "--check" in sys.argv[1:]
    hubs = load(RULES_JSON)
    kinds_doc = load(KINDS_JSON)
    taginfo = load(TAGINFO_JSON, {"counts": {}})
    counts = taginfo.get("counts", {})
    registry = load(REGISTRY_JSON, {"rules_version": 0, "fingerprint": "", "next_id": 1, "ids": {}})

    cat_hubs, cat_sensitive = catalog_hubs()
    json_hubs = {h["hub_slug"]: h for h in hubs}
    if len(json_hubs) != len(hubs):
        die("duplicate hub_slug in hub_place_rules.json")
    if set(json_hubs) != set(cat_hubs):
        die(f"hub slugs differ from hubs.sql: only in rules {sorted(set(json_hubs) - set(cat_hubs))}, "
            f"only in hubs.sql {sorted(set(cat_hubs) - set(json_hubs))}")
    for s, h in json_hubs.items():
        if h["category_slug"] != cat_hubs[s]:
            die(f"{s}: category {h['category_slug']} but hubs.sql says {cat_hubs[s]}")
        if h["sensitive"] != cat_sensitive.get(cat_hubs[s], False):
            die(f"{s}: sensitive flag disagrees with its category in hubs.sql")
        if h["place_specificity"] not in ("specific", "generic", "none"):
            die(f"{s}: bad place_specificity {h['place_specificity']}")
        if h["place_specificity"] == "none" and h["osm_filters"]:
            die(f"{s}: place_specificity none but has osm_filters")

    kinds = kinds_doc["kinds"]
    kind_slugs = [k["slug"] for k in kinds]
    if len(set(kind_slugs)) != len(kind_slugs):
        die("duplicate kind slug")
    tag_kind = kinds_doc["tags"]
    for t, k in tag_kind.items():
        if k not in kind_slugs:
            die(f"tag {t} maps to unknown kind {k}")

    def kind_for(key, value):
        k = tag_kind.get(tag_name(key, value)) or tag_kind.get(f"{key}=*")
        if not k:
            die(f"no kind for base tag {tag_name(key, value)}; add it to place_kinds.json")
        return k

    def uses(tag):
        c = counts.get(tag)
        return c if isinstance(c, int) else None

    # ---- expand hub filters into rules, apply the taginfo threshold --------------------------
    rules = {}  # signature -> rule dict
    links = defaultdict(set)  # hub slug -> signatures
    dropped = Counter()  # reason -> count of (hub, filter value) pairs dropped
    dropped_tags = set()
    for h in hubs:
        for f in h["osm_filters"]:
            values = f.get("values") or [f.get("value")]
            osm_type = f.get("osm_type") or "nwr"
            extra = {}
            drop_extra = False
            for ek, ev in sorted((f.get("extra_tags") or {}).items()):
                evs = ev if isinstance(ev, list) else [ev]
                kept = []
                for v in evs:
                    n = uses(tag_name(ek, v))
                    if n is not None and n < MIN_USES:
                        dropped_tags.add(tag_name(ek, v))
                        continue
                    kept.append(v)
                if not kept:
                    drop_extra = True
                    break
                extra[ek] = sorted(set(kept))
            for v in values:
                base = tag_name(f["key"], v)
                if drop_extra:
                    dropped["extra condition under threshold"] += 1
                    continue
                n = uses(base)
                if n is not None and n < MIN_USES:
                    dropped_tags.add(base)
                    dropped["base tag under threshold"] += 1
                    continue
                value = None if v == "*" else v
                sig = json.dumps([f["key"], value, extra, osm_type], sort_keys=True, ensure_ascii=False)
                if sig not in rules:
                    tags = [base] + [tag_name(ek, x) for ek, xs in extra.items() for x in xs]
                    ns = [uses(t) for t in tags]
                    rules[sig] = {
                        "osm_key": f["key"],
                        "osm_value": value,
                        "extra": extra,
                        "osm_type": osm_type,
                        "kind": kind_for(f["key"], v),
                        "verified": all(x is not None and x >= MIN_USES for x in ns),
                        "base_uses": uses(base),
                    }
                links[h["hub_slug"]].add(sig)

    # ---- stable ids and version ---------------------------------------------------------------
    ids = dict(registry["ids"])
    next_id = registry["next_id"]
    for sig in sorted(rules):
        if sig not in ids:
            ids[sig] = next_id
            next_id += 1
    if next_id > 32767:
        die("rule ids exhausted smallint")
    ordered = sorted(rules, key=lambda s: ids[s])
    link_rows = sorted((slug, ids[sig]) for slug, sigs in links.items() for sig in sigs)
    fp_src = json.dumps(
        {
            "rules": [[ids[s], rules[s]["kind"], rules[s]["verified"], s] for s in ordered],
            "links": link_rows,
            "modes": sorted((h["hub_slug"], h["place_specificity"], h["geoapify_categories"]) for h in hubs),
            "kinds": kinds,
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    fingerprint = hashlib.sha256(fp_src.encode()).hexdigest()
    version = registry["rules_version"]
    if fingerprint != registry["fingerprint"]:
        version += 1
    new_registry = {
        "_about": "Append-only. Maps each place rule signature [key, value, extra, osm_type] to its id; "
        "rules_version goes up whenever the generated rule set changes. Written by gen_place_rules.py.",
        "rules_version": version,
        "fingerprint": fingerprint,
        "next_id": next_id,
        "ids": dict(sorted(ids.items(), key=lambda kv: kv[1])),
    }

    # ---- stats --------------------------------------------------------------------------------
    modes = Counter(h["place_specificity"] for h in hubs)
    base_tags = sorted({tag_name(rules[s]["osm_key"], rules[s]["osm_value"]) for s in rules})
    all_tags = set()
    for h in hubs:
        for f in h["osm_filters"]:
            for v in f.get("values") or [f.get("value")]:
                all_tags.add(tag_name(f["key"], v))
            for ek, ev in (f.get("extra_tags") or {}).items():
                for v in ev if isinstance(ev, list) else [ev]:
                    all_tags.add(tag_name(ek, v))
    hubs_without_rules = sorted(
        h["hub_slug"] for h in hubs if h["place_specificity"] != "none" and not links.get(h["hub_slug"])
    )
    stats = {
        "rules_version": version,
        "hubs": len(hubs),
        "place_mode": dict(sorted(modes.items())),
        "rules": len(rules),
        "rules_verified": sum(r["verified"] for r in rules.values()),
        "base_tags": len(base_tags),
        "hub_rule_links": len(link_rows),
        "kinds": len(kinds),
        "tags_in_research": len(all_tags),
        "taginfo": {
            "fetched_at": taginfo.get("fetched_at"),
            "tags_with_counts": sum(1 for t in all_tags if uses(t) is not None),
            "tags_under_threshold": len(dropped_tags),
            "min_uses": MIN_USES,
        },
        "dropped_filter_values": dict(sorted(dropped.items())),
        "dropped_tags": sorted(dropped_tags),
        "hubs_with_places_but_no_rules": hubs_without_rules,
    }

    # ---- filters.txt (osmium tags-filter expressions) -----------------------------------------
    by_key = defaultdict(set)
    for s in rules:
        r = rules[s]
        prefix = "r" if r["osm_type"] == "relation" else "nwr"
        by_key[(prefix, r["osm_key"])].add(r["osm_value"] or "*")
    flines = [
        "# Generated by scripts/places/gen_place_rules.py from hub_place_rules.json. Do not edit.",
        f"# rules_version {version}: {len(rules)} rules, {len(base_tags)} base tags. "
        "Base tags only; extra conditions are applied after export.",
        "# Use: osmium tags-filter extract.osm.pbf --expressions=filters.txt -o filtered.osm.pbf",
    ]
    for (prefix, key), vals in sorted(by_key.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        if "*" in vals:
            flines.append(f"{prefix}/{key}")
        else:
            flines.append(f"{prefix}/{key}=" + ",".join(sorted(vals)))
    filters_txt = "\n".join(flines) + "\n"

    # ---- place_rules.sql ------------------------------------------------------------------------
    out = []
    w = out.append
    w("-- Generated by scripts/places/gen_place_rules.py from scripts/places/hub_place_rules.json,")
    w("-- place_kinds.json and taginfo_counts.json. Do not edit by hand; edit the inputs and re-run.")
    w(f"-- rules_version {version}: {len(kinds)} kinds, {len(rules)} rules over {len(base_tags)} base tags "
      f"({stats['rules_verified']} verified on taginfo), {len(hubs)} hubs "
      f"({modes['specific']} specific, {modes['generic']} generic, {modes['none']} none), "
      f"{len(link_rows)} hub-rule links.")
    w("-- Needs the hub map schema (slice 3): place_kinds, place_rules, hub_place_rules,")
    w("-- hubs.place_mode and hubs.geoapify_categories. Idempotent: upserts, then removes rules and links")
    w("-- that are no longer generated. Kinds are only added or updated, never deleted here.")
    w("begin;")
    w("")
    w("insert into public.place_kinds (slug, label, icon, sort) values")
    w(",\n".join(f"  ({q(k['slug'])}, {q(k['label'])}, {q(k['icon'])}, {(i + 1) * 10})" for i, k in enumerate(kinds)))
    w("on conflict (slug) do update set label = excluded.label, icon = excluded.icon, sort = excluded.sort;")
    w("")
    w("insert into public.place_rules (id, osm_key, osm_value, extra, osm_type, kind, verified, rules_version) values")
    rows = []
    for s in ordered:
        r = rules[s]
        val = "null" if r["osm_value"] is None else q(r["osm_value"])
        extra = q(json.dumps(r["extra"], sort_keys=True, ensure_ascii=False, separators=(",", ":"))) + "::jsonb"
        rows.append(f"  ({ids[s]}, {q(r['osm_key'])}, {val}, {extra}, {q(r['osm_type'])}, {q(r['kind'])}, "
                    f"{'true' if r['verified'] else 'false'}, {version})")
    w(",\n".join(rows))
    w("on conflict (id) do update set osm_key = excluded.osm_key, osm_value = excluded.osm_value, extra = excluded.extra,")
    w("  osm_type = excluded.osm_type, kind = excluded.kind, verified = excluded.verified, rules_version = excluded.rules_version;")
    w("")
    w("delete from public.place_rules where id <> all (array[" + ", ".join(str(ids[s]) for s in ordered) + "]::smallint[]);")
    w("")
    w("create temp table _hub_place_mode (slug text primary key, place_mode text not null, geoapify text[] not null) on commit drop;")
    w("insert into _hub_place_mode (slug, place_mode, geoapify) values")
    w(",\n".join(f"  ({q(h['hub_slug'])}, {q(h['place_specificity'])}, {text_array(h['geoapify_categories'])})"
                 for h in sorted(hubs, key=lambda h: h["hub_slug"])))
    w(";")
    w("do $$")
    w("begin")
    w("  if exists (select 1 from _hub_place_mode m left join public.hubs h on h.slug = m.slug where h.id is null) then")
    w("    raise exception 'place_rules seed: a hub in hub_place_rules.json is missing from public.hubs';")
    w("  end if;")
    w("end $$;")
    w("update public.hubs h set place_mode = m.place_mode, geoapify_categories = m.geoapify")
    w("  from _hub_place_mode m")
    w("  where h.slug = m.slug and (h.place_mode is distinct from m.place_mode or h.geoapify_categories is distinct from m.geoapify);")
    w("")
    w("create temp table _hub_place_rule (slug text not null, rule_id smallint not null, primary key (slug, rule_id)) on commit drop;")
    w("insert into _hub_place_rule (slug, rule_id) values")
    w(",\n".join(f"  ({q(slug)}, {rid})" for slug, rid in link_rows))
    w(";")
    w("insert into public.hub_place_rules (hub_id, rule_id)")
    w("  select h.id, l.rule_id from _hub_place_rule l join public.hubs h on h.slug = l.slug")
    w("  on conflict do nothing;")
    w("delete from public.hub_place_rules x")
    w("  using public.hubs h")
    w("  where h.id = x.hub_id")
    w("    and not exists (select 1 from _hub_place_rule l where l.slug = h.slug and l.rule_id = x.rule_id);")
    w("")
    w("commit;")
    sql_txt = "\n".join(out) + "\n"

    # ---- extract_rules.json (what the extract job evaluates, slice 5) ----------------------------
    extract_doc = {
        "_about": "Generated by gen_place_rules.py. Do not edit. The rules the extract job "
        "(extract_places.py) evaluates on each OSM feature: base tag, extra conditions (any listed value "
        "per key, '*' = present), OSM type and display kind. kinds is the kind order used to pick a "
        "place's kind when several rules match.",
        "rules_version": version,
        "kinds": kind_slugs,
        "rules": [
            {
                "id": ids[s],
                "key": rules[s]["osm_key"],
                "value": rules[s]["osm_value"],
                "extra": rules[s]["extra"],
                "osm_type": rules[s]["osm_type"],
                "kind": rules[s]["kind"],
            }
            for s in ordered
        ],
    }
    extract_txt = json.dumps(extract_doc, indent=1, ensure_ascii=False, sort_keys=True) + "\n"

    registry_txt = json.dumps(new_registry, indent=1, ensure_ascii=False) + "\n"
    stats_txt = json.dumps(stats, indent=1, ensure_ascii=False) + "\n"
    outputs = {OUT_SQL: sql_txt, OUT_FILTERS: filters_txt, REGISTRY_JSON: registry_txt, OUT_STATS: stats_txt,
               OUT_EXTRACT: extract_txt}

    if check:
        stale = []
        for path, txt in outputs.items():
            cur = open(path, encoding="utf-8").read() if os.path.exists(path) else None
            if cur != txt:
                stale.append(os.path.relpath(path, ROOT))
        if stale:
            die("generated files are out of date: " + ", ".join(stale)
                + ". Run python3 -I scripts/places/gen_place_rules.py and commit the result.")
        print(f"place rules up to date: rules_version {version}, {len(rules)} rules, {len(link_rows)} links")
        return

    for path, txt in outputs.items():
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(txt)
    print(json.dumps({k: v for k, v in stats.items() if k != "dropped_tags"}, indent=1))


if __name__ == "__main__":
    main()
