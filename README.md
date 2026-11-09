# Perch

A task manager, focus timer and notepad that live in your Mac's notch.

Hover the notch or press **⌥N**. Type or say what's on your mind, and it becomes a sorted task.

## What it does

| | |
|---|---|
| **Notch workspace** | Hover the notch, or press ⌥N, to open it. On monitors and Macs without a notch, Perch draws one. It follows your pointer between screens and steps aside for full-screen apps. |
| **Natural-language capture** | `text dad tomorrow at 6pm !high #home every monday for 30 min due friday` fills in the day, reminder, priority, project, repeat, time limit and deadline. A live hint under the field shows what it read. |
| **Voice** | Click the mic and speak. Recognition is on-device only (`requiresOnDeviceRecognition = true`). |
| **Focus timer** | A countdown or stopwatch that stays visible in the closed notch. Pause, resume or add 5 minutes. There are three timer faces: dot matrix, digital and minimal. Time only counts while the timer runs. |
| **Week view** | Drag tasks between days or into the Inbox. Past days are a read-only record. |
| **Notepad** | One per day, saved automatically. **⌘↩** turns the current line into a task. |
| **Clips** | New screenshots and screen recordings (and, optionally, anything you copy) hang on a line in the notch. Concealed copies from password managers are skipped. |
| **Reminders** | A reminder rings in the notch with Start, Snooze and Done. Optionally, Perch syncs both ways with a "Perch" list in Apple Reminders, so tasks reach your iPhone and Watch. |
| **Calendar** | Shows today's events and a "starts in 5 min" nudge. Read-only. |
| **Overdue carry-forward** | Copy unfinished tasks to today, or leave them in history. |
| **Insights** | Streak, completed vs planned, focus minutes, the last 7 days against the 7 before, and peak hours. |
| **AI sorting (optional)** | On-device Apple Intelligence (FoundationModels, macOS 26) sets a priority and project. Whatever you type yourself always wins. |
| **MCP server for agents** | Run the app binary with `--mcp` and it acts as a local MCP server. Connect it to Claude Code, the Claude app or Cursor with one click in Settings. 18 tools. Agent changes show up live and ⌘Z undoes them. |
| **URL scheme** | `perch://add?title=Buy%20milk&date=tomorrow`, `perch://open?page=week` |

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
