import Foundation

/// A focus timer. Countdown when `limit` is set, stopwatch otherwise.
/// Time only accrues while running; pausing (or the Mac sleeping) stops the clock.
public struct FocusSession: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, paused, finished }

    public var taskID: UUID?
    /// Countdown length in seconds; nil = stopwatch.
    public var limit: Double?
    public var state: State
    /// Seconds banked before the current running stretch.
    public var banked: Double
    /// When the current running stretch began (nil while paused/finished).
    public var resumedAt: Date?
    public var startedAt: Date

    public init(taskID: UUID?, limit: Double?, now: Date) {
        self.taskID = taskID; self.limit = limit; state = .running
        banked = 0; resumedAt = now; startedAt = now
    }

    public func elapsed(at now: Date) -> Double {
        banked + (state == .running ? max(0, now.timeIntervalSince(resumedAt ?? now)) : 0)
    }

    public func remaining(at now: Date) -> Double? {
        limit.map { max(0, $0 - elapsed(at: now)) }
    }

    public func isOver(at now: Date) -> Bool {
        if let r = remaining(at: now) { return r <= 0 }
        return false
    }

    func runningSegment(at now: Date) -> FocusSegment? {
        guard state == .running, let start = resumedAt else { return nil }
        let end = limit.map { min(now, start.addingTimeInterval(max(0, $0 - banked))) } ?? now
        return end > start ? FocusSegment(taskID: taskID, start: start, end: end) : nil
    }

    /// Banks the running tail without pausing. Recording the returned segment is the engine's job.
    @discardableResult
    public mutating func checkpoint(at now: Date) -> FocusSegment? {
        guard let segment = runningSegment(at: now) else { return nil }
        banked += segment.seconds
        resumedAt = segment.end
        return segment
    }

    /// Ends the running stretch; returns the segment that was just focused, if any.
    @discardableResult
    public mutating func pause(at now: Date) -> FocusSegment? {
        guard state == .running else { return nil }
        let segment = checkpoint(at: now)
        resumedAt = nil
        state = .paused
        return segment
    }

    public mutating func resume(at now: Date) {
        guard state == .paused else { return }
        resumedAt = now; state = .running
    }

    @discardableResult
    public mutating func finish(at now: Date) -> FocusSegment? {
        let seg = pause(at: now)
        state = .finished
        return seg
    }

    /// The +5 min button.
    public mutating func extend(by seconds: Double) {
        if let l = limit { limit = l + seconds }
    }
}

public enum TimerText {
    /// 25:00, 1:05:09
    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 1h 20m, 45m
    public static func short(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}
