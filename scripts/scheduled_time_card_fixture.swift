import Foundation

/// Captures the wall clock used by the display while keeping engine time exact and deterministic.
struct ScheduledTimeCardProbeFixture {
    let storeNow: Date
    let scheduledStart: Date

    init(displayNow: Date) {
        storeNow = displayNow
        scheduledStart = displayNow.addingTimeInterval(3_600)
    }
}
