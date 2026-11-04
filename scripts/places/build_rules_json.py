"""Build scripts/places/hub_place_rules.json from the research tables in scripts/places/rules/.

Run:  python3 -I scripts/places/build_rules_json.py

Inputs (hand-edited): rules/rules.txt (one line per hub), rules/slugs.txt and rules/cats.txt (hub
order and categories, which must match supabase/seed/hubs.sql). Output: hub_place_rules.json, the
per-hub rules that scripts/places/gen_place_rules.py turns into the seed and the osmium filter.
The "verified" flags here record what the research pass confirmed from OSM wiki excerpts; the
taginfo check (places-taginfo.yml) is what the generator uses to drop rare tags.
CI runs this and fails if the committed JSON differs.
"""
import json, os, re, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "rules")
OUT = os.path.join(HERE, "hub_place_rules.json")
slugs = open(f"{D}/slugs.txt").read().split()
cats = open(f"{D}/cats.txt").read().split()
cat_of = dict(zip(slugs, cats))

MACROS = {
    "SP": "leisure=pitch|sports_centre|sports_hall&sport={}",
    "HALL": "leisure=sports_centre|sports_hall|fitness_centre&sport={}",
    "MA": "leisure=sports_centre|sports_hall|fitness_centre&sport={} ; amenity=dojo",
    "FIT": "leisure=fitness_centre|sports_centre&sport={}",
    "POOL": "leisure=swimming_pool|sports_centre&sport={}",
    "PIST": "piste:type={} ; landuse=winter_sports",
}
PLAIN = {
    "@RINK": "leisure=ice_rink",
    "@TRAIL": "highway=trailhead ; leisure=nature_reserve ; boundary=national_park ; route=hiking (relation)",
    "@WATER": "leisure=slipway ; leisure=marina ; amenity=boat_rental",
    "@GAMES": "shop=games",
    "@VG": "shop=video_games",
}

# Tag pairs confirmed by OSM-wiki search excerpts in this session (wiki host itself is blocked).
V = set()
def add(k, vals):
    for v in vals.split(): V.add((k, v))
add("leisure", "pitch sports_centre sports_hall fitness_centre stadium swimming_pool disc_golf_course hackerspace horse_riding ice_rink trampoline_park escape_game dance bird_hide wildlife_hide fishing bowling_alley sauna amusement_arcade shooting_ground")
add("shop", "anime games video_games craft music collector books toys musical_instrument")
add("amenity", "karaoke_box music_venue dojo dancing_school music_school language_school")
add("sport", "basketball padel pickleball chess ultimate free_flying rc_car model_aerodrome shooting equestrian boules karting climbing")
add("club", "chess culture sport")
add("books", "comic")
add("boules", "petanque lyonnaise")
add("piste:type", "downhill nordic skitour hike sled sleigh ski_jump")
add("aerialway", "zip_line")
add("shooting", "rifle paintball clay_pigeon pistol")
add("lgbtq", "primary")
add("highway", "raceway")
add("karaoke", "yes")
add("anime:manga", "yes")
add("amenity", "library community_centre arts_centre theatre cinema nightclub place_of_worship marketplace social_facility")
add("religion", "muslim")
add("route", "mtb")
add("leisure", "bike_park track")
KEY_VERIFIED = {"mtb:scale", "sport", "club", "shooting", "piste:type", "books", "lgbtq", "boules"}  # wildcard use ok

GEO_V = set("""commercial.hobby commercial.hobby.anime commercial.hobby.art commercial.hobby.brewing commercial.hobby.collecting
commercial.hobby.games commercial.hobby.model commercial.hobby.music commercial.hobby.photo
entertainment entertainment.activity_park entertainment.activity_park.climbing entertainment.activity_park.trampoline
entertainment.amusement_arcade entertainment.bowling_alley entertainment.escape_game entertainment.miniature_golf
activity activity.community_center activity.sport_club leisure leisure.park commercial commercial.books
commercial.outdoor_and_sport commercial.outdoor_and_sport.bicycle sport sport.ice_rink sport.dive_centre
sport.horse_riding sport.track sport.fishing sport.golf_course sport.pitch sport.stadium sport.swimming_pool
commercial.toy_and_game commercial.video_and_music catering catering.bar adult adult.nightclub""".split())

TOKEN = re.compile(r"^(\*|[a-z0-9_:-]+)$")

def expand(s):
    for k, v in PLAIN.items():
        s = s.replace(k, v)
    s = re.sub(r"@(\w+)\(([^)]*)\)", lambda m: MACROS[m.group(1)].format(m.group(2)), s)
    return s

def parse_filter(f):
    f = f.strip()
    osm_type = None
    # "(relation)" may sit at the end or before the first "&" ("route=bicycle (relation)&surface=gravel").
    if "(relation)" in f:
        osm_type = "relation"; f = re.sub(r"\s*\(relation\)\s*", "", f)
    parts = f.split("&")
    k, v = parts[0].split("=", 1)
    out = {"key": k}
    vals = v.split("|")
    for x in [k] + vals:
        if not TOKEN.match(x):
            sys.exit(f"bad tag token {x!r} in filter {f!r}")
    if len(vals) > 1: out["values"] = vals
    else: out["value"] = vals[0]
    extra = {}
    for p in parts[1:]:
        ek, ev = p.split("=", 1)
        evs = ev.split("|")
        for x in [ek] + evs:
            if not TOKEN.match(x):
                sys.exit(f"bad tag token {x!r} in filter {f!r}")
        extra[ek] = evs if len(evs) > 1 else evs[0]
    if extra: out["extra_tags"] = extra
    if osm_type: out["osm_type"] = osm_type
    # verification
    unv = []
    def chk(key, vs):
        for x in (vs if isinstance(vs, list) else [vs]):
            if x == "*":
                if key not in KEY_VERIFIED: unv.append(f"{key}=*")
            elif (key, x) not in V:
                unv.append(f"{key}={x}")
    chk(k, vals)
    for ek, ev in extra.items(): chk(ek, ev)
    out["verified"] = not unv
    if unv: out["unverified_tags"] = unv
    return out

rules = {}
for line in open(f"{D}/rules.txt", encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("#"): continue
    cols = line.split("|")
    # columns: slug|conf|kind|filters|geo|notes  -- but filters contain '|'. Parse from both ends.
    slug, conf, kind = cols[0], cols[1], cols[2]
    if kind == "skip": continue
    notes = cols[-1].strip(); geo = cols[-2].strip()
    filt = "|".join(cols[3:-2]).strip()
    assert slug not in rules, slug
    rules[slug] = (conf, kind, filt, geo, notes)

missing = [s for s in slugs if s not in rules]
extra = [s for s in rules if s not in cat_of]
assert not missing and not extra, (missing, extra)

SENS = {"culture-and-identity", "faith-and-spirituality", "wellness-and-support"}
out = []
for s in slugs:
    conf, kind, filt, geo, notes = rules[s]
    fl = [parse_filter(x) for x in expand(filt).split(" ; ") if x.strip()] if filt else []
    gl = [g.strip() for g in geo.split(",") if g.strip()]
    out.append({
        "hub_slug": s,
        "category_slug": cat_of[s],
        "has_places": kind != "none",
        "place_specificity": kind,  # specific = hub-specific venue types; generic = only shared third places; none = events/online only
        "osm_filters": fl,
        "geoapify_categories": gl,
        "geoapify_unverified": [g for g in gl if g not in GEO_V],
        "confidence": conf,
        "sensitive": cat_of[s] in SENS,
        "notes": notes,
    })
with open(OUT, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=1, ensure_ascii=False)
    fh.write("\n")

# stats
c = collections.Counter(r["place_specificity"] for r in out)
conf = collections.Counter((r["place_specificity"], r["confidence"]) for r in out)
nf = sum(len(r["osm_filters"]) for r in out)
nv = sum(f["verified"] for r in out for f in r["osm_filters"])
unv_tags = collections.Counter(t for r in out for f in r["osm_filters"] for t in f.get("unverified_tags", []))
geo_unv = collections.Counter(g for r in out for g in r["geoapify_unverified"])
allv = sum(1 for r in out if r["osm_filters"] and all(f["verified"] for f in r["osm_filters"]))
anyv = sum(1 for r in out if any(f["verified"] for f in r["osm_filters"]))
print("hubs", len(out), dict(c))
print("conf", dict(conf))
print("filters", nf, "verified", nv, "hubs all-verified", allv, "hubs >=1 verified", anyv)
print("distinct unverified tags", len(unv_tags))
print("top unverified tags", unv_tags.most_common(40))
print("geo unverified", len(geo_unv), geo_unv.most_common(25))
print("specific-low", [r["hub_slug"] for r in out if r["place_specificity"]=="specific" and r["confidence"]=="low"])
