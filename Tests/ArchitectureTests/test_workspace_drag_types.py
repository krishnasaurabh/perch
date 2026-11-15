"""The installed bundle must declare the custom local drag formats."""
import pathlib
import plistlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WorkspaceDragTypeTests(unittest.TestCase):
    def test_every_exported_drag_type_has_exactly_one_data_declaration(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TaskDragItem.swift").read_text()
        identifiers = re.findall(r'UTType\(exportedAs: "([^"]+)"', source)
        self.assertEqual(len(identifiers), 2)
        with (ROOT / "Resources/Info.plist").open("rb") as handle:
            declarations = plistlib.load(handle)["UTExportedTypeDeclarations"]
        for identifier in identifiers:
            matches = [item for item in declarations if item["UTTypeIdentifier"] == identifier]
            self.assertEqual(len(matches), 1, identifier)
            self.assertEqual(matches[0]["UTTypeConformsTo"], ["public.data"])
        self.assertEqual(len(set(identifiers)), 2)


if __name__ == "__main__":
    unittest.main()
