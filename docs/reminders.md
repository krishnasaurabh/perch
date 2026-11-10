# Reminders

With notification permission enabled, Perch submits one-shot reminders to macOS before they are due. You can quit Perch without cancelling requests that macOS has accepted. The notch's short-lived reminder card is separate from the system notification.

Perch schedules the nearest 60 reminders within a rolling 14-planner-day window. Launch, wake, clock/timezone changes and logical-day rollover renew that window. While Perch is running, task edits, completion, deletion and snoozing reconcile the queue. Repeat occurrences in this window are created without opening Home or Week; browsing later weeks can create additional occurrences. The configured day-reset hour and the repeat's original schedule are retained.

A local `<planner filename>.notifications.json` sidecar alongside the planner tracks accepted, observed-delivered and missed reminder identifiers without task text. “Delivered” means macOS reported the notification, not that you saw it. “Missed” means its due time passed without confirmed delivery; an alert you already dismissed may also fall into this category. Past reminders are not replayed on launch or wake, and denied permission does not consume future reminders.

macOS controls actual presentation, sound, Focus filtering and behavior while asleep or powered off. These are best effort, not an alarm-clock guarantee. Perch must run again to renew an exhausted scheduling window or apply changes made by another process while Perch was closed. Existing reminders retain their resolved absolute time when the system timezone changes. Newly materialized repeats use the current calendar and timezone.
