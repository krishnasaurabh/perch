"""Guard product dependency direction and platform-neutral source boundaries."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TargetBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        package = json.loads(subprocess.check_output(
            ["swift", "package", "dump-package"], cwd=ROOT, text=True))
        cls.targets = {target["name"]: target for target in package["targets"]}

    def dependencies(self, target):
        return {next(iter(dep.values()))[0] for dep in self.targets[target]["dependencies"]}

    def test_domain_has_no_outward_dependency(self):
        self.assertEqual(self.dependencies("PlannerCore"), set())
        self.assertFalse((ROOT / "Sources/PlannerCore/MCP").exists())
        for path in (ROOT / "Sources/PlannerCore").glob("*.swift"):
            self.assertNotRegex(path.read_text(), r"import (PerchUI|PerchMCP|AppKit|SwiftUI)")
        self.assertFalse((ROOT / "Sources/PlannerCore/NotchLayout.swift").exists())

    def test_portable_adapters_depend_only_on_domain(self):
        for target in ("PerchMCP", "PerchUI"):
            self.assertEqual(self.dependencies(target), {"PlannerCore"})
        for name in ("ShortcutKey.swift", "ClipStorage.swift", "NotchLayout.swift"):
            source = (ROOT / "Sources/PerchUI" / name).read_text()
            self.assertNotRegex(source, r"import (AppKit|SwiftUI|Carbon|Darwin)")

    def test_real_suites_and_thin_cli(self):
        for name in ("PlannerCoreTests", "PerchMCPTests", "PerchUITests"):
            self.assertEqual(self.targets[name]["type"], "test")
            self.assertTrue(list((ROOT / "Tests" / name).glob("*.swift")))
        self.assertEqual(self.dependencies("PerchCLI"), {"PlannerCore", "PerchMCP"})
        entry = (ROOT / "Sources/Perch/main.swift").read_text()
        self.assertEqual(entry.strip(), "import PerchApp\n\nPerchApplication.run()")
        self.assertNotIn("MCPServer", (ROOT / "Sources/PlannerCore/Models.swift").read_text())

    def test_app_tests_require_native_ci(self):
        import ast
        import re
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        match = re.search(r"core_only = lambda p: p.startswith\((\(.*?\))\)", workflow)
        assert match is not None, "Missing CI path-selection rule"
        portable = ast.literal_eval(match.group(1))
        self.assertFalse("Tests/PerchAppTests/PlannerStoreTests.swift".startswith(portable))
        self.assertFalse("Sources/PerchApp/App/PlannerStore.swift".startswith(portable))
        self.assertTrue("Tests/PlannerCoreTests/PlannerUndoTests.swift".startswith(portable))

    def test_mac_app_layer_is_testable_library(self):
        self.assertTrue(list((ROOT / "Tests/PerchAppTests").glob("*.swift")))
        if sys.platform == "darwin":
            self.assertEqual(self.targets["PerchApp"]["type"], "regular")
            self.assertEqual(self.dependencies("Perch"), {"PerchApp"})
            self.assertIn("PerchApp", self.dependencies("PerchAppTests"))
        else:
            self.assertNotIn("PerchApp", self.targets)


if __name__ == "__main__":
    unittest.main()
