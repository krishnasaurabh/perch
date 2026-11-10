import AppKit
import EventKit
import Foundation

@MainActor
protocol CalendarAccess {
    var authorization: EKAuthorizationStatus { get }
    func requestAccess() async throws
    func calendars() -> [EKCalendar]
    func events(on day: Date, calendars: [EKCalendar]) -> [CalendarService.Event]
}

@MainActor
final class SystemCalendarAccess: CalendarAccess {
    private let ek = EKEventStore()
    var authorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    func requestAccess() async throws { _ = try await ek.requestFullAccessToEvents() }
    func calendars() -> [EKCalendar] { ek.calendars(for: .event) }
    func events(on day: Date, calendars cals: [EKCalendar]) -> [CalendarService.Event] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: cals)
        return ek.events(matching: pred).sorted { $0.startDate < $1.startDate }.map {
            CalendarService.Event(
                id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Event",
                start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                colorHex: $0.calendar.cgColor.flatMap { NSColor(cgColor: $0) }.map(SwiftUIColorBridge.hex) ?? "#8E8CF5",
                location: $0.location, calendarTitle: $0.calendar.title)
        }
    }
}
