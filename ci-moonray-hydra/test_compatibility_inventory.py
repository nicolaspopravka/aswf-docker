#!/usr/bin/env python3

import unittest

import generate_compatibility_inventory as inventory


class InventoryTests(unittest.TestCase):
    def test_profile_replacements(self):
        parsed = inventory.parse_profile(
            "moonray/*: moonray/3.6.0.1@aswf/vfx2025\n"
            "openimagedenoise/*: openimagedenoise/2.3.3@aswf/vfx2025\n"
            "openusd/*: openusd/25.05.01@aswf/vfx2025\n"
        )
        self.assertEqual(parsed["moonray"], "3.6.0.1")
        self.assertEqual(parsed["openimagedenoise"], "2.3.3")
        self.assertEqual(parsed["openusd"], "25.05.01")

    def test_external_project_versions(self):
        versions, projects = inventory.parse_native_manifest(
            "ExternalProject_Add(OpenImageDenoise\n"
            " URL https://example.invalid/oidn-2.3.3.src.tar.gz\n)\n"
            "ExternalProject_Add(USD\n"
            " GIT_REPOSITORY https://example.invalid/USD\n"
            " GIT_TAG deadbeef # v23.08\n)\n"
        )
        self.assertEqual(versions["openimagedenoise"], "2.3.3")
        self.assertEqual(versions["openusd"], "23.08")
        self.assertEqual(projects[1]["git_tag"], "deadbeef")

    def test_oidn_major_mismatch_is_not_run(self):
        outcome, reasons = inventory.classify(
            {"id": "candidate"},
            {"legacy_ndr_plugins": True},
            {"openimagedenoise": "1.2.4", "openusd": "24.08"},
            {"openimagedenoise": "2.3.3", "openusd": "23.08"},
            None,
        )
        self.assertEqual(outcome, "do-not-run")
        self.assertIn("OIDN API family differs", reasons[0])

    def test_observed_result_overrides_inference(self):
        observed = {"outcome": "verified-success", "finding": "Succeeded."}
        outcome, reasons = inventory.classify(
            {"id": "candidate"},
            {"legacy_ndr_plugins": True},
            {"openimagedenoise": "1.2.4", "openusd": "26.03"},
            {"openimagedenoise": "2.3.3", "openusd": "23.08"},
            observed,
        )
        self.assertEqual(outcome, "verified-success")
        self.assertEqual(reasons, ["Succeeded."])


if __name__ == "__main__":
    unittest.main()
