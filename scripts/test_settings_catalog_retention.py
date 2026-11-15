"""Settings label changes must not prune previously shipped translations."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import update_localization as catalog


class SettingsCatalogRetentionTests(unittest.TestCase):
    def test_refresh_is_additive_and_check_still_requires_new_keys(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "App/Localizable.xcstrings"
            ui = root / "UI/Localizable.xcstrings"
            bundled = root / "Resources/Localizable.xcstrings"
            app.parent.mkdir()
            app.write_text(catalog.rendered(catalog.catalog({"Previous label"})))
            with patch.multiple(catalog, ROOT=root, APP_CATALOG=app, UI_CATALOG=ui, BUNDLED_CATALOG=bundled), \
                    patch.object(catalog, "human_app_strings", return_value={"Current label"}), \
                    patch.object(catalog, "collect", return_value=set()), \
                    patch("sys.argv", ["update_localization.py"]):
                catalog.main()
                stored = json.loads(app.read_text())["strings"]
                self.assertIn("Previous label", stored)
                self.assertIn("Current label", stored)
                self.assertEqual(app.read_bytes(), app.with_suffix(".json").read_bytes())
                self.assertEqual(app.read_bytes(), bundled.read_bytes())
                with patch("sys.argv", ["update_localization.py", "--check"]):
                    catalog.main()
                    with patch.object(catalog, "human_app_strings", return_value={"Missing label"}):
                        with self.assertRaises(SystemExit):
                            catalog.main()


if __name__ == "__main__":
    unittest.main()
