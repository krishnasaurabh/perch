import Foundation

/// Device state is deliberately excluded from portable planner documents.
public protocol PlannerPreferencesAdapter: AnyObject {
    func load() throws -> DevicePreferences?
    func save(_ preferences: DevicePreferences?) throws
}

/// A single atomic value avoids partially migrated preference keys.
public final class UserDefaultsPlannerPreferences: PlannerPreferencesAdapter {
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
public final class MemoryPlannerPreferences: PlannerPreferencesAdapter {
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

    public init(from decoder: Decoder) throws {
        self.init(try Preferences(from: decoder))
    }

    public init(_ value: Preferences) {
        focusCompletionSound = value.focusCompletionSound
        notchTimerPlacement = value.notchTimerPlacement
        workspaceTimerStyle = value.workspaceTimerStyle
        notchOpenTrigger = value.notchOpenTrigger
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
    }

    public func apply(to value: inout Preferences) {
        value.focusCompletionSound = focusCompletionSound
        value.notchTimerPlacement = notchTimerPlacement
        value.workspaceTimerStyle = workspaceTimerStyle
        value.notchOpenTrigger = notchOpenTrigger
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
