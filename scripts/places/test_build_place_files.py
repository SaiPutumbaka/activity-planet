"""Tests for build_place_files.py (run: python3 -I -m unittest discover -s scripts/places -p 'test_*.py').

Made-up rows; no network, no database.
"""
import gzip
import hashlib
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_place_files as bf  # noqa: E402

def rd(path, mode="rb"):
    with open(path, mode) as f:
        return f.read()


HUB = "0f8fad5b-d9cb-469f-a165-70867728950e"


def row(ref="n1", **over):
    r = [ref, 7.85, 47.99, "court_field", "Court One", [3], "Hauptstr. 1", "Freiburg", "Mo-Su 08:00-22:00",
         "https://example.org", {"sport": "basketball"}]
    for k, v in over.items():
        r[bf.COLS.index(k)] = v
    return r


def queue(tiles=(198375,), rv=1, drop=()):
    return {"as_of": "2026-11-04T00:00:00Z", "rules_version": rv,
            "hubs": [[HUB, "basketball", "Basketball", "🏀", "specific", [3, 7]]],
            "build": [{"id": t, "status": "active", "row_count": 2, "file_path": None} for t in tiles],
            "drop": list(drop)}


def pages(rows_by_tile, page=2):
    calls = []

    def get_page(tile, after):
        calls.append((tile, after))
        rows = rows_by_tile[tile]
        start = 0 if after is None else next(i for i, r in enumerate(rows) if r[0] == after) + 1
        chunk = rows[start:start + page]
        nxt = chunk[-1][0] if len(chunk) == page and start + page < len(rows) else None
        return {"rows": chunk, "next": nxt, "as_of": f"2026-11-04T10:00:0{len(calls)}Z"}
    return get_page, calls


class CheckRow(unittest.TestCase):
    def test_good(self):
        bf.check_row(row(), 1, 0)
        bf.check_row(row(address=None, locality=None, hours=None, website=None, tags=None), 1, 1)
        # A public website may carry a uuid of its own (two such rows on staging, Nov 4).
        bf.check_row(row(website="https://example.org/store/0f8fad5b-d9cb-469f-a165-70867728950e"), 1, 2)

    def test_bad(self):
        for bad in (row(osm_ref="x1"), row(lng=200), row(lat="1"), row(kind=""), row(name=""),
                    row(rule_ids=[]), row(rule_ids=[True]), row(website="javascript:x"),
                    row(tags={"owner": "x"}), row(name="0f8fad5b-d9cb-469f-a165-70867728950e"),
                    row(tags={"brand": "0f8fad5b-d9cb-469f-a165-70867728950e"}), row()[:10]):
            with self.assertRaises(bf.FilesError):
                bf.check_row(bad, 1, 0)


class Build(unittest.TestCase):
    def test_build_pages_and_names(self):
        rows = {198375: [row("n1"), row("n2"), row("w3")]}
        get_page, calls = pages(rows)
        with tempfile.TemporaryDirectory() as out:
            result, stats = bf.build(queue(), get_page, out, log=lambda *_: None)
            self.assertEqual(calls, [(198375, None), (198375, "n2")])
            t = result["tiles"][0]
            self.assertRegex(t["path"], r"^places/v1/198375\.[0-9a-f]{16}\.json\.gz$")
            self.assertEqual(t["count"], 3)
            self.assertEqual(t["built_from"], "2026-11-04T10:00:01Z")   # the first page's time
            data = rd(os.path.join(out, t["path"]))
            self.assertEqual(hashlib.sha256(data).hexdigest(), t["sha256"])
            self.assertEqual(len(data), t["bytes"])
            raw = gzip.decompress(data)
            self.assertEqual(hashlib.sha256(raw).hexdigest()[:16], t["path"].split(".")[1])
            doc = json.loads(raw)
            self.assertEqual(doc["cols"], bf.COLS)
            self.assertEqual(doc["attribution"], "© OpenStreetMap contributors")
            self.assertEqual([r[0] for r in doc["rows"]], ["n1", "n2", "w3"])
            self.assertRegex(result["rules"]["path"], r"^rules/v1\.[0-9a-f]{16}\.json\.gz$")
            rules = json.loads(gzip.decompress(rd(os.path.join(out, result["rules"]["path"]))))
            self.assertEqual(rules["hubs"][0][5], [3, 7])
            self.assertEqual(stats["total_rows"], 3)
            self.assertTrue(os.path.exists(os.path.join(out, "build.json")))

    def test_reproducible(self):
        rows = {198375: [row("n1"), row("n2")]}
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            ra, _ = bf.build(queue(), pages(rows)[0], a, log=lambda *_: None)
            rb, _ = bf.build(queue(), pages(rows, page=5)[0], b, log=lambda *_: None)
            self.assertEqual(ra["tiles"][0]["path"], rb["tiles"][0]["path"])
            self.assertEqual(ra["tiles"][0]["sha256"], rb["tiles"][0]["sha256"])

    def test_order_and_bad_queue(self):
        with tempfile.TemporaryDirectory() as out:
            with self.assertRaises(bf.FilesError):
                bf.build(queue(), pages({198375: [row("n2"), row("n1")]}, page=5)[0], out, log=lambda *_: None)
            with self.assertRaises(bf.FilesError):
                bf.build({"build": []}, pages({})[0], out, log=lambda *_: None)
            q = queue()
            q["hubs"][0][4] = "none"
            with self.assertRaises(bf.FilesError):
                bf.build(q, pages({198375: []})[0], out, log=lambda *_: None)

    def test_record_body(self):
        with tempfile.TemporaryDirectory() as out:
            result, _ = bf.build(queue(drop=[5]), pages({198375: [row()]})[0], out, log=lambda *_: None)
            body = bf.record_body(result, False)
            self.assertFalse(body["published"])
            self.assertEqual(body["tiles"][-1], {"id": 5, "clear": True})
            self.assertEqual(set(body["tiles"][0]), {"id", "path", "sha256", "bytes", "count", "rules_version",
                                                     "built_from"})


class Publish(unittest.TestCase):
    def test_merge_retire_drop(self):
        now = datetime(2026, 11, 4, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as site, tempfile.TemporaryDirectory() as b1, \
                tempfile.TemporaryDirectory() as b2:
            r1, _ = bf.build(queue(tiles=(198375, 178031)),
                             pages({198375: [row("n1")], 178031: [row("n9")]})[0], b1, log=lambda *_: None)
            m = bf.publish(site, b1, now=now, log=lambda *_: None)
            first = m["tiles"]["198375"]["path"]
            self.assertTrue(os.path.exists(os.path.join(site, first)))
            self.assertTrue(os.path.exists(os.path.join(site, ".nojekyll")))
            self.assertIn("Open Database License", rd(os.path.join(site, "LICENSE.md"), "r"))
            # A changed tile gets a new name; the old one stays for keep_days, then goes.
            r2, _ = bf.build(queue(drop=[178031]), pages({198375: [row("n1"), row("n2")]})[0], b2,
                             log=lambda *_: None)
            m = bf.publish(site, b2, keep_days=7, now=now + timedelta(days=1), log=lambda *_: None)
            second = m["tiles"]["198375"]["path"]
            self.assertNotEqual(first, second)
            self.assertTrue(os.path.exists(os.path.join(site, first)))
            self.assertNotIn("178031", m["tiles"])
            self.assertFalse(os.path.exists(os.path.join(site, r1["tiles"][1]["path"])))
            m = bf.publish(site, b2, keep_days=7, now=now + timedelta(days=9), log=lambda *_: None)
            self.assertFalse(os.path.exists(os.path.join(site, first)))
            self.assertTrue(os.path.exists(os.path.join(site, second)))
            self.assertEqual(m["retired"], [])
            man = json.loads(rd(os.path.join(site, "places", "manifest.json"), "r"))
            self.assertEqual(man["license"], "ODbL-1.0")


if __name__ == "__main__":
    unittest.main()


FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "apps", "app", "src", "lib",
                        "__tests__", "fixtures", "place-files")


class StagingFixtures(unittest.TestCase):
    """The app's client tests read real staging rows (fixtures/place-files); the builder must accept
    every one of them and write the same columns the app decodes."""

    def test_builds_the_app_fixtures(self):
        for name in ("atlanta-downtown", "freiburg-altstadt"):
            fx = json.loads(rd(os.path.join(FIXTURES, f"{name}.json"), "r"))
            tiles = {int(t): rows for t, rows in fx["tiles"].items()}
            q = {"rules_version": 1, "hubs": fx["hubs"], "drop": [],
                 "build": [{"id": t, "status": "active", "row_count": len(r), "file_path": None}
                           for t, r in tiles.items()]}
            with tempfile.TemporaryDirectory() as out:
                result, stats = bf.build(q, pages(tiles, page=50)[0], out, log=lambda *_: None)
                for t in result["tiles"]:
                    self.assertEqual(t["count"], len(tiles[t["id"]]))
                    doc = json.loads(gzip.decompress(rd(os.path.join(out, t["path"]))))
                    self.assertEqual(doc["rows"], tiles[t["id"]])
                    self.assertEqual(doc["cols"], ["osm_ref", "lng", "lat", "kind", "name", "rule_ids", "address",
                                                   "locality", "hours", "website", "tags"])
