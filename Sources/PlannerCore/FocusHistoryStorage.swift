import Foundation

/// Exact interval tuples, not daily totals: arbitrary time-range and DST queries remain possible.
/// Each tuple is [original index, start, end], with dates in Foundation reference seconds.
struct PackedFocusHistory: Codable {
    var taskID: UUID?
    var intervals: [[Double]]
    var indexedSegments: [(Int, FocusSegment)] {
        intervals.map {
            (
                Int($0[0]),
                FocusSegment(
                    taskID: taskID,
                    start: Date(timeIntervalSinceReferenceDate: $0[1]),
                    end: Date(timeIntervalSinceReferenceDate: $0[2]))
            )
        }
    }
    init(taskID: UUID?, intervals: [[Double]]) { self.taskID = taskID; self.intervals = intervals }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        intervals = try c.decode([[Double]].self, forKey: .intervals)
        guard
            intervals.allSatisfy({
                $0.count == 3 && $0.allSatisfy(\.isFinite) && $0[0] >= 0 && $0[0] < Double(Int.max)
                    && $0[0].rounded(.towardZero) == $0[0] && $0[2] > $0[1]
            })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .intervals, in: c,
                debugDescription: "Expected indexed, finite, positive focus intervals.")
        }
    }
}

/// Bound the verbose working log; retain exact history in packed pages of at most 256 intervals.
/// Pending sync records and all slices of the current session stay in the working log even
/// when that deliberately exceeds the limit. No time is clipped, rounded or synthesized.
struct FocusHistoryStorage {
    static let recentLimit = 512
    var recent: [FocusSegment] = []
    var recentIndices: [Int] = []
    var archive: [PackedFocusHistory] = []

    init(_ segments: [FocusSegment], current: FocusSession?) {
        let boundary = max(0, segments.count - Self.recentLimit)
        var pages: [UUID?: Int] = [:]
        for (index, segment) in segments.enumerated() {
            let protected = !segment.isSynced || current.map { segment.end > $0.startedAt } == true
            guard index < boundary, !protected, segment.seconds > 0,
                segment.start.timeIntervalSinceReferenceDate.isFinite,
                segment.end.timeIntervalSinceReferenceDate.isFinite
            else {
                recent.append(segment); recentIndices.append(index); continue
            }
            if let page = pages[segment.taskID], archive[page].intervals.count < 256 {
                archive[page].intervals.append([
                    Double(index), segment.start.timeIntervalSinceReferenceDate,
                    segment.end.timeIntervalSinceReferenceDate,
                ])
            } else {
                pages[segment.taskID] = archive.count
                archive.append(
                    PackedFocusHistory(
                        taskID: segment.taskID,
                        intervals: [
                            [
                                Double(index), segment.start.timeIntervalSinceReferenceDate,
                                segment.end.timeIntervalSinceReferenceDate,
                            ]
                        ]))
            }
        }
    }

    static func restore(archive: [PackedFocusHistory], recent: [FocusSegment], indices: [Int]) throws -> [FocusSegment]
    {
        guard indices.count == recent.count else {
            throw PlannerError("Focus history indices do not match the working log.")
        }
        let all = archive.flatMap(\.indexedSegments) + zip(indices, recent).map { ($0, $1) }
        guard Set(all.map { $0.0 }).count == all.count,
            all.allSatisfy({ $0.0 >= 0 && $0.0 < all.count })
        else {
            throw PlannerError("Focus history indices must identify each interval exactly once.")
        }
        return all.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
