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
    func requestAccess() async throws {
        do {
            let granted = try await ek.requestFullAccessToEvents()
            PlatformLog.calendar.info("requestAccess completed granted=\(granted, privacy: .public)")
        } catch {
            PlatformLog.calendar.error("requestAccess failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            throw error
        }
    }
    func calendars() -> [EKCalendar] {
        let calendars = ek.calendars(for: .event)
        PlatformLog.calendar.debug("calendars loaded count=\(calendars.count, privacy: .public)")
        return calendars
    }
    func events(on day: Date, calendars cals: [EKCalendar]) -> [CalendarService.Event] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: cals)
        let events = ek.events(matching: pred).sorted { $0.startDate < $1.startDate }
        PlatformLog.calendar.debug(
            "events loaded calendars=\(cals.count, privacy: .public) count=\(events.count, privacy: .public)")
        return events.map {
            CalendarService.Event(
                id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Event",
                start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                colorHex: $0.calendar.cgColor.flatMap { NSColor(cgColor: $0) }.map(SwiftUIColorBridge.hex) ?? "#8E8CF5",
                location: $0.location, calendarTitle: $0.calendar.title)
        }
    }
}
