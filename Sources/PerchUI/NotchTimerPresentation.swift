import Foundation
import PlannerCore

/// A bounded visual face with an exact, unabridged value for accessibility and help.
public struct NotchTimerPresentation: Equatable, Sendable {
    public let text: String
    public let fullText: String
    public let usesDotMatrix: Bool

    public init(seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000_000_000 else {
            text = "--:--"; fullText = PerchL10n.text("Timer unavailable"); usesDotMatrix = false
            return
        }
        fullText = TimerText.clock(seconds)
        usesDotMatrix = seconds < 100 * 3600
        if usesDotMatrix {
            text = fullText
        } else if seconds < 1000 * 86400 {
            text = "\(Int(seconds / 3600))h"
        } else if seconds < 365_000 * 86400 {
            text = "\(Int(seconds / 86400))d"
        } else {
            text = "\(Int(seconds / (365 * 86400)))y"
        }
    }

    /// Exact 3x5 glyph widths, including dot and character spacing.
    public static func units(for text: String) -> CGFloat {
        let colons = CGFloat(text.filter { $0 == ":" }.count)
        let digits = CGFloat(text.count) - colons
        return digits * 3.9 + colons + CGFloat(max(0, text.count - 1)) * 1.2
    }

    public static func dot(for text: String, width: CGFloat, height: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        // Never impose a lower bound that silently makes the face wider than its container.
        return max(0, min(width / units(for: text), height / 6.8, 2.2))
    }
}
