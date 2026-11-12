"""Fail closed on missing native probe coverage; never a substitute for running it."""
import argparse
import json
from pathlib import Path

THEME_PAGES = {
    "settings-General", "settings-Workspace", "settings-Focus timer",
    "settings-AI agents", "settings-System", "dashboard-Upcoming",
    "dashboard-History", "dashboard-Insights", "dashboard-Projects",
    "welcome", "details", "details-removed", "week", "clips",
}
THEME_STATES = {"standard", "enlarged-type", "increased-contrast", "enlarged-increased"}


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
                or len(passed) != 19 or len(set(passed)) != 19):
            raise ValueError("unbroken keyboard matrix is incomplete or red")
        if sum(label.startswith("week:") for label in passed) != 9:
            raise ValueError("Week keyboard coverage is incomplete")
        if sum(label.startswith("clips:") for label in passed) != 10:
            raise ValueError("Clips keyboard coverage is incomplete")
        for run in report:
            if run.get("ok") is not True:
                raise ValueError("a keyboard control failed")
            if run.get("broken") and run.get("red") != run["broken"]:
                raise ValueError("negative control did not fail its own assertion")
        return len(passed)
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
