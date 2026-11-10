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
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [EKCalendar] = []
    private let ek = EKEventStore()
    private let store: PlannerStore

    init(store: PlannerStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    var hasAccess: Bool { access == .fullAccess }

    func requestAccess() async {
        _ = try? await ek.requestFullAccessToEvents()
        access = EKEventStore.authorizationStatus(for: .event)
        refresh()
    }

    func refresh(day: Date = Date()) {
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { events = []; return }
        calendars = ek.calendars(for: .event)
        let hidden = Set(store.prefs.hiddenCalendarIDs)
        let cals = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { events = []; return }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: cals)
        events = ek.events(matching: pred).sorted { $0.startDate < $1.startDate }.map {
            Event(
                id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Event",
                start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                colorHex: $0.calendar.cgColor.flatMap { NSColor(cgColor: $0) }.map(SwiftUIColorBridge.hex) ?? "#8E8CF5",
                location: $0.location, calendarTitle: $0.calendar.title)
        }
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
