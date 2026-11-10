# Perch

A task manager, focus timer and notepad that live in your Mac's notch.

Hover the notch or press **⌥N** (configurable in Settings). Type or dictate a task.
Version **1.1.0** keeps Today compact and puts charts on a separate Insights tab.

## What it does

| | |
|---|---|
| **Notch workspace** | Hover the notch, or press ⌥N, to open it. Idle stays inside the hardware housing with no icon/count wings; an active timer extends only on its configured side. On monitors and Macs without a notch, Perch draws one. It follows your pointer between screens and steps aside for full-screen apps. |
| **Natural-language capture** | `text dad tomorrow at 6pm !high #home every monday for 30 min due friday` fills in the day, reminder, priority, project, repeat, time limit and deadline. A live hint under the field shows what it read. |
| **Voice** | Click the mic and speak. Recognition is on-device only (`requiresOnDeviceRecognition = true`). |
| **Focus timer** | Countdown or stopwatch, with digital (default), dot-grid and minimal faces. Running time is checkpointed every 30 seconds; a restarted app restores the saved time paused, without crediting time offline. |
| **Week view** | Drag tasks between days or into the Inbox. Busy columns scroll with overflow hints and a fixed capture field. Past days remain read-only. |
| **Day and repeats** | Set the day boundary in Settings. Repeats materialize when a day is viewed; stop a series without deleting its existing tasks. Carrying or deleting one occurrence keeps its schedule phase. Legacy completed, unlinked repeat history is not automatically restarted. |
| **Notepad** | One per day, saved automatically. **⌘↩** turns the current line into a task. |
| **Clips** | Screenshot-folder watching supplements Spotlight. Clips can be pinned, reordered and let go with a five-second Undo window. Temporary dropped files get an owned copy. The line itself is session-only, not a persistent file library. Concealed clipboard content is skipped. |
| **Reminders** | A reminder rings in the notch with Start, Snooze and Done. Optionally, Perch syncs both ways with a "Perch" list in Apple Reminders, so tasks reach your iPhone and Watch. |
| **Calendar** | Shows events and timeline nudges. Check-off state is stored locally and counted separately from completed tasks; source calendars are never edited. |
| **Overdue carry-forward** | Ask, automatically carry, or leave unfinished tasks in history. Overdue tasks can also be completed on their original day. |
| **Insights** | Streak, completed vs planned, focus minutes, the last 7 days against the 7 before, and peak hours. |
| **AI sorting (optional)** | On-device Apple Intelligence (FoundationModels, macOS 26) sets a priority and project. Whatever you type yourself always wins. |
| **MCP server for agents** | Local stdio server with 18 tools and one-click setup for Claude Code, Claude Desktop and Cursor. Task rows identify the client that created them; Dashboard history can filter by agent. External changes refresh in the app and are undoable. |
| **URL scheme** | `perch://add?title=Buy%20milk&date=tomorrow`, `perch://open?page=week` |

## Verification and remaining limits

The test suite covers planner rules, migration, dates, repeats, focus accounting and MCP.
The macOS workflow is configured to build the app, exercise its MCP binary and run
crash/restart and rendered-view probes. This is not a claim that every workflow run passes.

Rendered snapshots and in-process probes do **not** prove physical hover/hotkeys, live VoiceOver, multi-monitor routing, fullscreen transitions, permission dialogs or Apple service synchronization. Those remain hardware acceptance checks. Global Undo versus truly simultaneous external writes is not a proven transactional merge. Calendar fetching uses the civil day even when the task day has a custom boundary.

## Agents (MCP)

In Perch, open Settings › AI agents › Connect. Or from a terminal:

```sh
claude mcp add --scope user perch -- "/Applications/Perch.app/Contents/MacOS/Perch" --mcp
```

The tools are `add_tasks`, `list_tasks`, `get_task`, `complete_task`, `reopen_task`, `rename_task`, `delete_task`,
`move_task`, `update_task`, `snooze_reminder`, `start_timer`, `pause_timer`, `resume_timer`, `stop_timer`,
`read_notepad`, `write_notepad`, `get_insights` and `list_projects`.

The app and the MCP process share `~/Library/Application Support/Perch/planner.json`. Writes use an
`flock` and atomic file replacement; the app polls for external changes.

## Build

```sh
swift test                      # PlannerCore + MCP tests (macOS or Linux)
scripts/bundle.sh               # macOS: dist/Perch.app + dist/Perch-<ver>.dmg (universal, ad-hoc signed)
SIGN_ID="Developer ID Application: …" scripts/bundle.sh   # real signing
swift run perch-cli add "text dad tomorrow 6pm"            # headless CLI on any platform
```

The app requires macOS 14 or later and a Swift toolchain compatible with the APIs used by the app
(the macOS workflow selects Xcode 26). AI sorting needs macOS 26 with Apple Intelligence.
PlannerCore tests and the CLI also run on Linux with Swift 5.10 or later.

To install a local macOS build, copy `dist/Perch.app` to `/Applications`, or open the
DMG and drag Perch to Applications. The default build is ad-hoc signed, not notarized;
macOS may block it under Gatekeeper. There is no automatic updater.

## Layout

```
Sources/PlannerCore/   models, TaskCapture (NL parser), TaskRepeat, FocusSession, PlannerEngine, PlannerFile, MCP/
Sources/Perch/         AppKit/SwiftUI app: Notch/, Workspace/, Services/, Settings/
Sources/PerchCLI/      perch-cli (MCP server + scriptable CLI)
Tests/                 XCTest suites
```

## Repository checks

Enable local hooks: `git config core.hooksPath .githooks`.
Check staged files: `python3 scripts/check_repository.py --staged`. CI checks reachable history automatically.

## License

[MIT License](LICENSE).
