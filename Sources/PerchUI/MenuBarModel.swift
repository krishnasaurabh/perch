import Foundation
import PlannerCore

/// The system menu's order, permissions and privacy-safe output, independent of AppKit.
public struct MenuBarModel: Equatable, Sendable {
    public enum Entry: Equatable, Sendable {
        case runningBlock, separator, addTask, openToday, openWeek, privacy, settings, quit

        public var action: Action? {
            switch self {
            case .runningBlock, .separator: nil
            case .addTask: .addTask
            case .openToday: .openToday
            case .openWeek: .openWeek
            case .privacy: .privacy
            case .settings: .settings
            case .quit: .quit
            }
        }
    }

    public enum Action: String, CaseIterable, Sendable {
        case addTask, openToday, openWeek, privacy, settings, quit, pauseOrContinue, addFiveMinutes

        public var title: String {
            switch self {
            case .addTask: PerchL10n.text("Add a task")
            case .openToday: PerchL10n.text("Open Today")
            case .openWeek: PerchL10n.text("Open Week")
            case .privacy: PerchL10n.text("Hide counts and times")
            case .settings: PerchL10n.text("Settings")
            case .quit: PerchL10n.text("Quit Perch")
            case .pauseOrContinue: PerchL10n.text("Pause")
            case .addFiveMinutes: PerchL10n.text("+5 min")
            }
        }
    }

    public struct Shortcut: Equatable, Sendable {
        public let key: String
        public let modifiers: ShortcutModifiers
        public init(key: String, modifiers: ShortcutModifiers) { self.key = key; self.modifiers = modifiers }
    }

    /// No task title ever enters the status button's image, help or accessibility label.
    public struct Item: Equatable, Sendable {
        public let isVisible: Bool
        public let isPill: Bool
        public let text: String?
        public let showsDot: Bool
        public let isDimmed: Bool
        public let accessibilityLabel: String
    }

    public struct Block: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let pauseTitle: String
    }

    public let item: Item
    public let block: Block?
    public let privacyEnabled: Bool
    public let focus: FocusSession?
    private let display: MenuBarDisplay
    private let addShortcut: ShortcutKey

    public var entries: [Entry] {
        (block == nil ? [] : [.runningBlock, .separator])
            + [.addTask, .openToday, .openWeek, .separator, .privacy, .separator, .settings, .quit]
    }

    public init(planner: Planner, today: DayKey, now: Date, addShortcut: ShortcutKey = .default) {
        let prefs = planner.preferences
        let current = planner.focus.flatMap { $0.state == .finished ? nil : $0 }
        focus = current
        privacyEnabled = prefs.hideCountsAndTimes
        display = prefs.menuBarDisplay
        self.addShortcut = ShortcutKey.validated(addShortcut)
        let paused = current?.state == .paused
        let time = current.map { NotchTimerPresentation(seconds: $0.remaining(at: now) ?? $0.elapsed(at: now)) }
        if let current, let time {
            let task = current.taskID.flatMap { id in planner.tasks.first { $0.id == id } }
            var detail =
                prefs.hideCountsAndTimes
                ? PerchL10n.text(paused ? "Paused" : "Time set aside")
                : PerchL10n.format(current.limit == nil ? "%@ elapsed" : "%@ left", time.fullText)
            if !prefs.hideCountsAndTimes, let task, !task.steps.isEmpty {
                detail = PerchL10n.format(
                    "%@ · %lld of %lld steps", detail, task.steps.filter(\.done).count, task.steps.count)
            }
            block = Block(
                title: task?.title ?? PerchL10n.text("Time set aside"), detail: detail,
                pauseTitle: PerchL10n.text(paused ? "Continue" : "Pause"))
        } else {
            block = nil
        }
        let visible = display != .hidden
        let text: String?
        if prefs.hideCountsAndTimes || !visible {
            text = nil
        } else {
            switch display {
            case .timeLeft: text = time?.text
            case .tasksLeft:
                text = PerchL10n.format("%lld left", planner.tasks.filter { $0.day == today && !$0.done }.count)
            case .icon, .hidden: text = nil
            }
        }
        let dot = visible && current?.state == .running && (prefs.hideCountsAndTimes || display == .timeLeft)
        let label: String
        if prefs.hideCountsAndTimes {
            label = PerchL10n.text("Perch. Counts and times hidden.")
        } else if let text {
            label =
                PerchL10n.format(
                    "%@. %@", PerchL10n.text("Perch"),
                    display == .timeLeft
                        ? PerchL10n.format(
                            current?.limit == nil ? "%@ elapsed" : "%@ left", time?.fullText ?? text)
                        : text)
                + (paused && display == .timeLeft ? ". " + PerchL10n.text("Paused") : "")
        } else {
            label = PerchL10n.text("Perch")
        }
        item = Item(
            isVisible: visible, isPill: visible && (text != nil || dot), text: text, showsDot: dot,
            isDimmed: paused && display == .timeLeft, accessibilityLabel: label)
    }

    public func isEnabled(_ action: Action) -> Bool {
        switch action {
        case .pauseOrContinue: focus != nil
        case .addFiveMinutes: focus?.limit != nil
        default: true
        }
    }

    public func needsClock(menuOpen: Bool) -> Bool {
        item.isVisible && !privacyEnabled && focus?.state == .running && (display == .timeLeft || menuOpen)
    }

    public func shortcut(for action: Action) -> Shortcut? {
        switch action {
        case .addTask:
            let name = addShortcut.name ?? ""
            let special: [String: String] = [
                "Return": "\r", "Enter": "\u{3}", "Space": " ", "Tab": "\t", "Delete": "\u{8}",
                "↑": "\u{F700}", "↓": "\u{F701}", "←": "\u{F702}", "→": "\u{F703}",
                "Home": "\u{F729}", "End": "\u{F72B}", "Page Up": "\u{F72C}", "Page Down": "\u{F72D}",
                "Forward Delete": "\u{F728}", "Clear": "\u{F739}",
            ]
            let key: String
            if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...35).contains(number),
                let scalar = UnicodeScalar(0xF703 + number)
            {
                key = String(scalar)
            } else {
                key = special[name] ?? (name.count == 1 ? name.lowercased() : "")
            }
            return Shortcut(key: key, modifiers: addShortcut.modifiers)
        case .settings: return Shortcut(key: ",", modifiers: .command)
        case .quit: return Shortcut(key: "q", modifiers: .command)
        case .pauseOrContinue: return Shortcut(key: "p", modifiers: .command)
        case .addFiveMinutes: return Shortcut(key: "+", modifiers: .command)
        case .openToday, .openWeek, .privacy: return nil
        }
    }
}

/// Status-item-only geometry. Shared surface, type, stroke and motion values stay in DesignTokens.
public enum MenuBarTokens {
    public static let height = DesignTokens.Size.pillMinHeight.value
    public static let markSize = DesignTokens.Size.stepCheckboxSize.value
    public static let ringDiameter: Double = 10
    public static let perchWidth: Double = 14
    public static let markStroke = DesignTokens.Size.cardEdge.value
    public static let padding: Double = 8
    public static let gap: Double = 6
    public static let dotDiameter: Double = 5
    public static let menuWidth: Double = 290
    public static let previewWidth: Double = 340
    public static let previewHeight: Double = 100
    public static let clockInterval: Double = 1
    public static let pausedInk: UInt32 = 0xB9ADA3
    public static let background = DesignTokens.ColorToken.band.hex(in: .dark)
    public static let ink = DesignTokens.ColorToken.ink.hex(in: .dark)
    public static let dot = DesignTokens.ColorToken.brandFill.hex(in: .dark)
}
