import Foundation
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class SettingsNotchPaneTests: XCTestCase {
    @MainActor
    func testProgressLineControlWritesAndReloads() async throws {
        try check(\.progressLine, preference: \.notchProgressLine, values: [false, true])
    }

    @MainActor
    func testTimePillControlWritesAndReloads() async throws {
        try check(\.timePill, preference: \.notchTimePill, values: [true, false])
    }

    @MainActor
    func testTaskPillControlWritesAndReloads() async throws {
        try check(\.taskPill, preference: \.notchTaskCount, values: [true, false])
    }

    @MainActor
    func testPillSideControlWritesAndReloads() async throws {
        try check(\.pillSide, preference: \.notchTimerPlacement, values: [.left, .split, .right])
    }

    @MainActor
    func testNextBlockControlWritesAndReloads() async throws {
        try check(\.nextBlock, preference: \.notchNextBlock, values: [true, false])
    }

    @MainActor
    func testReminderDotControlWritesAndReloads() async throws {
        try check(\.reminderDot, preference: \.notchReminderDot, values: [false, true])
    }

    @MainActor
    func testMenuBarControlWritesAndReloads() async throws {
        try check(\.menuBar, preference: \.menuBarDisplay, values: [.timeLeft, .tasksLeft, .hidden, .icon])
    }

    @MainActor
    func testManualPrivacyControlWritesAndReloads() async throws {
        try check(\.privacy, preference: \.hideCountsAndTimes, values: [false, true])
    }

    @MainActor
    func testFreshControlsMatchDefaults() async throws {
        let adapter = MemoryPlannerPreferences()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter), watching: false)
        let preferences = SettingsNotchPreferences(store: store)
        XCTAssertTrue(preferences.progressLine.wrappedValue)
        XCTAssertFalse(preferences.timePill.wrappedValue)
        XCTAssertFalse(preferences.taskPill.wrappedValue)
        XCTAssertEqual(preferences.pillSide.wrappedValue, .right)
        XCTAssertFalse(preferences.nextBlock.wrappedValue)
        XCTAssertTrue(preferences.reminderDot.wrappedValue)
        XCTAssertEqual(preferences.menuBar.wrappedValue, .icon)
        XCTAssertTrue(preferences.privacy.wrappedValue)
        XCTAssertEqual(preferences.sideItems.map(\.value), [.left, .right, .split])
    }

    @MainActor
    func testConfiguredPreviewUsesTheSameStoredBindings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let store = PlannerStore(file: storage, watching: false)
        SettingsNotchPreview.configure(store: store)
        XCTAssertFalse(store.prefs.notchProgressLine)
        XCTAssertTrue(store.prefs.notchTimePill)
        XCTAssertTrue(store.prefs.notchTaskCount)
        XCTAssertEqual(store.prefs.notchTimerPlacement, .split)
        XCTAssertTrue(store.prefs.notchNextBlock)
        XCTAssertFalse(store.prefs.notchReminderDot)
        XCTAssertEqual(store.prefs.menuBarDisplay, .timeLeft)
        XCTAssertFalse(store.prefs.hideCountsAndTimes)
        XCTAssertEqual(try storage.load().preferences, store.prefs)
    }

    @MainActor
    func testLegacyHiddenSideRemainsSelectableWithoutWritingOnRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = Preferences()
        original.notchTimerPlacement = .hidden
        let adapter = MemoryPlannerPreferences(DevicePreferences(original))
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter), watching: false)
        let preferences = SettingsNotchPreferences(store: store)
        XCTAssertEqual(preferences.pillSide.wrappedValue, .hidden)
        XCTAssertEqual(preferences.sideItems.map(\.value), [.left, .right, .split, .hidden])
        XCTAssertEqual(adapter.load(), DevicePreferences(original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.url.path))
        preferences.pillSide.wrappedValue = .right
        XCTAssertEqual(try store.file.load().preferences.notchTimerPlacement, .right)
        XCTAssertEqual(preferences.sideItems.map(\.value), [.left, .right, .split])
    }

    @MainActor
    func testFailedPreferenceWriteKeepsControlStateAndReportsError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: UnwritableNotchPreferences()),
            watching: false)
        let preferences = SettingsNotchPreferences(store: store)
        preferences.timePill.wrappedValue = true
        XCTAssertFalse(preferences.timePill.wrappedValue)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    private func check<Value: Equatable>(
        _ control: KeyPath<SettingsNotchPreferences, Binding<Value>>, preference: KeyPath<Preferences, Value>,
        values: [Value], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MemoryPlannerPreferences()
        let storage = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter)
        let store = PlannerStore(file: storage, watching: false)
        let controls = SettingsNotchPreferences(store: store)
        let binding = controls[keyPath: control]
        for value in values {
            binding.wrappedValue = value
            XCTAssertNil(store.lastError, file: file, line: line)
            // The same binding reads the newly published value without closing Settings.
            XCTAssertEqual(binding.wrappedValue, value, file: file, line: line)
            XCTAssertEqual(store.prefs[keyPath: preference], value, file: file, line: line)
            XCTAssertEqual(try storage.load().preferences[keyPath: preference], value, file: file, line: line)
            let bytes = try JSONEncoder().encode(XCTUnwrap(adapter.load()))
            let restarted = PlannerStore(
                file: PlannerFile(
                    url: storage.url,
                    preferences: MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: bytes))
                ),
                watching: false)
            XCTAssertEqual(
                SettingsNotchPreferences(store: restarted)[keyPath: control].wrappedValue, value, file: file, line: line
            )
        }
    }
}

private final class UnwritableNotchPreferences: PlannerPreferencesAdapter {
    func load() throws -> DevicePreferences? { nil }
    func save(_ preferences: DevicePreferences?) throws { throw CocoaError(.fileWriteNoPermission) }
}
