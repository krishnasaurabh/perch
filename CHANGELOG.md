# Changelog

All notable user-facing changes to Perch. Versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

## 1.2.0 (2026-11-13)

### Added

- **Task details.** Edit a task's title, day, reminder, deadline, priority, project, repeat, time
  limit and steps in one sheet. Nothing is saved until you choose Save, Cancel discards your edits,
  and invalid dates or repeats are flagged inline.
- **Repeat picker** with daily, weekday, weekly (pick the days), monthly, quarterly, yearly and
  custom schedules, plus "count from completion".
- **Week view rebuilt as a calendar.** Columns follow your first weekday, you can check off
  today's tasks there, long titles stay readable, and the Inbox is kept separate from the seven days.
- **Two-way Reminders sync (experimental, opt-in).** Edits to linked reminders on your iPhone or
  Watch come back into Perch. Conflicting edits pause sync rather than pick a winner, and existing
  reminders are never adopted.
- **Notch task count (opt-in).** Shows how many of today's tasks are left, never their titles.
  Hide it from the Perch menu before screen sharing.
- **MCP:** `list_inbox`, `list_overdue` and `update_overdue` (complete, carry or dismiss), typed
  structured results with output schemas on every tool, and stricter input validation. 21 tools.
- **Keyboard.** Tab, Space and arrow keys reach every Today row action, the page picker, the
  Week Inbox, Settings and the Dashboard. Command-Z undoes project changes in the Dashboard.

### Changed

- Today keeps actions visible on every row and puts short task actions on the title line, so more
  tasks fit. Capture and Undo stay pinned below the list, and overdue tasks open in an on-demand
  review instead of a banner.
- Insights stacks its cards at narrow widths and shows planned and completed tasks side by side.
- Screenshot watching for Clips is now an explicit choice in Welcome and stays off until you
  turn it on. Clip actions are always visible.
- Built-in displays never get a drawn notch. Drawing one on external monitors is off by default.
- Settings shows each permission's state with a link to System Settings. Failures stay visible
  with a Retry button.
- Interface text uses English string catalogs. Dates, counts and repeat summaries follow the
  presentation locale without changing stored dates. Task entry declares English support and
  reports other app languages instead of guessing.
- Planner and notch updates are event-driven instead of polled, and Reminders reconciliation is
  idempotent and ownership-aware.
- Built with Swift 6 language mode.

### Fixed

- Week's "+N more" no longer counts a task that is already on screen.
- Clicks on the closed notch follow its drawn shape, and activity-strip controls are clickable.
- Clips toolbar controls reflow at narrow widths instead of being cut off.

## 1.1.1 (2026-11-10)

### Added

- An app icon, with simplified artwork for the smallest sizes.

### Changed

- Reminders are handed to macOS ahead of time (the nearest 60 within 14 days), so accepted
  reminders still arrive after you quit Perch. Past reminders are not replayed late, and repeating
  tasks are renewed at launch, wake and each day boundary. See [docs/reminders.md](docs/reminders.md).
- The planner file moves to storage version 2, with explicit task order and precise update times.
  Your existing file is upgraded automatically after a verified backup. Perch 1.1.0 cannot open a
  version 2 file and reports it as unsupported instead of changing it.
- Device settings are stored in macOS preferences, separately from the planner file; existing
  values are carried over.
- Older focus history is stored more compactly without losing interval detail.

### Fixed

- Repeated and carried-forward tasks start with their own timer and focus state.
- Recovery counts recovered tasks correctly even when their stored order is damaged.

## 1.1.0 (2026-11-10)

First public release. The [README](README.md) describes the full feature set.

### Changed

- Insights has its own tab, so Today stays compact.
- Task capture keeps your title as typed. Repeats need an explicit phrase such as "every monday",
  and words that only look like a priority or a time stay in the title.
- Links that add tasks (`perch://add`) show the task and its date and wait for confirmation.

### Fixed

- Saving keeps up to five verified earlier versions of the planner, and refuses to replace the
  file if that copy cannot be made.
- A damaged planner file is left untouched. Perch opens the readable records in a read-only
  recovery view and reports which files to use for repair. Stored dates are validated on load.
- Undo and Redo no longer roll back a running timer or recorded focus time, and Redo of a
  deleted task works when that task already had focus history.
- Error banners show the whole message and stay until the problem is resolved.
- MCP: invalid numbers and task references are rejected without changing anything, and tools
  advertised as read-only never write.
