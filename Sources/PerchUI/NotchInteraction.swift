import Foundation
import PlannerCore

/// Hover policy is independent of the persisted click-to-open preference.
public enum NotchOpenLevel: Equatable, Sendable {
    case closed, peek, everything

    public static func hover(_ trigger: NotchOpenTrigger, pill: Bool = false) -> Self {
        if pill { return .peek }
        switch trigger {
        case .hover: return .peek
        case .everything: return .everything
        case .nothing, .click, .doubleClick: return .closed
        }
    }
}

public struct NotchPeekPresentation: Equatable, Sendable {
    public let task: PlanTask?
    public let focus: FocusSession?
    public let moreToday: Int
    public var nextStep: Subtask? { task?.steps.first { !$0.done } }

    public init(planner: Planner, today: DayKey) {
        let focus = planner.focus.flatMap { $0.state == .finished ? nil : $0 }
        let open = planner.tasks.filter { $0.day == today && !$0.done }
        let task = focus.flatMap { block in planner.tasks.first { $0.id == block.taskID && !$0.done } } ?? open.first
        self.task = task
        self.focus = focus
        self.moreToday = open.filter { $0.id != task?.id }.count
    }
}

/// Return adds a task; slash or Command-Return parks a thought. Empty input never writes.
public enum NotchPeekCapture: Equatable, Sendable {
    case task(String), thought(String)

    public init?(_ input: String, park: Bool = false) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let slash = text.hasPrefix("/")
        if slash { text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text.isEmpty else { return nil }
        self = park || slash ? .thought(text) : .task(text)
    }
}

/// Compact geometry derives from foundation values. The sheet can scroll at larger text sizes.
public enum NotchPeekLayout {
    public static let width = DesignTokens.Size.peekWidth.value
    public static let inset = DesignTokens.Size.cardPadding.value - DesignTokens.Size.stepCheckboxRadius.value
    public static let gap = DesignTokens.Size.cardPadding.value / 2
    public static let blockInset = DesignTokens.TypeRole.detail.spec.size
    public static let contentHeight =
        DesignTokens.Size.addFieldHeight.value
        + DesignTokens.Size.stepRowHeight.value + DesignTokens.Size.buttonHeight.value
        + inset * 4 + gap * 3 + DesignTokens.TypeRole.detail.spec.size + DesignTokens.Size.sheetPadding.value

    /// AppKit points are y-up; SwiftUI paths are y-down. Keep screen-top clicks inside the painted path.
    public static func localPoint(_ pointer: CGPoint, in rect: CGRect) -> CGPoint? {
        guard NotchLayout.contains(rect, pointer: pointer) else { return nil }
        return CGPoint(x: pointer.x - rect.minX, y: max(0.5, rect.maxY - pointer.y))
    }

    public static func frame(workspace: CGRect, bandHeight: CGFloat) -> CGRect {
        CGRect(
            x: workspace.midX - width / 2, y: workspace.maxY - bandHeight - contentHeight,
            width: width, height: bandHeight + contentHeight)
    }
}

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

    /// Only a real eligibility transition invalidates a dwell. Keep the dismissal latch
    /// until a pointer exit or explicit opening; another display's transition is unrelated.
    @discardableResult
    public mutating func fullScreenChanged(on screen: UInt32, from previous: Bool, to current: Bool) -> Bool {
        guard previous != current, pending?.screen == screen else { return false }
        pending = nil
        return true
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
