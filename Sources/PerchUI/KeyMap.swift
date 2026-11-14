/// Shared shortcut descriptions and input matching. No UI framework or event monitor lives here.
public enum KeyMap {
    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case anywhere, writing, time, checklist, week
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .anywhere: return PerchL10n.text("Anywhere")
            case .writing: return PerchL10n.text("Writing")
            case .time: return PerchL10n.text("Time")
            case .checklist: return PerchL10n.text("The checklist")
            case .week: return PerchL10n.text("Week")
            }
        }
        public var surface: DesignTokens.Surface {
            switch self {
            case .anywhere, .checklist: return .paper
            case .writing: return .butter
            case .time: return .blush
            case .week: return .mint
            }
        }
        public var entries: [Entry] { KeyMap.entries.filter { $0.group == self } }
    }

    public enum Action: String, Sendable {
        case openPerch, close, undo, addTask, indentStep, outdentStep, startTaskTime
        case pauseOrContinue, addFiveMinutes, moveTaskSelection, checkTask, openTask
        case showSteps, reorderTask, deleteTask, parkTask, openWeek, moveDaySelection, pushTaskDay, showKeys

        public var label: String {
            switch self {
            case .openPerch: return PerchL10n.text("Open Perch, ready to type")
            case .close: return PerchL10n.text("Close it")
            case .undo: return PerchL10n.text("Undo the last change")
            case .addTask: return PerchL10n.text("Add the task")
            case .indentStep: return PerchL10n.text("Make it a step")
            case .outdentStep: return PerchL10n.text("Move it back out")
            case .startTaskTime: return PerchL10n.text("Start time on the task")
            case .pauseOrContinue: return PerchL10n.text("Pause or continue")
            case .addFiveMinutes: return PerchL10n.text("Add five minutes")
            case .moveTaskSelection: return PerchL10n.text("Move between tasks")
            case .checkTask: return PerchL10n.text("Check it off")
            case .openTask: return PerchL10n.text("Open the task")
            case .showSteps: return PerchL10n.text("Show or hide its steps")
            case .reorderTask: return PerchL10n.text("Move it up or down")
            case .deleteTask: return PerchL10n.text("Delete, with Undo")
            case .parkTask: return PerchL10n.text("Park it for later")
            case .openWeek: return PerchL10n.text("Go to Week")
            case .moveDaySelection: return PerchL10n.text("Move between days")
            case .pushTaskDay: return PerchL10n.text("Push a task a day")
            case .showKeys: return PerchL10n.text("Keys")
            }
        }
    }

    /// Only actions installed by the application have a handler. Screen-local actions
    /// stay explicitly unbound until their owning screen supplies selection and focus.
    public enum Handler: CaseIterable, Sendable {
        case close, undo, pauseOrContinue, addFiveMinutes, openWeek, showKeys
    }

    public struct Input: Equatable, Sendable {
        public var keyCode: UInt32
        public var characters: String
        public var modifiers: ShortcutModifiers
        public var isRepeat: Bool

        public init(keyCode: UInt32, characters: String, modifiers: ShortcutModifiers, isRepeat: Bool = false) {
            self.keyCode = keyCode
            self.characters = characters
            self.modifiers = modifiers
            self.isRepeat = isRepeat
        }
    }

    public struct Gesture: Equatable, Sendable {
        public enum Key: Equatable, Sendable { case code(UInt32), character(String) }
        public let key: Key
        public let modifiers: ShortcutModifiers

        public init(_ key: Key, modifiers: ShortcutModifiers = []) {
            self.key = key
            self.modifiers = modifiers
        }

        public func matches(_ input: Input) -> Bool {
            var actual = input.modifiers
            // These glyphs are shifted on some layouts and unshifted on others.
            if key == .character("?") || key == .character("+") { actual.remove(.shift) }
            guard actual == modifiers else { return false }
            switch key {
            case .code(let code): return code == input.keyCode
            case .character(let character): return character == input.characters.lowercased()
            }
        }

        public var example: Input {
            switch key {
            case .code(let code): return Input(keyCode: code, characters: "", modifiers: modifiers)
            case .character(let character): return Input(keyCode: 0, characters: character, modifiers: modifiers)
            }
        }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Action
        public let group: Group?
        public let keyCaps: [String]
        /// Multiple gestures are alternatives, not simultaneous keys (for example ↑ and ↓).
        public let gestures: [Gesture]
        public let handler: Handler?
        public var label: String { id.label }
    }

    public static let columns: [[Group]] = [[.anywhere, .writing, .time], [.checklist, .week]]
    public static let entries: [Entry] = [
        Entry(
            id: .openPerch, group: .anywhere, keyCaps: ["⌥", "N"],
            gestures: [.init(.character("n"), modifiers: .option)], handler: nil),
        Entry(id: .close, group: .anywhere, keyCaps: ["Esc"], gestures: [.init(.code(53))], handler: .close),
        Entry(
            id: .undo, group: .anywhere, keyCaps: ["⌘", "Z"], gestures: [.init(.character("z"), modifiers: .command)],
            handler: .undo),
        Entry(id: .addTask, group: .writing, keyCaps: ["↩"], gestures: [.init(.code(36))], handler: nil),
        Entry(id: .indentStep, group: .writing, keyCaps: ["Tab"], gestures: [.init(.code(48))], handler: nil),
        Entry(
            id: .outdentStep, group: .writing, keyCaps: ["⇧", "Tab"], gestures: [.init(.code(48), modifiers: .shift)],
            handler: nil),
        Entry(
            id: .startTaskTime, group: .time, keyCaps: ["⌘", "↩"], gestures: [.init(.code(36), modifiers: .command)],
            handler: nil),
        Entry(
            id: .pauseOrContinue, group: .time, keyCaps: ["⌘", "P"],
            gestures: [.init(.character("p"), modifiers: .command)], handler: .pauseOrContinue),
        Entry(
            id: .addFiveMinutes, group: .time, keyCaps: ["⌘", "+"],
            gestures: [.init(.character("+"), modifiers: .command)], handler: .addFiveMinutes),
        Entry(
            id: .moveTaskSelection, group: .checklist, keyCaps: ["↑", "↓"],
            gestures: [.init(.code(126)), .init(.code(125))], handler: nil),
        Entry(id: .checkTask, group: .checklist, keyCaps: ["Space"], gestures: [.init(.code(49))], handler: nil),
        Entry(id: .openTask, group: .checklist, keyCaps: ["↩"], gestures: [.init(.code(36))], handler: nil),
        Entry(
            id: .showSteps, group: .checklist, keyCaps: ["→", "←"], gestures: [.init(.code(124)), .init(.code(123))],
            handler: nil),
        Entry(
            id: .reorderTask, group: .checklist, keyCaps: ["⌥", "↑"],
            gestures: [.init(.code(126), modifiers: .option), .init(.code(125), modifiers: .option)], handler: nil),
        Entry(id: .deleteTask, group: .checklist, keyCaps: ["⌫"], gestures: [.init(.code(51))], handler: nil),
        Entry(
            id: .parkTask, group: .checklist, keyCaps: ["⌘", "K"],
            gestures: [.init(.character("k"), modifiers: .command)], handler: nil),
        Entry(
            id: .openWeek, group: .week, keyCaps: ["⌘", "2"], gestures: [.init(.character("2"), modifiers: .command)],
            handler: .openWeek),
        Entry(
            id: .moveDaySelection, group: .week, keyCaps: ["←", "→"], gestures: [.init(.code(123)), .init(.code(124))],
            handler: nil),
        Entry(
            id: .pushTaskDay, group: .week, keyCaps: ["⌥", "→"], gestures: [.init(.code(124), modifiers: .option)],
            handler: nil),
    ]
    /// The sheet opener belongs to the subtitle, not an extra row in the five groups.
    public static let help = Entry(
        id: .showKeys, group: nil, keyCaps: ["?"], gestures: [.init(.character("?"))], handler: .showKeys)
    public static var allEntries: [Entry] { entries + [help] }
    public static var boundEntries: [Entry] { allEntries.filter { $0.handler != nil } }
    public static var pendingEntries: [Entry] { entries.filter { $0.handler == nil } }

    public enum Context { case application, textEditing, modal }

    public struct Bindings {
        private let handlers: [Handler: () -> Bool]
        public init(handlers: [Handler: () -> Bool]) { self.handlers = handlers }
        public var unboundEntries: [Entry] { boundEntries.filter { handlers[$0.handler!] == nil } }

        @discardableResult
        public func handle(_ input: Input, context: Context) -> Bool {
            guard context != .modal, !input.isRepeat,
                let entry = boundEntries.first(where: { $0.gestures.contains { $0.matches(input) } }),
                let handler = entry.handler, let perform = handlers[handler]
            else { return false }
            // Keep punctuation, field cancellation and the text editor's own undo native.
            if context == .textEditing && [.showKeys, .close, .undo].contains(handler) { return false }
            return perform()
        }
    }

    /// Sheet-specific layout tokens. Shared colors, typography and edge metrics stay
    /// in DesignTokens; these dimensions belong only to the shortcut reference.
    public enum Layout {
        public static let width: Double = 820
        public static let height: Double = 568
        public static let columnGap: Double = 12
        public static let cardGap: Double = 10
        public static let headerInset: Double = 4
        public static let headerLineHeight: Double = 27.6
        public static let bodyLineHeight: Double = 18.9
        public static let groupLineHeight: Double = 21.6
        public static let rowHeight: Double = 32
        public static let keyColumnWidth: Double = 96
        public static let keyHeight: Double = 26
        public static let keyPadding: Double = 8
        public static let keyGap: Double = 4
        public static let headingGap: Double = 4
        public static let cardVerticalPadding: Double = 12
    }
}
