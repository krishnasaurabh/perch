import AppKit
import Combine
import PerchUI
import PlannerCore

// MARK: - Notch activity timeline

/// Drives `NotchModel.activity` from the pure `NotchActivityTimeline`, with no polling: each pass shows what the
/// timeline says is visible now and sleeps until the next presentation boundary. OS reminders
/// are scheduled independently by ReminderService. Planner, calendar, wake and clock changes refresh the strip.
@MainActor
final class NotchTimelineDriver {
    private typealias Activity = PerchUI.NotchActivity

    private let store: PlannerStore
    private let calendar: CalendarService
    private weak var model: NotchModel?
    private var wake: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// Closed by the user: hidden for the rest of their window.
    private var dismissed = Set<String>()
    /// What the timeline showed on the previous pass, to tell a transition from a refresh.
    private var lastShowing: String?
    /// The timeline activity now in the model, keyed to the UI activity that shows it.
    private var presented: (timelineID: String, uiID: UUID)?
    /// The timeline activity behind `presented`, for live text.
    private var presentedActivity: Activity?
    /// When the next pass is scheduled.
    private(set) var nextWake: Date?
    /// Called after every pass with the visible timeline activity ID and the next wake (`--dump-activity`).
    var onPass: ((String?, Date?) -> Void)?

    init(store: PlannerStore, calendar: CalendarService) {
        self.store = store; self.calendar = calendar
    }

    func start(model: NotchModel) {
        self.model = model
        model.$activity.sink { [weak self] new in self?.activityChanged(to: new) }.store(in: &cancellables)
        // The running focus timer rewrites the planner every second; only reminder changes matter here.
        // `@Published` emits before storing, so hop the run loop and let the pass read the stored values.
        let alarms = store.$planner.map { NotchActivityTimeline.triggers(planner: $0) }.removeDuplicates().map { _ in ()
        }
        alarms.merge(with: calendar.$events.removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }.store(in: &cancellables)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        // A new day or a clock change also needs the new day's events; their change runs the pass.
        observe(.default, .NSCalendarDayChanged, refreshCalendar: true)
        observe(.default, .NSSystemClockDidChange, refreshCalendar: true)
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, refreshCalendar: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if refreshCalendar { self.calendar.refresh() }
                self.refresh()
            }
        }
        observers.append(token)
    }

    func refresh(now: Date = Date()) {
        guard let model else { return }
        wake?.invalidate(); wake = nil
        let events = calendar.events.map {
            NotchActivityTimeline.Event(id: $0.id, title: $0.title, start: $0.start, isAllDay: $0.allDay)
        }
        let timeline = NotchActivityTimeline(planner: store.planner, events: events)
        let live = Set(timeline.activities.map(\.id))
        dismissed.formIntersection(live)
        let showing = timeline.showing(at: now, dismissed: dismissed)
        present(showing, in: model, now: now)

        nextWake = timeline.nextChange(after: now, dismissed: dismissed)
        if let at = nextWake {
            let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            wake = t
        }
        onPass?(showing?.id, nextWake)
    }

    /// Shows the timeline's activity on a transition, or when nothing else is up. A one-off activity (focus done,
    /// a caught clip, "Added") stays until the timeline itself changes.
    private func present(_ current: Activity?, in model: NotchModel, now: Date) {
        defer { lastShowing = current?.id }
        let ours = presented.map { model.activity?.id == $0.uiID } ?? false
        guard current?.id != lastShowing || model.activity == nil else { return }
        if let current {
            if ours, presented?.timelineID == current.id { return }
            guard let ui = card(for: current, now: now) else { return }
            presented = (current.id, ui.id); presentedActivity = current
            model.show(ui)
        } else if ours {
            presented = nil; presentedActivity = nil
            model.dismissActivity()
        }
    }

    /// The user closing our activity (the X or an action) dismisses it on the timeline. Anything else that clears
    /// or replaces the activity gets a pass, so the timeline can show what is due once the notch is free.
    private func activityChanged(to new: PresentedNotchActivity?) {
        if let p = presented {
            if new?.id == p.uiID { return }
            presented = nil; presentedActivity = nil
            if new == nil { dismissed.insert(p.timelineID) }
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The strip's subtitle as of `now`: an event countdown stays current while it shows.
    func subtitle(for ui: PresentedNotchActivity, now: Date) -> String {
        guard let a = presentedActivity, presented?.uiID == ui.id, a.kind == .eventSoon else { return ui.subtitle }
        return Self.countdown(to: a.date.addingTimeInterval(NotchActivityTimeline.eventLead), now: now)
    }

    static func countdown(to start: Date, now: Date) -> String {
        "Starts in \(max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))) min"
    }

    private func card(for a: Activity, now: Date) -> PresentedNotchActivity? {
        switch a.kind {
        case .reminder:
            guard let id = a.taskID else { return nil }
            return PresentedNotchActivity(kind: .reminder(id), title: a.title, subtitle: body(for: a))
        case .eventSoon:
            let start = a.date.addingTimeInterval(NotchActivityTimeline.eventLead)
            return PresentedNotchActivity(
                kind: .eventSoon(a.id), title: a.title, subtitle: Self.countdown(to: start, now: now))
        case .eventNow:
            return PresentedNotchActivity(kind: .eventSoon(a.id), title: a.title, subtitle: "Starting now")
        case .screenshot:
            guard let url = a.fileURL else { return nil }
            return PresentedNotchActivity(kind: .clip(url), title: "On the line", subtitle: a.title)
        }
    }

    private func body(for a: Activity) -> String {
        let task = a.taskID.flatMap { id in store.planner.tasks.first { $0.id == id } }
        return task?.minutes.map { "A \($0)-minute reminder for \(a.title). Choose an action below." }
            ?? "Reminder for \(a.title). Choose an action below."
    }

}
