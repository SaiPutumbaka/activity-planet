"""OpenStreetMap places extract for the hub map (D-041 slice 5, design 3.1).

Called by .github/workflows/places-extract.yml, one subcommand per step:

  plan      tiles + Geofabrik index-v1.json -> plan.json (the smallest extracts covering each tile,
            one bounding box per extract group)
  evaluate  osmium geojsonseq exports -> one NDJSON file of place rows per tile, plus stats.json
  post      NDJSON rows -> the collector Edge Function (POST /collector/ingest/places in batches,
            then POST /collector/tiles/{id}/done), with the row-count guard

Run with `python3 -I`. Needs shapely (Ubuntu's python3-shapely) for `evaluate`; the other
subcommands are standard library only. Output is counts, error names and a few sample rows of
public OpenStreetMap data; never the collector secret, never member data (the job only reads OSM).
"""
import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
RULES_JSON = os.path.join(HERE, "extract_rules.json")
REGIONS_JSON = os.path.join(HERE, "regions.json")
USER_AGENT = "ActivityPlanet-places/1 (+https://github.com/SaiPutumbaka/activity-planet)"

TILE_DEG = 0.5
MARGIN_DEG = 0.02  # about 2 km: polygons that straddle a tile edge are still complete
MAX_TILE_ID = 259199
BATCH_ROWS = 1000  # the collector takes up to 2,000; 1,000 keeps each RPC well under its timeout
BYTES_PER_ROW_DB = 1600  # design 4.5, measured: heap plus indexes per place after a refresh
MAX_ROWS_PER_TILE = 60000
DROP_GUARD = 0.7  # refuse to finish a tile whose row count fell more than 30%
GUARD_MIN_ROWS = 50
DEDUPE_METERS = 150.0
LINE_CELL_DEG = 0.02

# Tags kept on a row (design 4.3; the database applies the same allowlist).
TAG_ALLOWLIST = ("sport", "religion", "denomination", "lgbtq", "access", "fee", "lit", "indoor",
                 "surface", "hoops", "wheelchair", "wikidata", "phone", "brand")
BUSINESS_KEYS = ("amenity", "shop", "craft", "office", "tourism", "leisure", "club")
HOME_BUILDINGS = {"house", "residential", "apartments", "detached", "semidetached_house", "terrace",
                  "bungalow", "dormitory"}
PRIVATE_ACCESS = {"private", "no"}
PUBLIC_ACCESS = {"yes", "public", "permissive", "customers", "designated"}

# Facilities that are useful without a name; they get a descriptive one ("Tennis court at X Park").
UNNAMED_OK = {
    "leisure=pitch", "leisure=track", "leisure=swimming_pool", "leisure=fitness_station",
    "leisure=playground", "leisure=dog_park", "leisure=ice_rink", "leisure=disc_golf_course",
    "leisure=slipway", "leisure=picnic_table",
}
COURT_SPORTS = {"basketball", "tennis", "volleyball", "beachvolleyball", "pickleball", "handball",
                "padel", "squash", "racquetball", "badminton", "netball", "paddle_tennis",
                "beach_tennis", "futsal", "sepak_takraw", "korfball", "shuffleboard", "boules",
                "bowls", "horseshoes", "cornhole", "table_tennis"}
SPORT_LABELS = {"beachvolleyball": "Beach volleyball", "american_football": "Football",
                "soccer": "Soccer", "skateboard": "Skate", "table_tennis": "Table tennis",
                "multi": "Multi-sport", "boules": "Boules", "bmx": "BMX"}
FALLBACK_NAMES = {
    "leisure=track": "Track", "leisure=swimming_pool": "Swimming pool",
    "leisure=fitness_station": "Outdoor fitness station", "leisure=playground": "Playground",
    "leisure=dog_park": "Dog park", "leisure=ice_rink": "Ice rink",
    "leisure=disc_golf_course": "Disc golf course", "leisure=slipway": "Boat ramp",
    "leisure=picnic_table": "Chess table", "leisure=pitch": "Sports field",
}
LINE_GEOMS = {"LineString", "MultiLineString"}
AREA_GEOMS = {"Polygon", "MultiPolygon"}


def die(msg):
    sys.exit(f"extract_places: {msg}")


def log(*args):
    print(*args, flush=True)


# ------------------------------------------------------------------------------------------------
# Tiles (same arithmetic as public.place_tile_id / place_tile_bbox)
def tile_id(lat, lng):
    row = min(359, max(0, math.floor((lat + 90) / TILE_DEG)))
    col = min(719, max(0, math.floor((lng + 180) / TILE_DEG)))
    return row * 720 + col


def tile_bbox(tid):
    """(west, south, east, north) of a tile."""
    if not 0 <= tid <= MAX_TILE_ID:
        raise ValueError(f"tile id out of range: {tid}")
    west = (tid % 720) * TILE_DEG - 180
    south = (tid // 720) * TILE_DEG - 90
    return (west, south, west + TILE_DEG, south + TILE_DEG)


def union_bbox(tids, margin=MARGIN_DEG):
    boxes = [tile_bbox(t) for t in tids]
    return (max(-180.0, min(b[0] for b in boxes) - margin), max(-90.0, min(b[1] for b in boxes) - margin),
            min(180.0, max(b[2] for b in boxes) + margin), min(90.0, max(b[3] for b in boxes) + margin))


def resolve_tiles(region, regions_doc=None):
    """'atlanta' (regions.json), '178030,178031' (tile ids) or 'queue' (None: take the queue)."""
    region = (region or "").strip().lower()
    if region in ("", "queue"):
        return None
    if re.fullmatch(r"[0-9]{1,6}(,[0-9]{1,6})*", region):
        tids = sorted({int(x) for x in region.split(",")})
        for t in tids:
            tile_bbox(t)
        return tids
    if regions_doc is None:
        with open(REGIONS_JSON, encoding="utf-8") as fh:
            regions_doc = json.load(fh)
    doc = regions_doc
    reg = doc["regions"].get(region)
    if not reg:
        die(f"unknown region {region!r}; known: {', '.join(sorted(doc['regions']))}, queue, or tile ids")
    return sorted(set(reg["tiles"]))


# ------------------------------------------------------------------------------------------------
# Geofabrik extract pick (design 3.1 step 2)
def _ring_contains(ring, x, y):
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def _polys(geometry):
    if not geometry:
        return []
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return geometry["coordinates"]
    return []


def geom_contains(geometry, x, y):
    for poly in _polys(geometry):
        if poly and _ring_contains(poly[0], x, y) and not any(_ring_contains(h, x, y) for h in poly[1:]):
            return True
    return False


def geom_area(geometry):
    total = 0.0
    for poly in _polys(geometry):
        ring = poly[0]
        a = 0.0
        for i in range(len(ring) - 1):
            a += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
        total += abs(a) / 2
    return total


def extract_candidates(index):
    """Region extracts with a .osm.pbf, minus continents, the planet and whole-country giants."""
    out = []
    for f in index["features"]:
        p = f.get("properties", {})
        pbf = (p.get("urls") or {}).get("pbf")
        if not pbf or not f.get("geometry"):
            continue
        if p.get("parent") is None:  # continents (and other top-level entries)
            continue
        if p.get("id") in ("us", "russia", "canada", "china", "brazil", "india"):
            continue
        out.append({"id": p["id"], "name": p.get("name", p["id"]), "pbf": pbf, "geometry": f["geometry"],
                    "area": geom_area(f["geometry"]), "iso1": p.get("iso3166-1:alpha2") or [],
                    "iso2": p.get("iso3166-2") or []})
    return out


def extract_country(c):
    codes = {x.upper() for x in c["iso1"]} | {x.split("-")[0].upper() for x in c["iso2"]}
    return codes.pop() if len(codes) == 1 else None


def pick_extracts(tids, index):
    """Per tile, the smallest extract holding each of 9 sample points (corners, edge midpoints,
    centre), so a tile on a border takes both sides and an aggregate such as us-south never wins
    over the state files inside it."""
    cands = extract_candidates(index)
    picks = {}
    for t in tids:
        w, s, e, n = tile_bbox(t)
        pts = [(x, y) for x in (w + 1e-6, (w + e) / 2, e - 1e-6) for y in (s + 1e-6, (s + n) / 2, n - 1e-6)]
        chosen = []
        for x, y in pts:
            holding = [c for c in cands if geom_contains(c["geometry"], x, y)]
            if holding:
                best = min(holding, key=lambda c: c["area"])
                if best not in chosen:
                    chosen.append(best)
        if not chosen:
            die(f"no Geofabrik extract covers tile {t}")
        picks[t] = chosen
    groups = defaultdict(list)  # extract ids tuple -> tiles
    meta = {}
    for t, chosen in picks.items():
        key = tuple(sorted(c["id"] for c in chosen))
        groups[key].append(t)
        for c in chosen:
            meta[c["id"]] = c
    plan = {"groups": [], "extracts": {}}
    for key, ts in sorted(groups.items()):
        ts = sorted(ts)
        countries = {extract_country(meta[i]) for i in key}
        plan["groups"].append({
            "name": "-".join(key),
            "extracts": list(key),
            "tiles": ts,
            "bbox": [round(v, 6) for v in union_bbox(ts)],
            "country": countries.pop() if len(countries) == 1 else None,
        })
    for i, c in meta.items():
        plan["extracts"][i] = {"name": c["name"], "pbf": c["pbf"]}
    return plan


# ------------------------------------------------------------------------------------------------
# Rule evaluation (design 3.1 step 6)
def tag_values(raw):
    return {v.strip() for v in str(raw).split(";") if v.strip()}


class Rules:
    def __init__(self, doc):
        self.version = doc["rules_version"]
        self.kind_order = {k: i for i, k in enumerate(doc["kinds"])}
        self.by_key = defaultdict(list)
        for r in doc["rules"]:
            self.by_key[r["key"]].append(r)

    def match(self, tags, osm_type):
        """Matching rules for a feature's tags; osm_type is 'n', 'w' or 'r'."""
        hits = []
        for key, rules in self.by_key.items():
            if key not in tags:
                continue
            vals = tag_values(tags[key])
            for r in rules:
                if r["osm_type"] == "relation" and osm_type != "r":
                    continue
                if r["value"] is not None and r["value"] not in vals:
                    continue
                ok = True
                for ek, evs in r["extra"].items():
                    if ek not in tags:
                        ok = False
                        break
                    if "*" not in evs and not (tag_values(tags[ek]) & set(evs)):
                        ok = False
                        break
                if ok:
                    hits.append(r)
        return hits

    def best(self, hits):
        """The rule that names the place's kind: most extra conditions, then kind order, then id."""
        return min(hits, key=lambda r: (-len(r["extra"]), self.kind_order.get(r["kind"], 999), r["id"]))


def osm_ref_of(feature):
    """'n123' / 'w123' / 'r123' from an osmium export feature (type_id ids or @type/@id)."""
    props = feature.get("properties") or {}
    t, i = props.get("@type"), props.get("@id")
    if t in ("node", "way", "relation") and i is not None:
        return t[0] + str(int(i))
    fid = str(feature.get("id") or "")
    m = re.fullmatch(r"([nwr])([0-9]{1,15})", fid)
    if m:
        return fid
    m = re.fullmatch(r"a([0-9]{1,16})", fid)
    if m:
        a = int(m.group(1))
        return ("w" if a % 2 == 0 else "r") + str(a // 2)
    return None


def read_geojsonseq(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip().lstrip("\x1e").strip()
            if line:
                yield json.loads(line)


def humanize(v):
    return SPORT_LABELS.get(v) or v.replace("_", " ").strip().capitalize()


def fallback_name(base_tag, tags):
    if base_tag == "leisure=pitch":
        sports = [s for s in sorted(tag_values(tags.get("sport", ""))) if s]
        if sports:
            s = sports[0]
            if s == "skateboard":
                return "Skate park"
            return f"{humanize(s)} {'court' if s in COURT_SPORTS else 'field'}"
    if base_tag == "leisure=track" and tag_values(tags.get("sport", "")) & {"running", "athletics"}:
        return "Running track"
    return FALLBACK_NAMES.get(base_tag, "Place")


def clean_name(raw):
    return re.sub(r"\s+", " ", str(raw or "")).strip()[:120]


def meters(lat1, lng1, lat2, lng2):
    x = math.radians(lng2 - lng1) * math.cos(math.radians((lat1 + lat2) / 2))
    y = math.radians(lat2 - lat1)
    return 6371000.0 * math.hypot(x, y)


class Evaluator:
    def __init__(self, rules, tiles, country=None):
        from shapely.geometry import shape  # noqa: F401  (imported here: plan/post need no shapely)

        self.rules = rules
        self.tiles = set(tiles)
        self.country = country
        self.drops = Counter()
        self.seen_features = 0
        self.residential = []
        self.parks = []  # (polygon, name)
        self._res_tree = None
        self._park_tree = None
        self.named = set()

    # ---- context polygons ----
    def load_residential(self, path):
        from shapely.geometry import shape

        if path and os.path.exists(path):
            for f in read_geojsonseq(path):
                g = f.get("geometry") or {}
                if g.get("type") in AREA_GEOMS:
                    try:
                        self.residential.append(shape(g))
                    except Exception:
                        pass

    def _build_trees(self):
        from shapely.strtree import STRtree

        self._res_tree = STRtree(self.residential) if self.residential else None
        self._park_tree = STRtree([p for p, _ in self.parks]) if self.parks else None

    def in_residential(self, pt):
        if self._res_tree is None:
            return False
        return any(self.residential[i].contains(pt) for i in self._res_tree.query(pt))

    def park_name(self, pt):
        if self._park_tree is None:
            return None
        best = None
        for i in self._park_tree.query(pt):
            poly, name = self.parks[i]
            if poly.contains(pt) and (best is None or poly.area < best[0]):
                best = (poly.area, name)
        return best[1] if best else None

    # ---- one feature -> candidate row ----
    def point_of(self, geom):
        from shapely.geometry import shape

        g = shape(geom)
        if g.is_empty:
            return None
        if geom["type"] == "Point":
            return g
        if geom["type"] in AREA_GEOMS:
            try:
                return g.representative_point()
            except Exception:
                return g.centroid
        if geom["type"] in LINE_GEOMS:
            if geom["type"] == "MultiLineString":
                g = max(g.geoms, key=lambda x: x.length)
            return g.interpolate(0.5, normalized=True)
        return None

    def candidates(self, paths):
        """First pass: features that match a rule, with their point and geometry class."""
        from shapely.geometry import shape

        out = []
        for path in paths:
            for f in read_geojsonseq(path):
                self.seen_features += 1
                geom = f.get("geometry") or {}
                gtype = geom.get("type")
                props = f.get("properties") or {}
                tags = {k: v for k, v in props.items() if not k.startswith("@") and isinstance(v, (str, int, float))}
                ref = osm_ref_of(f)
                if not ref or gtype not in (AREA_GEOMS | LINE_GEOMS | {"Point"}):
                    continue
                name = clean_name(tags.get("name"))
                if gtype in AREA_GEOMS and tags.get("leisure") in ("park", "nature_reserve") and name:
                    try:
                        self.parks.append((shape(geom), name))
                    except Exception:
                        pass
                hits = self.rules.match(tags, ref[0])
                if not hits:
                    continue
                out.append((ref, gtype, geom, tags, hits))
        return out

    def rows(self, paths):
        cands = self.candidates(paths)
        self._build_trees()
        rows = []
        lines = {}
        for ref, gtype, geom, tags, hits in cands:
            if str(tags.get("access", "")).strip() in PRIVATE_ACCESS:
                self.drops["access_private"] += 1
                continue
            if str(tags.get("building", "")).strip() in HOME_BUILDINGS:
                self.drops["home_building"] += 1
                continue
            try:
                pt = self.point_of(geom)
            except Exception:
                pt = None
            if pt is None:
                self.drops["no_point"] += 1
                continue
            lat, lng = round(pt.y, 7), round(pt.x, 7)
            tid = tile_id(lat, lng)
            if tid not in self.tiles:
                self.drops["outside_tiles"] += 1
                continue
            best = self.rules.best(hits)
            base_tag = f"{best['key']}={best['value']}" if best["value"] else f"{best['key']}=*"
            name = clean_name(tags.get("name"))
            named = bool(name)
            if not named:
                if gtype in LINE_GEOMS:
                    self.drops["unnamed_line"] += 1
                    continue
                unnamed_bases = {f"{h['key']}={h['value']}" for h in hits} & UNNAMED_OK
                if not unnamed_bases:
                    self.drops["unnamed"] += 1
                    continue
                if base_tag not in UNNAMED_OK:
                    base_tag = sorted(unnamed_bases)[0]
                if self.in_residential(pt):
                    self.drops["unnamed_in_residential"] += 1
                    continue
                if base_tag == "leisure=swimming_pool" and str(tags.get("access", "")).strip() not in PUBLIC_ACCESS:
                    self.drops["unnamed_pool_not_public"] += 1
                    continue
                name = fallback_name(base_tag, tags)
                park = self.park_name(pt)
                if park:
                    name = clean_name(f"{name} at {park}")
            row = self.row(ref, name, named, best["kind"], sorted({h["id"] for h in hits})[:64], lat, lng, tags)
            row["_geom"] = gtype
            row["_named"] = named
            if gtype in LINE_GEOMS:
                # A named path is many ways; keep one row per name and rules in a ~2 km cell.
                key = (name.lower(), tuple(row["rule_ids"]), tid,
                       math.floor(lat / LINE_CELL_DEG), math.floor(lng / LINE_CELL_DEG))
                cur = lines.get(key)
                if cur is None or ref_order(ref) < ref_order(cur["source_id"]):
                    if cur is not None:
                        self.drops["line_segment_merged"] += 1
                    lines[key] = row
                else:
                    self.drops["line_segment_merged"] += 1
                continue
            rows.append(row)
        rows.extend(lines.values())
        rows = self.one_per_element(rows)
        rows = self.dedupe(rows)
        for r in rows:
            r.pop("_geom", None)
        self.named = {r["source_id"] for r in rows if r.pop("_named", True)}
        return rows

    def row(self, ref, name, named, kind, rule_ids, lat, lng, tags):
        row = {"source_id": ref, "osm_ref": ref, "name": name, "kind": kind, "rule_ids": rule_ids,
               "lat": lat, "lng": lng}
        street = " ".join(x for x in (str(tags.get("addr:housenumber", "")).strip(),
                                      str(tags.get("addr:street", "")).strip()) if x)
        if street:
            row["address_text"] = street[:200]
        city = str(tags.get("addr:city", "")).strip()
        if city:
            row["locality"] = city[:120]
        cc = str(tags.get("addr:country", "")).strip().upper()
        cc = cc if re.fullmatch(r"[A-Z]{2}", cc) else self.country
        if cc:
            row["country"] = cc
        hours = str(tags.get("opening_hours", "")).strip()
        if hours and len(hours) <= 255:
            row["opening_hours"] = hours
        web = str(tags.get("website") or tags.get("contact:website") or "").strip()
        if re.match(r"^https?://", web) and len(web) <= 500:
            row["website"] = web
        kept = {}
        for k in TAG_ALLOWLIST:
            v = tags.get("contact:phone") if k == "phone" and "phone" not in tags else tags.get(k)
            if v is None or str(v).strip() == "":
                continue
            if k == "phone" and not (named and any(b in tags for b in BUSINESS_KEYS)):
                continue
            kept[k] = str(v).strip()[:255]
        if kept:
            row["tags"] = kept
        return row

    def one_per_element(self, rows):
        """osmium can export one closed way as a polygon and as a line; keep one row per element
        (the polygon's interior point first, then a node, then a line midpoint)."""
        rank = {"Polygon": 0, "MultiPolygon": 0, "Point": 1}
        best = {}
        for r in rows:
            cur = best.get(r["source_id"])
            if cur is None:
                best[r["source_id"]] = r
                continue
            self.drops["same_element"] += 1
            if rank.get(r["_geom"], 2) < rank.get(cur["_geom"], 2):
                best[r["source_id"]] = r
        return list(best.values())

    def dedupe(self, rows):
        """Same name and kind within 150 m: keep one (areas and lines before nodes, then lowest id)."""
        def prio(r):
            return (0 if r["_geom"] != "Point" else 1, ref_order(r["source_id"]))

        cell = 0.002
        grid = defaultdict(list)
        kept = []
        for r in sorted(rows, key=prio):
            key = (r["name"].lower(), r["kind"])
            cx, cy = math.floor(r["lng"] / cell), math.floor(r["lat"] / cell)
            dup = False
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for o in grid[(key, cx + dx, cy + dy)]:
                        if meters(r["lat"], r["lng"], o["lat"], o["lng"]) <= DEDUPE_METERS:
                            dup = True
                            break
                    if dup:
                        break
                if dup:
                    break
            if dup:
                self.drops["duplicate_nearby"] += 1
                continue
            grid[(key, cx, cy)].append(r)
            kept.append(r)
        return kept


def ref_order(ref):
    return ({"r": 0, "w": 1, "n": 2}[ref[0]], int(ref[1:]))


def row_bytes(row):
    return len(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode())


# ------------------------------------------------------------------------------------------------
# Collector client (design 3.1 steps 7 and 8)
def http_json(method, url, secret, body=None, retries=3):
    data = None if body is None else json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=data, method=method, headers={
            "x-collector-secret": secret, "Content-Type": "application/json", "User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=170) as res:
                return res.status, json.loads(res.read().decode() or "null")
        except urllib.error.HTTPError as err:
            try:
                payload = json.loads(err.read().decode() or "null")
            except Exception:
                payload = None
            if err.code >= 500 and attempt < retries:
                time.sleep(5 * attempt)
                continue
            return err.code, payload
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt < retries:
                time.sleep(5 * attempt)
                continue
            return 0, {"error": "network"}
    return 0, {"error": "network"}


def guard_ok(count, previous):
    """The 30% drop check: False when a tile that had GUARD_MIN_ROWS rows lost more than 30%."""
    return previous is None or previous < GUARD_MIN_ROWS or count >= DROP_GUARD * previous


# ------------------------------------------------------------------------------------------------
# Subcommands
def cmd_plan(a):
    index = json.load(open(a.index, encoding="utf-8"))
    tids = [int(x) for x in a.tiles.split(",") if x]
    if not tids:
        die("no tiles")
    plan = pick_extracts(tids, index)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(plan, fh, indent=1)
    for g in plan["groups"]:
        log(f"group {g['name']}: tiles {g['tiles']} bbox {g['bbox']} country {g['country']}")
    for i, e in sorted(plan["extracts"].items()):
        log(f"extract {i}: {e['name']} {e['pbf']}")


def cmd_tiles(a):
    """Resolve the region input to tile ids (prints a comma list)."""
    tids = resolve_tiles(a.region)
    if tids is None:
        q = json.load(open(a.queue, encoding="utf-8")) if a.queue else {"tiles": []}
        tids = sorted({int(t["id"]) for t in q.get("tiles", [])})
    elif a.queue and not a.force:
        q = json.load(open(a.queue, encoding="utf-8"))
        due = {int(t["id"]) for t in q.get("tiles", [])}
        skipped = [t for t in tids if t not in due]
        if skipped:
            print(f"tiles not due a run, skipped (use force): {skipped}", file=sys.stderr)
        tids = [t for t in tids if t in due]
    print(",".join(str(t) for t in tids))


def cmd_evaluate(a):
    rules = Rules(json.load(open(RULES_JSON, encoding="utf-8")))
    plan = json.load(open(a.plan, encoding="utf-8"))
    group = next((g for g in plan["groups"] if g["name"] == a.group), None)
    if not group:
        die(f"no group {a.group} in plan")
    ev = Evaluator(rules, group["tiles"], group.get("country"))
    ev.load_residential(a.residential)
    rows = ev.rows(a.features)
    os.makedirs(a.out_dir, exist_ok=True)
    by_tile = defaultdict(list)
    for r in rows:
        by_tile[tile_id(r["lat"], r["lng"])].append(r)
    stats = {"group": group["name"], "rules_version": rules.version, "features_read": ev.seen_features,
             "rows": len(rows), "dropped": dict(sorted(ev.drops.items())), "tiles": {}}
    for t in group["tiles"]:
        trs = sorted(by_tile.get(t, []), key=lambda r: ref_order(r["source_id"]))
        with open(os.path.join(a.out_dir, f"tile_{t}.ndjson"), "w", encoding="utf-8") as fh:
            for r in trs:
                fh.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
        kinds = Counter(r["kind"] for r in trs)
        nbytes = sum(row_bytes(r) for r in trs)
        stats["tiles"][str(t)] = {
            "rows": len(trs), "json_bytes": nbytes, "est_db_bytes": len(trs) * BYTES_PER_ROW_DB,
            "named": sum(1 for r in trs if r["source_id"] in ev.named),
            "with_website": sum(1 for r in trs if "website" in r),
            "with_hours": sum(1 for r in trs if "opening_hours" in r),
            "kinds": dict(kinds.most_common()),
            "sha256": hashlib.sha256("".join(r["source_id"] for r in trs).encode()).hexdigest()[:16],
        }
    with open(os.path.join(a.out_dir, f"stats_{group['name'].replace('/', '_')}.json"), "w", encoding="utf-8") as fh:
        json.dump(stats, fh, indent=1)
    log(json.dumps({k: v for k, v in stats.items() if k != "tiles"}, indent=1))
    for t, s in stats["tiles"].items():
        log(f"tile {t}: {s['rows']} rows, {s['json_bytes']} JSON bytes, ~{s['est_db_bytes']} DB bytes; "
            f"kinds {json.dumps(s['kinds'])}")
    # A few public OSM rows as a sample (name, kind, element), never the full list.
    sample = sorted(rows, key=lambda r: hashlib.sha256(r["source_id"].encode()).hexdigest())[: a.samples]
    for r in sample:
        log(f"sample: {r['source_id']} {r['kind']} {r['name']!r} rules {r['rule_ids']}")
    for t, s in stats["tiles"].items():
        if s["rows"] > MAX_ROWS_PER_TILE:
            die(f"tile {t} has {s['rows']} rows, over the {MAX_ROWS_PER_TILE} cap; check the filters")


def cmd_post(a):
    secret = os.environ.get("COLLECTOR_SECRET", "")
    if len(secret) < 32:
        die("COLLECTOR_SECRET is not set")
    base = a.base_url.rstrip("/")
    queue = json.load(open(a.queue, encoding="utf-8")) if a.queue and os.path.exists(a.queue) else {"tiles": []}
    previous = {int(t["id"]): t.get("row_count") for t in queue.get("tiles", [])}
    tids = [int(x) for x in a.tiles.split(",") if x]
    results = {}
    failed = []
    for t in tids:
        path = os.path.join(a.rows_dir, f"tile_{t}.ndjson")
        if not os.path.exists(path):
            die(f"no rows file for tile {t}")
        rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
        prev = previous.get(t)
        if not guard_ok(len(rows), prev):
            log(f"tile {t}: GUARD {len(rows)} rows against {prev} before; more than a 30% drop, not posted")
            failed.append(t)
            results[str(t)] = {"error": "row_count_drop", "rows": len(rows), "previous": prev}
            continue
        totals = Counter()
        skipped = Counter()
        ok = True
        for n, start in enumerate(range(0, len(rows), BATCH_ROWS)):
            batch = rows[start:start + BATCH_ROWS]
            status, res = http_json("POST", f"{base}/ingest/places", secret, {
                "tile_id": t, "run_id": a.run_id, "source": "osm", "batch_no": n, "rows": batch})
            if status != 200 or not isinstance(res, dict) or res.get("received") != len(batch):
                err = res.get("error") if isinstance(res, dict) else None
                log(f"tile {t}: batch {n} failed: HTTP {status} {err}")
                ok = False
                break
            for k in ("received", "inserted", "updated", "unchanged", "merged", "reopened"):
                totals[k] += int(res.get(k) or 0)
            skipped.update({k: int(v) for k, v in (res.get("skipped") or {}).items()})
        if not ok:
            failed.append(t)
            results[str(t)] = {"error": "ingest_failed", **totals}
            continue
        status, res = http_json("POST", f"{base}/tiles/{t}/done", secret,
                                {"run_id": a.run_id, "count": totals["received"], "source": "osm"})
        if status != 200 or not isinstance(res, dict):
            err = res.get("error") if isinstance(res, dict) else None
            log(f"tile {t}: done failed: HTTP {status} {err}")
            failed.append(t)
            results[str(t)] = {"error": f"done_{err or status}", **totals}
            continue
        result = {**totals, "skipped": dict(skipped), **{k: res.get(k) for k in (
            "seen", "missed", "closed", "previous_seen", "active", "row_count")}}
        if not guard_ok(totals["received"], res.get("previous_seen")):
            log(f"tile {t}: GUARD after finish: {totals['received']} rows against {res.get('previous_seen')} "
                "in the last run (one miss counted, nothing closed yet)")
            failed.append(t)
            result["error"] = "row_count_drop_after_finish"
        results[str(t)] = result
        log(f"tile {t}: {json.dumps(result)}")
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=1)
    if failed:
        die(f"tiles failed: {failed}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="extract_places")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("tiles")
    s.add_argument("--region", required=True)
    s.add_argument("--queue")
    s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_tiles)
    s = sub.add_parser("plan")
    s.add_argument("--index", required=True)
    s.add_argument("--tiles", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_plan)
    s = sub.add_parser("evaluate")
    s.add_argument("--plan", required=True)
    s.add_argument("--group", required=True)
    s.add_argument("--features", nargs="+", required=True)
    s.add_argument("--residential")
    s.add_argument("--out-dir", required=True)
    s.add_argument("--samples", type=int, default=5)
    s.set_defaults(fn=cmd_evaluate)
    s = sub.add_parser("post")
    s.add_argument("--base-url", required=True)
    s.add_argument("--tiles", required=True)
    s.add_argument("--rows-dir", required=True)
    s.add_argument("--run-id", required=True)
    s.add_argument("--queue")
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_post)
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
