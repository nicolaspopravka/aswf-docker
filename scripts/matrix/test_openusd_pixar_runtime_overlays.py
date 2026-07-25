import copy
import json
import tempfile
import unittest
from pathlib import Path

import openusd_pixar_runtime_overlays as overlays


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "openusd_pixar_runtime_overlays.json"


class RuntimeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.data = overlays.load_manifest(MANIFEST)

    def test_repository_manifest_is_valid(self):
        overlays.validate_manifest(MANIFEST, self.data)

    def test_pilot_selects_only_cy2025(self):
        matrix = overlays.selected_matrix(self.data, "pilot")
        self.assertEqual([entry["cy"] for entry in matrix["include"]], [2025])
        parent = matrix["include"][0]["parent_image"]
        self.assertIn(":pixar-cy2025-", parent)
        self.assertRegex(parent, r"@sha256:[0-9a-f]{64}$")

    def test_all_selects_all_requested_years(self):
        matrix = overlays.selected_matrix(self.data, "all")
        self.assertEqual(
            [entry["cy"] for entry in matrix["include"]],
            overlays.EXPECTED_YEARS,
        )

    def test_exact_scope_accepts_base_or_runtime_name(self):
        short = overlays.selected_matrix(self.data, "pixar-cy2027")
        full = overlays.selected_matrix(self.data, "pixar-cy2027-runtime")
        self.assertEqual(short, full)
        self.assertEqual(short["include"][0]["cy"], 2027)

    def test_duplicate_year_is_rejected(self):
        data = copy.deepcopy(self.data)
        data["entries"][1]["cy"] = 2023
        with self.assertRaises(overlays.ValidationError):
            overlays.validate_manifest(MANIFEST, data)

    def test_unknown_scope_is_rejected(self):
        with self.assertRaises(overlays.ValidationError):
            overlays.selected_matrix(self.data, "pixar-cy2028")

    def test_malformed_manifest_json_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text("{", encoding="utf-8")
            with self.assertRaises(overlays.ValidationError):
                overlays.load_manifest(path)

    def test_manifest_round_trips_as_strict_json(self):
        encoded = json.dumps(self.data, allow_nan=False, sort_keys=True)
        self.assertEqual(json.loads(encoded), self.data)


if __name__ == "__main__":
    unittest.main()
