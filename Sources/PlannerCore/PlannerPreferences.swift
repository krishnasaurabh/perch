import Foundation

/// Device state is deliberately excluded from portable planner documents.
public protocol PlannerPreferencesAdapter: AnyObject, Sendable {
    func load() throws -> DevicePreferences?
    func save(_ preferences: DevicePreferences?) throws
}

/// A single atomic value avoids partially migrated preference keys.
// Immutable adapter; UserDefaults synchronizes its own reads and writes.
public final class UserDefaultsPlannerPreferences: PlannerPreferencesAdapter, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "perch.devicePreferences.v1") {
        self.defaults = defaults; self.key = key
    }
    public func load() throws -> DevicePreferences? {
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(DevicePreferences.self, from: data)
    }
    public func save(_ preferences: DevicePreferences?) throws {
        guard let preferences else { defaults.removeObject(forKey: key); defaults.synchronize(); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(preferences), forKey: key)
        defaults.synchronize()
    }
}

/// Useful for previews and tests; separate adapters model separate devices.
// All mutable state is protected by the private lock.
public final class MemoryPlannerPreferences: PlannerPreferencesAdapter, @unchecked Sendable {
    private var value: DevicePreferences?
    private let lock = NSLock()
    public init(_ value: DevicePreferences? = nil) { self.value = value }
    public func load() -> DevicePreferences? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ preferences: DevicePreferences?) { lock.lock(); defer { lock.unlock() }; value = preferences }
}

/// Explicit field lists keep future preferences from accidentally becoming portable.
public struct DevicePreferences: Codable, Equatable, Sendable {
    public var focusCompletionSound: Bool
    public var notchTimerPlacement: NotchTimerPlacement
    public var workspaceTimerStyle: WorkspaceTimerStyle
    public var notchOpenTrigger: NotchOpenTrigger
    public var notchClickToOpen: Bool
    public var notchTaskCount: Bool
    public var notchOnMonitors: Bool
    public var showOnDisplay: String?
    public var remindersSync: Bool
    public var ringOnPhone: Bool
    public var sortWithAI: Bool
    public var catchScreenshots: Bool
    public var catchCopies: Bool
    public var workspaceCardOrder: [String]
    public var hiddenWorkspaceCards: [String]
    public var hiddenCalendarIDs: [String]
    public var welcomeCompleted: Bool
    public var openShortcut: OpenShortcut
    public var launchAtLogin: Bool
    public var blockHeadsUp: HeadsUpInterval
    public var blockEndAction: BlockEndAction
    public var notchProgressLine: Bool
    public var notchTimePill: Bool
    public var notchNextBlock: Bool
    public var notchReminderDot: Bool
    public var menuBarDisplay: MenuBarDisplay
    public var hideCountsAndTimes: Bool
    public var showCalendarMeetings: Bool
    public var meetingHeadsUp: HeadsUpInterval
    public var notifyWhenClosed: Bool
    public var persistentReminders: Bool
    public var snoozeMinutes: SnoozeDuration
    public var phoneEdits: PhoneEditPolicy
    public var agentsCanEditTasks: Bool
    public var agentsCanControlTime: Bool
    public var agentsCanReadParkingLot: Bool
    public var showAgentAttribution: Bool
    public var confirmAgentDeletes: Bool
    public var finishedTaskRetention: FinishedTaskRetention

    public init(from decoder: Decoder) throws {
        self.init(try Preferences(from: decoder))
    }

    public init(_ value: Preferences) {
        focusCompletionSound = value.focusCompletionSound
        notchTimerPlacement = value.notchTimerPlacement
        workspaceTimerStyle = value.workspaceTimerStyle
        notchOpenTrigger = value.notchOpenTrigger
        notchClickToOpen = value.notchClickToOpen
        notchTaskCount = value.notchTaskCount
        notchOnMonitors = value.notchOnMonitors
        showOnDisplay = value.showOnDisplay
        remindersSync = value.remindersSync
        ringOnPhone = value.ringOnPhone
        sortWithAI = value.sortWithAI
        catchScreenshots = value.catchScreenshots
        catchCopies = value.catchCopies
        workspaceCardOrder = value.workspaceCardOrder
        hiddenWorkspaceCards = value.hiddenWorkspaceCards
        hiddenCalendarIDs = value.hiddenCalendarIDs
        welcomeCompleted = value.welcomeCompleted
        openShortcut = value.openShortcut
        launchAtLogin = value.launchAtLogin
        blockHeadsUp = value.blockHeadsUp
        blockEndAction = value.blockEndAction
        notchProgressLine = value.notchProgressLine
        notchTimePill = value.notchTimePill
        notchNextBlock = value.notchNextBlock
        notchReminderDot = value.notchReminderDot
        menuBarDisplay = value.menuBarDisplay
        hideCountsAndTimes = value.hideCountsAndTimes
        showCalendarMeetings = value.showCalendarMeetings
        meetingHeadsUp = value.meetingHeadsUp
        notifyWhenClosed = value.notifyWhenClosed
        persistentReminders = value.persistentReminders
        snoozeMinutes = value.snoozeMinutes
        phoneEdits = value.phoneEdits
        agentsCanEditTasks = value.agentsCanEditTasks
        agentsCanControlTime = value.agentsCanControlTime
        agentsCanReadParkingLot = value.agentsCanReadParkingLot
        showAgentAttribution = value.showAgentAttribution
        confirmAgentDeletes = value.confirmAgentDeletes
        finishedTaskRetention = value.finishedTaskRetention
    }

    public func apply(to value: inout Preferences) {
        value.focusCompletionSound = focusCompletionSound
        value.notchTimerPlacement = notchTimerPlacement
        value.workspaceTimerStyle = workspaceTimerStyle
        value.notchOpenTrigger = notchOpenTrigger
        value.notchClickToOpen = notchClickToOpen
        value.notchTaskCount = notchTaskCount
        value.notchOnMonitors = notchOnMonitors
        value.showOnDisplay = showOnDisplay
        value.remindersSync = remindersSync
        value.ringOnPhone = ringOnPhone
        value.sortWithAI = sortWithAI
        value.catchScreenshots = catchScreenshots
        value.catchCopies = catchCopies
        value.workspaceCardOrder = workspaceCardOrder
        value.hiddenWorkspaceCards = hiddenWorkspaceCards
        value.hiddenCalendarIDs = hiddenCalendarIDs
        value.welcomeCompleted = welcomeCompleted
        value.openShortcut = openShortcut
        value.launchAtLogin = launchAtLogin
        value.blockHeadsUp = blockHeadsUp
        value.blockEndAction = blockEndAction
        value.notchProgressLine = notchProgressLine
        value.notchTimePill = notchTimePill
        value.notchNextBlock = notchNextBlock
        value.notchReminderDot = notchReminderDot
        value.menuBarDisplay = menuBarDisplay
        value.hideCountsAndTimes = hideCountsAndTimes
        value.showCalendarMeetings = showCalendarMeetings
        value.meetingHeadsUp = meetingHeadsUp
        value.notifyWhenClosed = notifyWhenClosed
        value.persistentReminders = persistentReminders
        value.snoozeMinutes = snoozeMinutes
        value.phoneEdits = phoneEdits
        value.agentsCanEditTasks = agentsCanEditTasks
        value.agentsCanControlTime = agentsCanControlTime
        value.agentsCanReadParkingLot = agentsCanReadParkingLot
        value.showAgentAttribution = showAgentAttribution
        value.confirmAgentDeletes = confirmAgentDeletes
        value.finishedTaskRetention = finishedTaskRetention
    }
}

/// Minutes before a block or meeting; zero disables the heads-up.
public enum HeadsUpInterval: Int, Codable, CaseIterable, Sendable {
    case off = 0, fiveMinutes = 5, tenMinutes = 10
}
public enum BlockEndAction: String, Codable, CaseIterable, Sendable { case ask, takeBreak, doNothing }
public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable { case icon, timeLeft, tasksLeft, hidden }
public enum SnoozeDuration: Int, Codable, CaseIterable, Sendable {
    case fiveMinutes = 5, tenMinutes = 10, fifteenMinutes = 15
}
public enum PhoneEditPolicy: String, Codable, CaseIterable, Sendable { case ignore, bringBack }
public enum FinishedTaskRetention: Int, Codable, CaseIterable, Sendable {
    case never = 0, thirtyDays = 30, ninetyDays = 90
}

/// Recorder-compatible storage: control=1, option=2, shift=4, command=8.
/// Presentation and hot-key registration belong to the app, not the planner.
public struct OpenShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: Int
    public init(keyCode: UInt32 = 45, modifiers: Int = 2) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }
}

/// One typed update per stored preference. Apply through `updatePrefs` to retain
/// validation, persistence, day-policy changes and the existing Undo behavior.
public enum PreferenceUpdate: Equatable, Sendable {
    case resetHour(Int)
    case carryMode(CarryMode)
    case defaultFocusMinutes(Int)
    case focusCompletionSound(Bool)
    case notchTimerPlacement(NotchTimerPlacement)
    case workspaceTimerStyle(WorkspaceTimerStyle)
    case notchOpenTrigger(NotchOpenTrigger)
    case notchClickToOpen(Bool)
    case notchTaskCount(Bool)
    case notchOnMonitors(Bool)
    case showOnDisplay(String?)
    case remindersSync(Bool)
    case ringOnPhone(Bool)
    case sortWithAI(Bool)
    case includeWeekendsInStreak(Bool)
    case catchScreenshots(Bool)
    case catchCopies(Bool)
    case workspaceCardOrder([String])
    case hiddenWorkspaceCards([String])
    case hiddenCalendarIDs([String])
    case welcomeCompleted(Bool)
    case openShortcut(OpenShortcut)
    case launchAtLogin(Bool)
    case blockHeadsUp(HeadsUpInterval)
    case blockEndAction(BlockEndAction)
    case notchProgressLine(Bool)
    case notchTimePill(Bool)
    case notchNextBlock(Bool)
    case notchReminderDot(Bool)
    case menuBarDisplay(MenuBarDisplay)
    case hideCountsAndTimes(Bool)
    case showCalendarMeetings(Bool)
    case meetingHeadsUp(HeadsUpInterval)
    case notifyWhenClosed(Bool)
    case persistentReminders(Bool)
    case snoozeMinutes(SnoozeDuration)
    case phoneEdits(PhoneEditPolicy)
    case agentsCanEditTasks(Bool)
    case agentsCanControlTime(Bool)
    case agentsCanReadParkingLot(Bool)
    case showAgentAttribution(Bool)
    case confirmAgentDeletes(Bool)
    case finishedTaskRetention(FinishedTaskRetention)

    /// Additive preference inverses keep unrelated later edits intact.
    static func undoChanges(before: Preferences, after: Preferences) -> [(inout Planner) -> Void] {
        var changes: [(inout Planner) -> Void] = []
        func field<Value: Equatable>(_ key: WritableKeyPath<Preferences, Value>) {
            let old = before[keyPath: key], new = after[keyPath: key]
            guard old != new else { return }
            changes.append { planner in
                if planner.preferences[keyPath: key] == new { planner.preferences[keyPath: key] = old }
            }
        }
        field(\.notchClickToOpen)
        field(\.notchTaskCount)
        field(\.openShortcut)
        field(\.launchAtLogin)
        field(\.blockHeadsUp)
        field(\.blockEndAction)
        field(\.notchProgressLine)
        field(\.notchTimePill)
        field(\.notchNextBlock)
        field(\.notchReminderDot)
        field(\.menuBarDisplay)
        field(\.hideCountsAndTimes)
        field(\.showCalendarMeetings)
        field(\.meetingHeadsUp)
        field(\.notifyWhenClosed)
        field(\.persistentReminders)
        field(\.snoozeMinutes)
        field(\.phoneEdits)
        field(\.agentsCanEditTasks)
        field(\.agentsCanControlTime)
        field(\.agentsCanReadParkingLot)
        field(\.showAgentAttribution)
        field(\.confirmAgentDeletes)
        field(\.finishedTaskRetention)
        return changes
    }

    public func apply(to value: inout Preferences) {
        switch self {
        case .resetHour(let choice): value.resetHour = choice
        case .carryMode(let choice): value.carryMode = choice
        case .defaultFocusMinutes(let choice): value.defaultFocusMinutes = choice
        case .focusCompletionSound(let choice): value.focusCompletionSound = choice
        case .notchTimerPlacement(let choice): value.notchTimerPlacement = choice
        case .workspaceTimerStyle(let choice): value.workspaceTimerStyle = choice
        case .notchOpenTrigger(let choice): value.notchOpenTrigger = choice
        case .notchClickToOpen(let choice): value.notchClickToOpen = choice
        case .notchTaskCount(let choice): value.notchTaskCount = choice
        case .notchOnMonitors(let choice): value.notchOnMonitors = choice
        case .showOnDisplay(let choice): value.showOnDisplay = choice
        case .remindersSync(let choice): value.remindersSync = choice
        case .ringOnPhone(let choice): value.ringOnPhone = choice
        case .sortWithAI(let choice): value.sortWithAI = choice
        case .includeWeekendsInStreak(let choice): value.includeWeekendsInStreak = choice
        case .catchScreenshots(let choice): value.catchScreenshots = choice
        case .catchCopies(let choice): value.catchCopies = choice
        case .workspaceCardOrder(let choice): value.workspaceCardOrder = choice
        case .hiddenWorkspaceCards(let choice): value.hiddenWorkspaceCards = choice
        case .hiddenCalendarIDs(let choice): value.hiddenCalendarIDs = choice
        case .welcomeCompleted(let choice): value.welcomeCompleted = choice
        case .openShortcut(let choice): value.openShortcut = choice
        case .launchAtLogin(let choice): value.launchAtLogin = choice
        case .blockHeadsUp(let choice): value.blockHeadsUp = choice
        case .blockEndAction(let choice): value.blockEndAction = choice
        case .notchProgressLine(let choice): value.notchProgressLine = choice
        case .notchTimePill(let choice): value.notchTimePill = choice
        case .notchNextBlock(let choice): value.notchNextBlock = choice
        case .notchReminderDot(let choice): value.notchReminderDot = choice
        case .menuBarDisplay(let choice): value.menuBarDisplay = choice
        case .hideCountsAndTimes(let choice): value.hideCountsAndTimes = choice
        case .showCalendarMeetings(let choice): value.showCalendarMeetings = choice
        case .meetingHeadsUp(let choice): value.meetingHeadsUp = choice
        case .notifyWhenClosed(let choice): value.notifyWhenClosed = choice
        case .persistentReminders(let choice): value.persistentReminders = choice
        case .snoozeMinutes(let choice): value.snoozeMinutes = choice
        case .phoneEdits(let choice): value.phoneEdits = choice
        case .agentsCanEditTasks(let choice): value.agentsCanEditTasks = choice
        case .agentsCanControlTime(let choice): value.agentsCanControlTime = choice
        case .agentsCanReadParkingLot(let choice): value.agentsCanReadParkingLot = choice
        case .showAgentAttribution(let choice): value.showAgentAttribution = choice
        case .confirmAgentDeletes(let choice): value.confirmAgentDeletes = choice
        case .finishedTaskRetention(let choice): value.finishedTaskRetention = choice
        }
    }
}

extension PlannerCommands {
    public func updatePreference(_ update: PreferenceUpdate) throws {
        try updatePrefs { update.apply(to: &$0) }
    }
}

extension PlannerCommandPipeline {
    @discardableResult
    public func updatePreference(_ update: PreferenceUpdate, origin: PlannerCommandOrigin) throws
        -> PlannerCommandResult<Void>
    {
        try perform(origin: origin) { try $0.updatePreference(update) }
    }
}

struct SharedPlannerPreferences: Codable {
    var resetHour: Int
    var carryMode: CarryMode
    var defaultFocusMinutes: Int
    var includeWeekendsInStreak: Bool
    init(_ value: Preferences) {
        resetHour = value.resetHour; carryMode = value.carryMode
        defaultFocusMinutes = value.defaultFocusMinutes
        includeWeekendsInStreak = value.includeWeekendsInStreak
    }
}
