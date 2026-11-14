"""Exercise the workflow's layout validator with explicit routing fixtures."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest
import warnings
from typing import Any
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def validator():
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    step = workflow.split("- name: NotchLayout frames (fixtures + live) and mouse routing", 1)[1]
    return textwrap.dedent(step.split("<<'EOF'\n", 1)[1].split("          EOF", 1)[0])


def screen(*, opened=False, tab=False) -> dict[str, Any]:
    routing = dict.fromkeys([
        "notchCenterTopEdge", "leftWing", "shoulderCorner", "justBelowShape", "leftOfShape",
        "workspaceCenter", "windowCornerOutsideShape", "menuBarRight", "menuBarAboveWorkspaceEdge",
        "shapeTopCornerOutside", "shapeTopInside", "timerCapsuleCenter", "timerGap", "closedTabCenter",
    ], False)
    if opened:
        routing.update(workspaceCenter=True, shapeTopInside=True)
    else:
        routing["closedTabCenter"] = tab
    row = dict(
        name="Fixture", frame=dict(x=-1024, y=300, w=1024, h=768),
        notch=dict(x=-548, y=1044, w=72, h=24), idle=dict(x=-548, y=1044, w=154, h=24),
        workspace=dict(x=-912, y=500, w=800, h=532), window=dict(x=-936, y=452, w=848, h=616),
        visible=True, expanded=opened, hardwareNotch=False, menuBarHeight=24,
        workspaceAttached=False, ignoresMouse=not opened and not tab,
        closedVisible=tab and not opened, routing=routing,
    )
    if tab and not opened:
        row["closedTab"] = dict(x=-560, y=1022, w=96, h=22)
    return row


class ClosedLayoutProbeTests(unittest.TestCase):
    def run_validator(self, closed, *, opened=None, default=None):
        with tempfile.TemporaryDirectory() as directory:
            rows = {
                "fixtures": [{"name": "Fixture"}], "live-closed": closed if isinstance(closed, list) else [closed],
                "live-open": [opened or screen(opened=True)],
                "default-closed": [default or screen()], "default-open": [screen(opened=True)],
            }
            for name, value in rows.items():
                Path(directory, name + ".json").write_text(json.dumps(value))
            output = io.StringIO()
            with patch.object(sys, "argv", ["layout-validator", directory]), redirect_stdout(output), warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                try:
                    exec(compile(validator(), "layout-validator", "exec"), {"__name__": "__main__"})
                except SystemExit as result:
                    return result.code, output.getvalue()
                except (AssertionError, KeyError) as error:
                    return 1, str(error)
            self.fail("Validator must return an exit status")

    def test_flat_idle_routes_nothing_even_when_panel_is_visible(self):
        code, output = self.run_validator(screen())
        self.assertEqual(code, 0, output)

    def test_flat_active_tab_is_the_only_closed_surface(self):
        code, output = self.run_validator(screen(tab=True))
        self.assertEqual(code, 0, output)

    def test_missing_closed_visibility_is_not_silently_skipped(self):
        row = screen()
        del row["closedVisible"]
        self.assertNotEqual(self.run_validator(row)[0], 0)

    def test_invisible_idle_panel_still_checks_routing_and_capture(self):
        row = screen()
        row["visible"] = False
        row["ignoresMouse"] = False
        self.assertNotEqual(self.run_validator(row)[0], 0)
        row["ignoresMouse"] = True
        row["routing"]["notchCenterTopEdge"] = True
        self.assertNotEqual(self.run_validator(row)[0], 0)

    def test_tab_routing_and_geometry_are_required(self):
        for change in ("missing", "height", "menu", "center", "routing"):
            with self.subTest(change=change):
                row = screen(tab=True)
                if change == "missing":
                    del row["closedTab"]
                elif change == "height":
                    row["closedTab"]["h"] = 21
                elif change == "menu":
                    row["closedTab"]["y"] += 1
                elif change == "center":
                    row["closedTab"]["x"] += 1
                else:
                    row["routing"]["closedTabCenter"] = False
                self.assertNotEqual(self.run_validator(row)[0], 0)

    def test_all_removed_closed_surfaces_and_menu_probes_stay_inert(self):
        for tab in (False, True):
            for key in screen()["routing"]:
                if key == "closedTabCenter":
                    continue
                with self.subTest(tab=tab, key=key):
                    row = screen(tab=tab)
                    row["routing"][key] = True
                    self.assertNotEqual(self.run_validator(row)[0], 0)

    def test_default_capture_routing_and_open_workspace_guards_remain(self):
        default = screen()
        default["ignoresMouse"] = False
        self.assertNotEqual(self.run_validator(screen(), default=default)[0], 0)
        default = screen()
        default["routing"]["menuBarRight"] = True
        self.assertNotEqual(self.run_validator(screen(), default=default)[0], 0)
        opened = screen(opened=True)
        for key in ("workspaceCenter", "menuBarRight", "menuBarAboveWorkspaceEdge"):
            row = deepcopy(opened)
            row["routing"][key] = not row["routing"][key]
            self.assertNotEqual(self.run_validator(screen(), opened=row)[0], 0)
        opened["workspace"]["h"] = (
            opened["frame"]["y"] + opened["frame"]["h"] - max(opened["menuBarHeight"], 24)
            - 8 - opened["workspace"]["y"] + 1
        )
        self.assertNotEqual(self.run_validator(screen(), opened=opened)[0], 0)

    def test_hardware_capsule_dimensions_and_gap_still_have_guards(self):
        row = screen()
        row.update(hardwareNotch=True, closedVisible=True)
        row["routing"].update(notchCenterTopEdge=True, leftWing=True, shapeTopInside=True)
        row["timerCapsule"] = dict(x=-470, y=1047, w=76, h=18)
        row["routing"].pop("closedTabCenter")
        code, output = self.run_validator(row)
        self.assertEqual(code, 0, output)
        code, output = self.run_validator([screen(tab=True), row, screen()])
        self.assertEqual(code, 0, output)
        for field in ("x", "w"):
            invalid = deepcopy(row)
            invalid["timerCapsule"][field] += 1
            self.assertNotEqual(self.run_validator(invalid)[0], 0)


if __name__ == "__main__":
    unittest.main()
