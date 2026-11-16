"""Catalog compatibility survives replacement of a presentation caller."""
import json
import pathlib
import tempfile
import unittest
from unittest import mock

import update_localization as catalog

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ReminderCatalogCompatibilityTests(unittest.TestCase):
    def test_legacy_reminder_key_survives_without_a_source_caller(self):
        with tempfile.TemporaryDirectory() as directory:
            empty = pathlib.Path(directory)
            with mock.patch.multiple(catalog, APP=empty, CORE=empty, MCP=empty, REMINDERS=empty):
                self.assertIn("In a bit", catalog.human_app_strings())

    def test_all_app_catalog_copies_keep_the_exact_pseudolocalization(self):
        for relative in ["Resources/Localizable.xcstrings", "Sources/PerchApp/Resources/Localizable.xcstrings",
                         "Sources/PerchApp/Resources/Localizable.json"]:
            with self.subTest(path=relative):
                strings = json.loads((ROOT / relative).read_text())["strings"]
                entry = strings["In a bit"]["localizations"]
                self.assertEqual(entry["en"]["stringUnit"]["value"], "In a bit")
                self.assertEqual(entry["zz"]["stringUnit"]["value"], "⟦În à bït ·~⟧")


if __name__ == "__main__":
    unittest.main()
