"""Tests for extract_places.py (run: python3 -I -m unittest discover -s scripts/places -p 'test_*.py').

Fixture features are made up; no network, no database. The evaluate tests need shapely.
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_places as ep  # noqa: E402

try:
    import shapely  # noqa: F401

    HAVE_SHAPELY = True
except ImportError:
    HAVE_SHAPELY = False

RULES = json.load(open(ep.RULES_JSON, encoding="utf-8"))
# Atlanta's centre tile: lat 33.5..34, lng -84.5..-84
TILE = 178031


def sq(lng, lat, d=0.0005):
    return {"type": "Polygon", "coordinates": [[[lng, lat], [lng + d, lat], [lng + d, lat + d], [lng, lat + d], [lng, lat]]]}


def feat(fid, geom, **tags):
    return {"type": "Feature", "id": fid, "geometry": geom, "properties": tags}


def pt(lng, lat):
    return {"type": "Point", "coordinates": [lng, lat]}


class TileMath(unittest.TestCase):
    def test_tile_id_matches_sql(self):
        self.assertEqual(ep.tile_id(33.749, -84.388), 178031)
        self.assertEqual(ep.tile_id(33.749, -84.6), 178030)
        self.assertEqual(ep.tile_id(34.1, -84.3), 178751)
        self.assertEqual(ep.tile_id(-90, -180), 0)
        self.assertEqual(ep.tile_id(90, 180), ep.MAX_TILE_ID)

    def test_bbox_round_trip(self):
        w, s, e, n = ep.tile_bbox(TILE)
        self.assertEqual((w, s, e, n), (-84.5, 33.5, -84.0, 34.0))
        self.assertEqual(ep.tile_id((s + n) / 2, (w + e) / 2), TILE)
        with self.assertRaises(ValueError):
            ep.tile_bbox(ep.MAX_TILE_ID + 1)

    def test_resolve_region(self):
        doc = {"regions": {"atlanta": {"tiles": [178751, 178030, 178031]}}}
        self.assertEqual(ep.resolve_tiles("Atlanta", doc), [178030, 178031, 178751])
        self.assertEqual(ep.resolve_tiles("178031,178030", doc), [178030, 178031])
        self.assertIsNone(ep.resolve_tiles("queue", doc))
        with self.assertRaises(SystemExit):
            ep.resolve_tiles("nowhere", doc)

    def test_atlanta_region_file(self):
        self.assertEqual(ep.resolve_tiles("atlanta"), [178030, 178031, 178751])


class Pick(unittest.TestCase):
    def index(self):
        def f(i, parent, geom, **p):
            return {"type": "Feature", "geometry": geom,
                    "properties": {"id": i, "name": i, "parent": parent,
                                   "urls": {"pbf": f"https://download.geofabrik.de/{i}-latest.osm.pbf"}, **p}}
        return {"features": [
            f("north-america", None, sq(-170, 10, 120)),
            f("us", "north-america", sq(-130, 20, 70), **{"iso3166-1:alpha2": ["US"]}),
            f("us/georgia", "us", sq(-85.7, 30.3, 5), **{"iso3166-2": ["US-GA"]}),
            f("us/alabama", "us", {"type": "Polygon", "coordinates": [[[-89, 30], [-85.7, 30], [-85.7, 35],
                                                                        [-89, 35], [-89, 30]]]},
              **{"iso3166-2": ["US-AL"]}),
            f("us-south", "north-america", sq(-100, 25, 25)),
        ]}

    def test_smallest_containing(self):
        plan = ep.pick_extracts([178030, 178031], self.index())
        self.assertEqual([g["extracts"] for g in plan["groups"]], [["us/georgia"]])
        self.assertEqual(plan["groups"][0]["tiles"], [178030, 178031])
        self.assertEqual(plan["groups"][0]["country"], "US")
        w, s, e, n = plan["groups"][0]["bbox"]
        self.assertAlmostEqual(w, -85.02)
        self.assertAlmostEqual(n, 34.02)

    def test_border_tile_takes_both(self):
        # Tile spanning lng -86..-85.5 straddles the made-up Alabama/Georgia line at -85.7.
        t = ep.tile_id(33.7, -85.8)
        plan = ep.pick_extracts([t], self.index())
        self.assertEqual(plan["groups"][0]["extracts"], ["us/alabama", "us/georgia"])


class RuleMatch(unittest.TestCase):
    def setUp(self):
        self.rules = ep.Rules(RULES)

    def ids(self, tags, t="w"):
        return {(r["key"], r["value"], json.dumps(r["extra"], sort_keys=True)) for r in self.rules.match(tags, t)}

    def test_sport_list_contains(self):
        hits = self.rules.match({"leisure": "pitch", "sport": "tennis;basketball"}, "w")
        sports = {tuple(r["extra"].get("sport", [])) for r in hits}
        self.assertIn(("basketball",), sports)
        self.assertIn(("tennis",), sports)
        best = self.rules.best(hits)
        self.assertEqual(best["kind"], "court_field")
        self.assertTrue(best["extra"])

    def test_extra_required(self):
        hits = self.rules.match({"amenity": "parking"}, "n")
        self.assertEqual(hits, [])
        self.assertTrue(self.rules.match({"amenity": "parking", "access": "yes"}, "n"))

    def test_relation_only(self):
        self.assertEqual(self.rules.match({"route": "hiking"}, "w"), [])
        self.assertTrue(self.rules.match({"route": "hiking"}, "r"))

    def test_key_present_rule(self):
        hits = self.rules.match({"historic": "memorial"}, "n")
        self.assertEqual({r["kind"] for r in hits}, {"historic"})

    def test_osm_ref(self):
        self.assertEqual(ep.osm_ref_of({"id": "n12"}), "n12")
        self.assertEqual(ep.osm_ref_of({"id": "a24"}), "w12")
        self.assertEqual(ep.osm_ref_of({"id": "a25"}), "r12")
        self.assertEqual(ep.osm_ref_of({"properties": {"@type": "relation", "@id": 9}}), "r9")
        self.assertIsNone(ep.osm_ref_of({"id": "x1"}))

    def test_guard(self):
        self.assertTrue(ep.guard_ok(10, None))
        self.assertTrue(ep.guard_ok(0, 40))  # small tiles are not guarded
        self.assertTrue(ep.guard_ok(700, 1000))
        self.assertFalse(ep.guard_ok(699, 1000))


@unittest.skipUnless(HAVE_SHAPELY, "shapely not installed")
class Evaluate(unittest.TestCase):
    def run_eval(self, features, residential=()):
        d = tempfile.mkdtemp()
        fp = os.path.join(d, "f.geojsonseq")
        with open(fp, "w") as fh:
            for f in features:
                fh.write("\x1e" + json.dumps(f) + "\n")
        rp = os.path.join(d, "r.geojsonseq")
        with open(rp, "w") as fh:
            for f in residential:
                fh.write(json.dumps(f) + "\n")
        ev = ep.Evaluator(ep.Rules(RULES), [TILE], "US")
        ev.load_residential(rp)
        return ev, {r["source_id"]: r for r in ev.rows([fp])}

    def test_rows_and_drops(self):
        park = feat("w200", sq(-84.40, 33.70, 0.01), leisure="park", name="Grant Park")
        feats = [
            park,
            feat("w100", sq(-84.395, 33.705), leisure="pitch", sport="basketball"),
            feat("n1", pt(-84.39, 33.71), amenity="cafe", name="Bean  There", website="https://example.org",
                 opening_hours="Mo-Fr 07:00-15:00", phone="+1 404 555 0100", **{"addr:street": "Main St",
                 "addr:housenumber": "12", "addr:city": "Atlanta", "contact:email": "x@example.org"}),
            feat("n2", pt(-84.30, 33.80), amenity="cafe"),  # unnamed cafe: dropped
            feat("n3", pt(-84.31, 33.81), amenity="cafe", name="Private", access="private"),
            feat("w300", sq(-84.32, 33.82), leisure="pitch", sport="tennis"),  # unnamed in residential
            feat("w400", sq(-84.33, 33.83), leisure="swimming_pool"),  # unnamed private-ish pool
            feat("n4", pt(-85.2, 33.7), amenity="cafe", name="Outside"),  # other tile
            feat("n5", pt(-84.39005, 33.71003), amenity="cafe", name="Bean There"),  # duplicate
            feat("w500", sq(-84.34, 33.84), leisure="park", name="Home Park", building="house"),
        ]
        res = [feat("w900", sq(-84.325, 33.815, 0.02), landuse="residential")]
        ev, rows = self.run_eval(feats, res)
        self.assertEqual(set(rows), {"w100", "n1", "w200"})
        court = rows["w100"]
        self.assertEqual(court["name"], "Basketball court at Grant Park")
        self.assertEqual(court["kind"], "court_field")
        self.assertEqual(ep.tile_id(court["lat"], court["lng"]), TILE)
        cafe = rows["n1"]
        self.assertEqual(cafe["name"], "Bean There")
        self.assertEqual(cafe["address_text"], "12 Main St")
        self.assertEqual(cafe["locality"], "Atlanta")
        self.assertEqual(cafe["country"], "US")
        self.assertEqual(cafe["tags"], {"phone": "+1 404 555 0100"})
        self.assertNotIn("contact:email", json.dumps(cafe))
        self.assertEqual(cafe["osm_ref"], "n1")
        self.assertTrue(all(isinstance(i, int) for i in cafe["rule_ids"]))
        self.assertEqual(ev.drops["unnamed"], 1)
        self.assertEqual(ev.drops["access_private"], 1)
        self.assertEqual(ev.drops["unnamed_in_residential"], 1)
        self.assertEqual(ev.drops["unnamed_pool_not_public"], 1)
        self.assertEqual(ev.drops["outside_tiles"], 1)
        self.assertEqual(ev.drops["duplicate_nearby"], 1)
        self.assertEqual(ev.drops["home_building"], 1)
        self.assertNotIn("w100", ev.named)
        self.assertIn("n1", ev.named)

    def test_one_row_per_element(self):
        poly = sq(-84.30, 33.70, 0.02)
        ring = poly["coordinates"][0]
        ev, rows = self.run_eval([
            feat("w70", {"type": "LineString", "coordinates": ring}, leisure="park", name="Big Park"),
            feat("w70", poly, leisure="park", name="Big Park"),
        ])
        self.assertEqual(list(rows), ["w70"])
        self.assertAlmostEqual(rows["w70"]["lat"], 33.71, places=2)
        self.assertEqual(ev.drops["same_element"], 1)

    def test_named_lines_collapse(self):
        line = lambda fid, x: feat(fid, {"type": "LineString", "coordinates": [[x, 33.75], [x + 0.001, 33.75]]},
                                   highway="cycleway", name="Eastside Trail")
        ev, rows = self.run_eval([line("w30", -84.355), line("w31", -84.3555), line("w32", -84.3560),
                                  feat("w40", {"type": "LineString", "coordinates": [[-84.2, 33.6], [-84.21, 33.6]]},
                                       highway="cycleway")])
        self.assertEqual(list(rows), ["w30"])
        self.assertEqual(rows["w30"]["kind"], "trail")
        self.assertEqual(ev.drops["line_segment_merged"], 2)
        self.assertEqual(ev.drops["unnamed_line"], 1)


if __name__ == "__main__":
    unittest.main()
