import base64
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import region_trial as rt  # noqa: E402


class RegionTrialTest(unittest.TestCase):
    def setUp(self):
        self.t = rt.load_trial("leipzig")

    def test_tiles(self):
        self.assertEqual(rt.tile_id(51.34, 12.37), 203424)
        self.assertIn(203425, rt.view_tiles(self.t))
        self.assertEqual(len(rt.neighbour_tiles(self.t)), 9)

    def test_unknown_trial(self):
        with self.assertRaises(SystemExit):
            rt.load_trial("nowhere")
        with self.assertRaises(SystemExit):
            rt.load_trial("Leipzig; drop")

    def test_report_sql_is_one_rolled_back_transaction(self):
        sql = rt.report_sql(self.t)
        self.assertTrue(sql.startswith("begin;\n"))
        self.assertTrue(sql.rstrip().endswith("rollback;"))
        self.assertEqual(sql.count("map_in_view("), 2 * 2 * (1 + len(self.t["hubs"])))
        self.assertIn("set local role anon", sql)

    def test_home_sql(self):
        sql = rt.home_sql(self.t)
        self.assertIn("collector_note_home_point(", sql)
        self.assertIn("TRIAL:home:", sql)

    def test_decode_and_summary(self):
        b = base64.b64encode(json.dumps({"places": [[1], [2]], "mapping": True}).encode()).decode()
        r = base64.b64encode(json.dumps({"id": "x", "timezone": "Europe/Berlin"}).encode()).decode()
        text = f'| TRIAL:view:centre:all:db:{b} |\n"v": "TRIAL:region:{r}"'
        rep = rt.decode(text)
        self.assertEqual(rep["view:centre:all:db"]["mapping"], True)
        self.assertEqual(rep["region"]["timezone"], "Europe/Berlin")
        out = rt.summary(rep)
        self.assertIn('"places": 2', out)
        self.assertNotIn("TRIAL", out)


if __name__ == "__main__":
    unittest.main()
