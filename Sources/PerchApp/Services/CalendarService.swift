import AppKit
import Combine
import EventKit
import PlannerCore

// MARK: - Calendar (read-only)

@MainActor
final class CalendarService: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let colorHex: String
        let location: String?
        let calendarTitle: String
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var access: EKAuthorizationStatus = .notDetermined
    @Published private(set) var calendars: [EKCalendar] = []
    let source: any CalendarAccess
    private let store: PlannerStore
    private var subscriptions = Set<AnyCancellable>()

    private struct Selection: Equatable {
        let shown: Bool
        let hidden: [String]
        init(_ planner: Planner) {
            shown = planner.preferences.showCalendarMeetings
            hidden = planner.preferences.hiddenCalendarIDs
        }
    }

    var showsMeetings: Bool { store.prefs.showCalendarMeetings }

    init(store: PlannerStore, source: (any CalendarAccess)? = nil) {
        self.store = store
        self.source = source ?? SystemCalendarAccess()
        NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        // Observe the command store so Undo and external preference changes work with no Settings pane open.
        store.$planner.map { Selection($0) }.removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    var hasAccess: Bool { access == .fullAccess }

    func requestAccess() async {
        _ = try? await source.requestAccess()
        access = source.authorization
        refresh()
    }

    func refresh(day: Date = Date()) {
        access = source.authorization
        guard hasAccess else { events = []; return }
        calendars = source.calendars()
        guard showsMeetings else { events = []; return }
        let hidden = Set(store.prefs.hiddenCalendarIDs)
        let cals = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { events = []; return }
        events = source.events(on: day, calendars: cals)
    }
}

enum SwiftUIColorBridge {
    static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? .systemPurple
        return String(
            format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }
}
