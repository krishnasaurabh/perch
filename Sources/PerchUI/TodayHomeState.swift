import Foundation
import Observation

/// Transient selection and capture preview shared by the three Today columns.
/// None of this state is stored in a planner document.
@MainActor @Observable
public final class TodayHomeState {
    public var selectedTaskID: UUID?
    public var editingTaskID: UUID?
    public var captureDraft: CaptureDraft?

    public init() {}

    public struct CaptureDraft: Equatable, Sendable {
        public var startTime: Date
        public var minutes: Int
        public var endTime: Date { startTime.addingTimeInterval(Double(minutes) * 60) }

        public init(startTime: Date, minutes: Int) {
            self.startTime = startTime
            self.minutes = minutes
        }
    }
}
