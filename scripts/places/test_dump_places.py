"""Tests for dump_places.py (run: python3 -I -m unittest discover -s scripts/places -p 'test_*.py').

Made-up rows; no network, no database.
"""
import gzip
import hashlib
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dump_places as dp  # noqa: E402


def row(**over):
    r = {"source": "osm", "osm_ref": "n42", "name": "Court One", "kind": "court_field", "lat": 33.75,
         "lng": -84.39, "tags": {"sport": "basketball"}, "opening_hours": None, "website": None}
    r.update(over)
    return r


class CheckRow(unittest.TestCase):
    def test_good_rows(self):
        dp.check_row(row(), 0)
        dp.check_row(row(source="user", osm_ref=None, tags={}), 1)

    def test_extra_or_missing_keys(self):
        with self.assertRaises(dp.DumpError):
            dp.check_row({**row(), "id": "x"}, 0)
        with self.assertRaises(dp.DumpError):
            dp.check_row({**row(), "created_by": None}, 0)
        bad = row()
        del bad["website"]
        with self.assertRaises(dp.DumpError):
            dp.check_row(bad, 0)

    def test_values(self):
        for over in ({"source": "google"}, {"lat": 91}, {"lng": "x"}, {"lat": True}, {"osm_ref": "x1"},
                     {"tags": {"name:en": "x"}}, {"name": ""}, {"website": 3}):
            with self.assertRaises(dp.DumpError, msg=str(over)):
                dp.check_row(row(**over), 0)

    def test_no_uuid_anywhere(self):
        with self.assertRaises(dp.DumpError):
            dp.check_row(row(name="Spot 0f8fad5b-d9cb-469f-a165-70867728950e"), 0)


class Paging(unittest.TestCase):
    def test_follows_cursor(self):
        pages = {None: {"rows": [row(name="A")], "next": "c1"}, "c1": {"rows": [row(name="B")], "next": None}}
        seen = []

        def get(after):
            seen.append(after)
            return pages[after]

        self.assertEqual([r["name"] for r in dp.fetch_all(get)], ["A", "B"])
        self.assertEqual(seen, [None, "c1"])

    def test_bad_page(self):
        with self.assertRaises(dp.DumpError):
            dp.fetch_all(lambda after: {"next": None})


class Build(unittest.TestCase):
    def test_files_are_deterministic_and_complete(self):
        rows = [row(name="B"), row(source="user", osm_ref=None, name="A", tags={}),
                row(source="venue", osm_ref=None, name="C", tags={})]
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            s1 = dp.build(rows, "2026-11", d1)
            s2 = dp.build(list(reversed(rows)), "2026-11", d2)
            self.assertEqual(s1["sha256"], s2["sha256"])
            self.assertEqual(s1["counts"], {"osm": 1, "geoapify": 0, "user": 1, "venue": 1})
            data = open(os.path.join(d1, "places-2026-11.ndjson.gz"), "rb").read()
            self.assertEqual(hashlib.sha256(data).hexdigest(), s1["sha256"])
            lines = gzip.decompress(data).decode("utf-8").splitlines()
            self.assertEqual([json.loads(x)["name"] for x in lines], ["B", "A", "C"])
            readme = open(os.path.join(d1, "README.md"), encoding="utf-8").read()
            self.assertIn("Open Database License (ODbL) 1.0", readme)
            self.assertIn("© OpenStreetMap contributors", readme)
            sums = open(os.path.join(d1, "SHA256SUMS"), encoding="utf-8").read()
            self.assertIn(f"{s1['sha256']}  places-2026-11.ndjson.gz", sums)

    def test_bad_month_and_rows(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(dp.DumpError):
                dp.build([row()], "2026-13", d)
            with self.assertRaises(dp.DumpError):
                dp.build([{**row(), "id": 1}], "2026-11", d)

    def test_main_from_file_and_min_rows(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "rows.json")
            with open(src, "w", encoding="utf-8") as f:
                json.dump([row()], f)
            self.assertEqual(dp.main(["--month", "2026-11", "--out", os.path.join(d, "o"), "--from-file", src]), 0)
            self.assertEqual(dp.main(["--month", "2026-11", "--out", os.path.join(d, "o2"), "--from-file", src,
                                      "--min-rows", "5"]), 1)


if __name__ == "__main__":
    unittest.main()
