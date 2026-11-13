"""Fail closed on missing native probe coverage; never a substitute for running it."""
import argparse
from collections import Counter
import json
from pathlib import Path

THEME_PAGES = {
    "settings-General", "settings-Workspace", "settings-Focus timer",
    "settings-AI agents", "settings-System", "dashboard-Upcoming",
    "dashboard-History", "dashboard-Insights", "dashboard-Projects",
    "welcome", "details", "details-removed", "week", "clips",
}
THEME_STATES = {"standard", "enlarged-type", "increased-contrast", "enlarged-increased"}
CLIPS_KEYBOARD_ASSERTIONS = (
    "week: Tab reaches the task-line actions menu",
    "week: Space opens the native task-line menu",
    "week: Escape closes the task-line menu",
    "week: focus returns to the task-line menu after Escape",
    "week: cancelling the task-line menu never mutates the task",
    "week: arrow keys and Return choose Details and attach the sheet",
    "week: nested Escape dismisses the details sheet",
    "week: focus returns to the task-line menu after the sheet closes",
    "week: cancelling the details sheet never mutates the task",
    "clips: Tab reaches the clip copy control",
    "clips: Space copies the clip once into the fake pasteboard",
    "clips: focus stays on the copy control after Space",
    "clips: Tab reaches the clip actions menu",
    "clips: Space opens the native clip actions menu",
    "clips: Escape closes the clip actions menu",
    "clips: focus returns to the clip actions menu after Escape",
    "clips: cancelling the clip actions menu never pins or removes",
    "clips: arrow keys and Return choose Copy in the actions menu",
    "clips: focus returns to the clip actions menu after choosing Copy",
)
# The native producer records two successful setup preconditions per surface.
# They are required separately, not counted as keyboard interaction coverage.
CLIPS_FIXTURE_ASSERTIONS = ("week fixture", "week fixture", "clips fixture", "clips fixture")


def labels(report, minimum):
    if not isinstance(report, dict) or report.get("failed") != []:
        raise ValueError("native assertions failed or their failure list is missing")
    passed = report.get("passed")
    if not isinstance(passed, list) or len(passed) < minimum:
        raise ValueError("native assertion coverage is incomplete")
    if any(not isinstance(label, str) or not label for label in passed):
        raise ValueError("invalid assertion label")
    return passed


def validate(kind, report):
    if kind == "theme":
        passed = labels(report, 330)
        rows = report.get("rows", [])
        expected = {(page, state) for page in THEME_PAGES for state in THEME_STATES}
        observed = [(row.get("page"), row.get("state")) for row in rows]
        if len(observed) != len(expected) or set(observed) != expected:
            raise ValueError("missing, duplicate or unexpected theme capture")
        for page, state in expected:
            if not any(label.startswith(f"{page} [{state}]:") for label in passed):
                raise ValueError("theme capture has no observed assertion")
        return len(passed)
    if kind == "clips":
        if not isinstance(report, list) or not report:
            raise ValueError("missing keyboard run")
        originals = [run for run in report if run.get("broken") == ""]
        if len(originals) != 1:
            raise ValueError("exactly one unbroken keyboard run is required")
        original = originals[0]
        passed = original.get("passed", [])
        if (original.get("ok") is not True or original.get("red") != ""
                or not isinstance(passed, list)
                or any(not isinstance(label, str) for label in passed)):
            raise ValueError("unbroken keyboard matrix is incomplete or red")
        expected = Counter(CLIPS_KEYBOARD_ASSERTIONS + CLIPS_FIXTURE_ASSERTIONS)
        if Counter(passed) != expected:
            raise ValueError("keyboard interactions or fixture preconditions are missing, duplicate or unexpected")
        for run in report:
            if run.get("ok") is not True:
                raise ValueError("a keyboard control failed")
            if run.get("broken") and run.get("red") != run["broken"]:
                raise ValueError("negative control did not fail its own assertion")
        return len(CLIPS_KEYBOARD_ASSERTIONS)
    passed = labels(report, 59)
    if kind == "integration":
        required = [f"settings {pane} pane renders its content" for pane in
                    ("General", "Workspace", "Focus timer", "AI agents", "System")]
        required += [f"dashboard {tab} tab renders its content" for tab in
                     ("Upcoming", "History", "Insights", "Projects")]
        required += ["welcome never rewrites unreadable planner data",
                     "failed details save keeps the draft",
                     "Command-Z restores the deleted project and its task links"]
        if not set(required).issubset(passed):
            raise ValueError("a required page or interaction never ran")
    else:
        raise ValueError("unknown probe")
    return len(passed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("integration", "theme", "clips"))
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        count = validate(args.kind, json.loads(args.report.read_text()))
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(1, f"FAIL: {args.kind} probe coverage: {error}\n")
    print(f"PASS: {args.kind} native report verifies {count} assertions")


if __name__ == "__main__":
    main()
