"""Both Settings opening pickers must use the independent click bridge."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GeneralOpeningBindingTests(unittest.TestCase):
    def test_general_and_notch_share_the_opening_preference_bridge(self):
        # The shared bridge's persistence and routing are exercised by
        # test_settings_opening_binding; neither live picker may bypass it.
        for pane in ("SettingsGeneralPane.swift", "SettingsNotchPane.swift"):
            with self.subTest(pane=pane):
                source = (ROOT / "Sources/PerchApp/Settings" / pane).read_text()
                selections = re.findall(
                    r'Picker\("Open the notch on", selection: (.+)\) \{', source
                )
                self.assertEqual(
                    selections,
                    ["SettingsView.openingPreference(store: store)"],
                    "The opening picker must update the independent click preference",
                )


if __name__ == "__main__":
    unittest.main()
