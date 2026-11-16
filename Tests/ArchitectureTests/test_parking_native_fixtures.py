"""Keep native parking fixtures compatible with their modules and catalog."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ParkingNativeFixtureTests(unittest.TestCase):
    def test_storage_fixture_imports_the_module_that_owns_save(self):
        native = (ROOT / 'Tests/PerchAppTests/ParkingLotCardTests.swift').read_text()
        self.assertIn('try file.save(Planner())', native)
        self.assertIn('@testable import PlannerCore', native)

    def test_native_dynamic_localization_inventory_has_translations(self):
        native = (ROOT / 'Tests/PerchAppTests/LocalizationTests.swift').read_text()
        inventory = re.search(r'for key in \[(.*?)\] \{', native, re.S)
        self.assertIsNotNone(inventory)
        assert inventory is not None
        keys = [json.loads('"' + value + '"')
                for value in re.findall(r'"((?:\\.|[^"\\])*)"', inventory.group(1))]
        self.assertIn('⌘↩ makes a task for today', keys)
        catalog = json.loads((ROOT / 'Sources/PerchApp/Resources/Localizable.json').read_text())['strings']
        for key in keys:
            with self.subTest(key=key):
                self.assertIn(key, catalog)
                self.assertTrue(catalog[key]['localizations']['zz']['stringUnit']['value'].startswith('⟦'))


if __name__ == '__main__':
    unittest.main()
