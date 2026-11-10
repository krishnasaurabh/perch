import Foundation
import PlannerCore

/// Geometry and visibility rules for the Clips line, kept here so they are testable on Linux.
public enum ClipsLineLayout {
    /// Gap between each rope end and the edge of the space it is drawn in (the card's padded content box).
    /// Larger than half the stroke width, so the round caps stay inside too.
    public static let inset = 6.0
    /// Height of the rope's two ends.
    public static let endY = 14.0
    /// How far the middle of the rope hangs below its ends.
    public static let sag = 10.0
    /// Height of the band the rope is drawn in.
    public static let bandHeight = 40.0
    /// Top of the empty message's box: the rope's lowest point, so the message reads as hanging from it.
    public static var emptyMessageTop: Double { endY + sag }

    public struct Point: Equatable {
        public let x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// A quadratic curve from `start` to `end`, pulled down by `control`.
    public struct Rope: Equatable {
        public let start: Point, control: Point, end: Point

        /// The point at `t` in 0...1 along the curve.
        public func point(at t: Double) -> Point {
            let u = 1 - t
            return Point(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }
    }

    /// The rope for a container `width` points wide, inset at both ends. The curve's lowest point is at the
    /// middle, `sag` below the ends (a quadratic's midpoint is halfway to its control point, so the control sits
    /// at twice the sag). Nil when the container is too narrow to draw a rope at all, such as before layout.
    public static func rope(width: Double) -> Rope? {
        guard width.isFinite, width > inset * 2 + 1 else { return nil }
        return Rope(
            start: Point(x: inset, y: endY),
            control: Point(x: width / 2, y: endY + sag * 2),
            end: Point(x: width - inset, y: endY))
    }

    /// The click / double-click / drag hints only mean something once a clip is on the line.
    public static func showsGestureHints(clipCount: Int) -> Bool { clipCount > 0 }
}
