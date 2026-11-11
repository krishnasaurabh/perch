import Foundation

/// Keyboard movement follows displayed order and never wraps into an unrelated control.
public enum TodayTaskNavigation {
    public static func neighbor(in ids: [UUID], from current: UUID, offset: Int) -> UUID? {
        guard let index = ids.firstIndex(of: current), !ids.isEmpty else { return nil }
        return ids[min(max(0, index + offset), ids.count - 1)]
    }

    /// Completing or deleting a row keeps its position: next row, otherwise the previous row.
    /// No surviving rows returns nil so the caller can put focus back in capture.
    public static func afterRemoval(of current: UUID, previous: [UUID], remaining: [UUID]) -> UUID? {
        guard !remaining.isEmpty else { return nil }
        if remaining.contains(current) { return current }
        guard let index = previous.firstIndex(of: current) else { return remaining.first }
        return remaining[min(index, remaining.count - 1)]
    }
}
