#!/usr/bin/env python3
"""Choose which CI suites a change needs.

Pull requests run the always-on gate (format, Linux tests, macOS unit tests, Release
build and smoke) plus only the native probes mapped to the paths they touch. The full
suite runs when a change touches build or CI plumbing, when a path has no mapping
(fail open), when a pull request carries the ``ci:full`` label, on manual dispatch,
and on main once FULL_EVERY merges have landed since the last green full run.

A push to main tests every merge since the newest verified main commit, so a run that
supersedes queued runs still covers the merges they would have tested.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

FULL_EVERY = 10
FULL_STATUS = "Full suite"
VERIFIED_STATUS = "Main verified"

# Heavy XCTest classes: each one builds its own copy of the app (60-110 s apiece).
NATIVE = {
    "gallery": "GalleryInteractionTests",
    "workspace_nav": "WorkspaceNavigationTests",
    "keys_window": "KeysWindowNativeTests",
    "segmented": "SegmentedKeyboardTests",
    "week_inbox": "WeekInboxKeyboardTests",
    "welcome_native": "WelcomeNativeLauncherTests",
}
BEHAVIOR = ["undo", "url_requests", "focus_entry", "integration", "recovery", "motion_policy",
            "empty_states", "clips"]
LAYOUT = ["notch_layout", "home_snapshots", "redesign", "homecards", "theme", "week",
          "compact_home", "compact_insights", "large_desktop", "capture_contrast"]
FULL_ONLY = ["large_desktop", "motion_evidence"]
ALL = sorted(set(NATIVE) | set(BEHAVIOR) | set(LAYOUT) | set(FULL_ONLY))

# Paths that change how everything is built or gated: run the full suite.
FULL_TRIGGERS = [
    "Package.swift", "Package.resolved", ".github/workflows/ci.yml", "scripts/ci_select.py",
    "scripts/bundle.sh", "Sources/Perch/*", "Sources/PerchApp/App/AppDelegate.swift",
    "Sources/PerchApp/App/PerchApplication.swift", "Sources/PerchApp/App/MotionScript.swift",
    "Sources/PerchApp/App/MainActorLifetime.swift", "Tests/PlannerTestSupport/*",
]

# Paths that only the Linux job or the always-on macOS steps need.
CORE_ONLY = [
    "Sources/PlannerCore/*", "Sources/PerchMCP/*", "Tests/PlannerCoreTests/*", "Tests/PerchMCPTests/*",
    "Tests/PerchUITests/*", "Tests/ArchitectureTests/*", "scripts/test_*.py", "docs/*", "*.md",
    "LICENSE", ".gitignore", ".githooks/*", ".github/workflows/repository-hygiene.yml",
    "scripts/check_repository.py", ".swift-format", "Sources/PerchCLI/*", "scripts/remote_test.sh",
    "scripts/ci_wait.sh",
]

PA = "Sources/PerchApp/"
UI = "Sources/PerchUI/"
W = PA + "Workspace/"
C = W + "Components/"
RULES: list[tuple[list[str], set[str]]] = [
    # Planner behavior that has a native probe on top of its unit tests.
    (["Sources/PlannerCore/PlannerUndo.swift"], {"undo"}),
    (["Sources/PlannerCore/ExternalURLRequest.swift"], {"url_requests"}),
    (["Sources/PlannerCore/PlannerFile.swift", "Sources/PlannerCore/PlannerDiskDocument.swift",
      "Sources/PlannerCore/PlannerDataMaintenance.swift"], {"recovery"}),
    (["Sources/PlannerCore/Focus*.swift"], {"focus_entry"}),
    (["Sources/PlannerCore/PlannerPreviewScenarios.swift"], {"home_snapshots", "redesign"}),
    # App layer.
    ([PA + "App/PlannerStore.swift", PA + "App/PlannerRuntimeIO.swift"], {"undo", "recovery", "integration"}),
    ([PA + "App/ExternalTaskConfirmation.swift"], {"url_requests"}),
    ([PA + "App/AppDelegate+Preview.swift"], {"home_snapshots", "redesign", "notch_layout"}),
    ([PA + "App/AppDelegate+ActivityDump.swift"], {"notch_layout"}),
    ([PA + "App/WindowHost.swift"], {"keys_window", "welcome_native", "integration"}),
    ([PA + "App/AppScheduler.swift", PA + "App/AppErrors.swift"], {"integration"}),
    ([PA + "App/AppLocalization.swift", PA + "App/AppLocalizationCheck.swift"], set()),
    ([PA + "Resources/*", UI + "Resources/*", "Resources/*"], set()),
    # Notch.
    ([PA + "Notch/*"], {"notch_layout", "focus_entry", "motion_policy"}),
    ([UI + "Notch*.swift"], {"notch_layout", "focus_entry"}),
    # Workspace pages.
    ([W + "HomePage.swift"], {"compact_home", "empty_states", "workspace_nav", "home_snapshots"}),
    ([W + "HomeCards.swift", W + "TasksCard.swift", W + "YourDayCard.swift", W + "TaskRow.swift"],
     {"compact_home", "homecards", "focus_entry"}),
    ([W + "WeekPage.swift"], {"week", "week_inbox", "workspace_nav"}),
    ([W + "InsightsPage.swift"], {"compact_insights", "motion_policy", "home_snapshots"}),
    ([W + "ClipsPage.swift", W + "ClipPreview.swift"], {"clips"}),
    ([W + "GalleryPage.swift"], {"gallery"}),
    ([W + "WorkspaceView.swift"], {"workspace_nav", "integration", "compact_home"}),
    ([W + "EmptyStateView.swift"], {"empty_states"}),
    ([W + "Motion.swift"], {"motion_policy"}),
    ([W + "Theme.swift", W + "Color+Palette.swift"], {"theme", "capture_contrast", "gallery"}),
    ([W + "TaskDetailsSheet.swift", W + "DateFieldEditor.swift", W + "RepeatPickerEditor.swift",
      W + "NativeDateButtonIdentity.swift", W + "TaskDragItem.swift"], {"integration"}),
    ([W + "AgentName.swift", W + "LocalClock.swift"], {"integration"}),
    ([C + "*"], {"gallery", "theme"}),
    ([C + "PerchSegmented.swift", C + "SegmentPills.swift"], {"segmented"}),
    ([C + "AddField.swift"], {"capture_contrast"}),
    ([C + "OwlMark.swift"], {"motion_policy"}),
    # Settings and windows.
    ([PA + "Settings/*"], {"integration"}),
    ([PA + "Settings/KeysView.swift", PA + "Settings/ShortcutPreferenceRow.swift"], {"keys_window"}),
    ([PA + "Settings/WelcomeView.swift", PA + "Settings/PermissionPanel.swift"], {"welcome_native"}),
    ([PA + "Settings/InsightsDashboard.swift"], {"compact_insights"}),
    ([PA + "Services/*", "Sources/PerchReminders/*"], {"integration"}),
    ([PA + "Services/ClipsService.swift", PA + "Services/PasteboardAccess.swift"], {"clips"}),
    ([PA + "Services/NotchTimelineDriver.swift"], {"notch_layout", "focus_entry"}),
    # Portable UI logic.
    ([UI + "HomeLayout.swift", UI + "TodayHomeState.swift", UI + "TodayTabs.swift",
      UI + "TodayTaskNavigation.swift", UI + "YourDayTimeline.swift"], {"compact_home", "workspace_nav"}),
    ([UI + "WeekColumnLayout.swift", UI + "WeekTaskPolicy.swift"], {"week", "week_inbox"}),
    ([UI + "WorkspaceLayout.swift"], {"workspace_nav", "compact_home", "compact_insights"}),
    ([UI + "Clip*.swift"], {"clips"}),
    ([UI + "ThemeTokens.swift", UI + "DesignTokens.swift"], {"theme", "gallery", "capture_contrast"}),
    ([UI + "KeyMap.swift", UI + "ShortcutKey.swift"], {"keys_window", "workspace_nav"}),
    ([UI + "TaskDetails*.swift", UI + "DateFieldDraft.swift", UI + "RepeatPickerDraft.swift",
      UI + "Reminder*.swift", UI + "Permission*.swift"], {"integration"}),
    ([UI + "EdgeFade.swift"], {"week", "compact_home"}),
    ([UI + "LocalizationResources.swift", UI + "LocalizedStringCatalog.swift", UI + "PerchLocalization.swift"],
     set()),
    # App tests run on every macOS job; the heavy native ones map to their own suite.
    (["Tests/PerchAppTests/*", "Tests/PerchRemindersTests/*"], set()),
    (["Tests/PerchAppTests/GalleryInteractionTests.swift", "Tests/PerchAppTests/GalleryNativeProbe.swift"],
     {"gallery"}),
    (["Tests/PerchAppTests/WorkspaceNavigationTests.swift", "Tests/PerchAppTests/WorkspaceBandProbe.swift",
      "scripts/check_workspace_navigation.sh", "scripts/workspace_navigation_probe.swift"], {"workspace_nav"}),
    (["Tests/PerchAppTests/KeysWindowNativeTests.swift"], {"keys_window"}),
    (["Tests/PerchAppTests/SegmentedKeyboardTests.swift"], {"segmented"}),
    (["Tests/PerchAppTests/WeekInboxKeyboardTests.swift"], {"week_inbox"}),
    (["Tests/PerchAppTests/WelcomeNativeLauncherTests.swift", "Tests/PerchAppTests/WelcomeNativeProbe.swift"],
     {"welcome_native"}),
    # Probe drivers run their own probe.
    (["scripts/check_undo.sh", "scripts/undo_probe.swift"], {"undo"}),
    (["scripts/check_url_requests.sh", "scripts/url_request_probe.swift"], {"url_requests"}),
    (["scripts/check_focus_entry.sh", "scripts/focus_entry_probe.swift"], {"focus_entry"}),
    (["scripts/check_integration.sh", "scripts/integration_probe.swift", "scripts/check_allpage_matrix.sh",
      "scripts/allpage_matrix_probe.swift", "Tests/WorkspaceProbes/*", "scripts/check_probe_results.py"],
     {"integration"}),
    (["scripts/check_recovery.sh"], {"recovery"}),
    (["scripts/check_motion.sh", "scripts/motion_probe.swift"], {"motion_policy"}),
    (["scripts/check_empty_states.sh", "scripts/empty_states_probe.swift"], {"empty_states"}),
    (["scripts/check_clips_layout.sh", "scripts/clips_layout_probe.swift", "scripts/measure_clips_bounds.py",
      "scripts/run_clips_probe.py"], {"clips"}),
    (["scripts/redesign_shots.sh", "scripts/redesign_shots.list", "scripts/preview_*.py"], {"redesign"}),
    (["scripts/update_localization.py"], set()),
    (["scripts/homecards_shots.sh"], {"homecards"}),
    (["scripts/check_theme.sh", "scripts/theme_probe.swift", "scripts/theme_contrast.py"], {"theme"}),
    (["scripts/week_shots.sh", "scripts/week_measurement_hooks.py"], {"week"}),
    (["scripts/check_compact_home.sh", "scripts/compact_home_probe.swift"], {"compact_home"}),
    (["scripts/check_compact_insights.sh", "scripts/compact_insights_probe.swift",
      "scripts/measure_compact_insights.py"], {"compact_insights"}),
    (["scripts/check_capture_contrast.sh", "scripts/capture_contrast_probe.swift",
      "scripts/measure_capture_contrast.py"], {"capture_contrast"}),
    (["scripts/motion_capture.sh", "scripts/check_motion_driver.sh", "scripts/motion_*.py"], {"motion_evidence"}),
    # Always-on macOS steps cover these.
    (["scripts/check_release.py", "scripts/mcp_smoke.py", "scripts/focus_crash_check.py",
      "scripts/check_localization.py", "scripts/compile_localization.py"], set()),
]


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def select(paths: list[str]) -> dict:
    """Map changed paths to the macOS work they need."""
    paths = [p for p in paths if p]
    if not paths:
        return plan(full=True, reason="no diff available")
    suites: set[str] = set()
    macos = False
    for path in paths:
        if matches(path, FULL_TRIGGERS):
            return plan(full=True, reason=f"{path} changes build or CI plumbing")
        hit = [s for pats, s in RULES if matches(path, pats)]
        if hit:
            macos = True
            for s in hit:
                suites |= s
        elif not matches(path, CORE_ONLY):
            return plan(full=True, reason=f"{path} has no test mapping")
    return plan(full=False, macos=macos, suites=suites, reason="targeted")


def plan(*, full: bool, macos: bool = True, suites: set[str] | None = None, reason: str) -> dict:
    chosen = set(ALL) if full else set(suites or ()) - set(FULL_ONLY)
    skipped = sorted(NATIVE[s] for s in NATIVE if s not in chosen)
    return {
        "full": full,
        "macos": macos or full,
        "suites": sorted(chosen),
        "behavior": bool(chosen & set(BEHAVIOR)) and (macos or full),
        "layout": bool(chosen & set(LAYOUT)) and (macos or full),
        "skip_native": ("PerchAppTests\\.(" + "|".join(skipped) + ")") if skipped else "",
        "reason": reason,
    }


def full_due(green: list[bool]) -> bool:
    """green[i] is True when HEAD~(i+1) has a green full run. Due after FULL_EVERY merges."""
    return not any(green[: FULL_EVERY - 1])


def main_history(repo: str, limit: int = 30) -> list[tuple[str, set[str]]]:
    """(sha, green status contexts) for HEAD~1, HEAD~2, ... on the first-parent line."""
    shas = subprocess.check_output(["git", "rev-list", "--first-parent", f"--max-count={limit}", "HEAD~1"],
                                   text=True).split()
    history = []
    found_full = found_base = False
    for i, sha in enumerate(shas):
        try:
            raw = subprocess.check_output(["gh", "api", f"repos/{repo}/commits/{sha}/status"], text=True, timeout=30)
            green = {s["context"] for s in json.loads(raw or "{}").get("statuses", []) if s.get("state") == "success"}
        except (subprocess.SubprocessError, json.JSONDecodeError, KeyError):
            green = set()
        history.append((sha, green))
        found_full |= FULL_STATUS in green and i < FULL_EVERY - 1
        found_base |= VERIFIED_STATUS in green
        if found_base and (found_full or i >= FULL_EVERY - 1):
            break
    return history


def push_base(history: list[tuple[str, set[str]]]) -> str:
    """Newest main commit that a green main run verified. Merges after it are tested together."""
    return next((sha for sha, green in history if VERIFIED_STATUS in green), "")


def changed(base: str) -> list[str] | None:
    try:
        raw = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", base, "HEAD"])
    except subprocess.CalledProcessError:
        return None
    return [p for p in raw.decode().split("\0") if p]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--event", required=True)
    ap.add_argument("--base", default="")
    ap.add_argument("--labels", default="[]")
    ap.add_argument("--force-full", default="false")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    a = ap.parse_args()
    labels = {l.get("name") if isinstance(l, dict) else l for l in (json.loads(a.labels or "[]") or [])}
    if a.event == "workflow_dispatch" and a.force_full == "true":
        result = plan(full=True, reason="manual full run")
    elif a.event == "pull_request" and "ci:full" in labels:
        result = plan(full=True, reason="ci:full label")
    elif a.event == "push" and a.repo:
        history = main_history(a.repo)
        base = push_base(history)
        if full_due([FULL_STATUS in green for _, green in history]):
            result = plan(full=True, reason=f"no green full run in the last {FULL_EVERY} merges")
        elif not base:
            result = plan(full=True, reason="no verified main commit to diff against")
        else:
            paths = changed(base)
            result = plan(full=True, reason="base unavailable") if paths is None else select(paths)
            result["reason"] += f" (main since {base[:8]})"
    elif not a.base or set(a.base) == {"0"}:
        result = plan(full=True, reason="no trustworthy base")
    else:
        paths = changed(a.base)
        result = plan(full=True, reason="base unavailable") if paths is None else select(paths)
    print(json.dumps(result, indent=1))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
            for k, v in result.items():
                fh.write(f"{k}={json.dumps(v) if isinstance(v, list) else str(v).lower() if isinstance(v, bool) else v}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
