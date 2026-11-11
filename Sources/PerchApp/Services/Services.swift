import AppKit
import Combine
import PlannerCore

/// Every system integration, behind one object the views can observe.
@MainActor
final class Services: ObservableObject {
    let store: PlannerStore
    weak var model: NotchModel?
    let calendar: CalendarService
    let reminders: ReminderService
    let timeline: NotchTimelineDriver
    let remindersSync: RemindersSync
    let voice: VoiceCapture
    let clips: ClipsService

    init(store: PlannerStore) {
        self.store = store
        calendar = CalendarService(store: store)
        reminders = ReminderService(store: store)
        timeline = NotchTimelineDriver(store: store, calendar: calendar)
        remindersSync = RemindersSync(store: store)
        voice = VoiceCapture()
        clips = ClipsService(store: store)
    }

    func attach(model: NotchModel) {
        self.model = model
        clips.model = model
        timeline.start(model: model)
    }

    func focusFinished() {
        let p = store.planner
        let title = p.focus?.taskID.flatMap { id in p.tasks.first { $0.id == id }?.title }
        if p.preferences.focusCompletionSound { NSSound(named: "Glass")?.play() }
        let mins = Int((p.focus?.limit ?? 0) / 60)
        model?.show(
            .init(
                kind: .focusDone(p.focus?.taskID), title: AppL10n.text("Timer finished"),
                subtitle: title.map {
                    AppL10n.format("You gave %@ %lld minutes of focus. Mark it done, or take a break.", $0, mins)
                } ?? AppL10n.format("%lld-minute focus block done.", mins)))
        reminders.notify(
            id: "focus-\(UUID())", title: AppL10n.text("Timer finished"),
            body: title ?? AppL10n.text("Time for a break."))
    }
}
