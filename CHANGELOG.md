# Changelog

All notable user-facing changes to Perch. Versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

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
