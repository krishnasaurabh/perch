import Foundation

/// A dwell belongs to one screen and one uninterrupted visit. Closing requires leaving before reopening.
public struct NotchHoverIntent: Sendable {
    public static let delay: TimeInterval = 0.25
    private var pending: (id: UUID, screen: UInt32)?
    private var blockedScreen: UInt32?

    public init() {}

    public mutating func enter(screen: UInt32?) -> UUID? {
        guard let screen else {
            pending = nil; blockedScreen = nil
            return nil
        }
        if blockedScreen != screen { blockedScreen = nil }
        guard blockedScreen != screen else { return nil }
        guard pending?.screen != screen else { return nil }
        let id = UUID()
        pending = (id, screen)
        return id
    }

    public mutating func cancel(blocking screen: UInt32? = nil) {
        pending = nil
        blockedScreen = screen
    }

    public mutating func consume(_ id: UUID, screen: UInt32, eligible: Bool) -> Bool {
        guard let candidate = pending, candidate.id == id else { return false }
        pending = nil
        return eligible && candidate.screen == screen && blockedScreen != screen
    }
}

extension NotchLayout {
    /// A closed trigger never expands into menu items, activity actions or a detached timer's transparent gap.
    public static func triggerFrame(workspace: CGRect, expanded: Bool, screen: Screen) -> CGRect {
        expanded ? workspace : notch(screen: screen)
    }

    /// A capsule's transparent corners must not consume clicks.
    public static func capsuleContains(_ rect: CGRect, pointer: CGPoint) -> Bool {
        guard contains(rect, pointer: pointer), rect.height > 0, rect.width >= rect.height else { return false }
        let radius = rect.height / 2
        let centerX = min(max(pointer.x, rect.minX + radius), rect.maxX - radius)
        let dx = pointer.x - centerX, dy = pointer.y - rect.midY
        return dx * dx + dy * dy <= radius * radius
    }
}
