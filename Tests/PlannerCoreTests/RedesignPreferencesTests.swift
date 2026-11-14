import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class RedesignPreferencesTests: XCTestCase {
    private let defaultJSON = #"""
        {"resetHour":4,"carryMode":"auto","defaultFocusMinutes":45,"focusCompletionSound":false,"notchTimerPlacement":"right","workspaceTimerStyle":"digital","notchOpenTrigger":"hover","notchClickToOpen":true,"notchTaskCount":false,"notchOnMonitors":false,"remindersSync":false,"ringOnPhone":false,"sortWithAI":false,"includeWeekendsInStreak":true,"catchScreenshots":false,"catchCopies":false,"workspaceCardOrder":["focus","events","notepad"],"hiddenWorkspaceCards":["notepad"],"hiddenCalendarIDs":[],"welcomeCompleted":false,"openShortcut":{"keyCode":45,"modifiers":2},"launchAtLogin":true,"blockHeadsUp":5,"blockEndAction":"ask","notchProgressLine":true,"notchTimePill":false,"notchNextBlock":false,"notchReminderDot":true,"menuBarDisplay":"icon","hideCountsAndTimes":true,"showCalendarMeetings":true,"meetingHeadsUp":5,"notifyWhenClosed":true,"persistentReminders":true,"snoozeMinutes":10,"phoneEdits":"ignore","agentsCanEditTasks":true,"agentsCanControlTime":false,"agentsCanReadParkingLot":false,"showAgentAttribution":true,"confirmAgentDeletes":true,"finishedTaskRetention":0}
        """#
    private let savedJSON = #"""
        {"resetHour":0,"carryMode":"ask","defaultFocusMinutes":50,"focusCompletionSound":true,"notchTimerPlacement":"left","workspaceTimerStyle":"dotMatrix","notchOpenTrigger":"doubleClick","notchClickToOpen":false,"notchTaskCount":true,"notchOnMonitors":true,"showOnDisplay":"Synthetic display","remindersSync":true,"ringOnPhone":true,"sortWithAI":true,"includeWeekendsInStreak":false,"catchScreenshots":true,"catchCopies":true,"workspaceCardOrder":["notepad","focus"],"hiddenWorkspaceCards":["events"],"hiddenCalendarIDs":["calendar-a"],"welcomeCompleted":true,"openShortcut":{"keyCode":49,"modifiers":9},"launchAtLogin":false,"blockHeadsUp":10,"blockEndAction":"takeBreak","notchProgressLine":false,"notchTimePill":true,"notchNextBlock":true,"notchReminderDot":false,"menuBarDisplay":"timeLeft","hideCountsAndTimes":false,"showCalendarMeetings":false,"meetingHeadsUp":0,"notifyWhenClosed":false,"persistentReminders":false,"snoozeMinutes":15,"phoneEdits":"bringBack","agentsCanEditTasks":false,"agentsCanControlTime":true,"agentsCanReadParkingLot":true,"showAgentAttribution":false,"confirmAgentDeletes":false,"finishedTaskRetention":90}
        """#

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func encoded(_ value: Preferences) throws -> NSDictionary {
        try object(JSONEncoder().encode(value)) as NSDictionary
    }
    private func legacy(_ preferences: [String: Any]) throws -> Planner {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [], "preferences": preferences])
        return try PlannerFile.decoder.decode(Planner.self, from: data)
    }

    private func diskPreferences(_ preferences: [String: Any], version: Int) throws -> Preferences {
        var document = try object(PlannerFile.encoder.encode(PlannerDiskDocument(Planner())))
        document["version"] = version
        document["preferences"] = preferences
        return try PlannerFile.decoder.decode(
            PlannerDiskDocument.self, from: JSONSerialization.data(withJSONObject: document)
        ).planner.preferences
    }

    func testFreshAndAbsentValuesMatchEveryDefault() throws {
        let expected = try object(Data(defaultJSON.utf8)) as NSDictionary
        XCTAssertEqual(try encoded(Preferences()), expected)
        XCTAssertEqual(try encoded(legacy([:]).preferences), expected)
        XCTAssertEqual(
            try encoded(PlannerFile.decoder.decode(Planner.self, from: Data("{}".utf8)).preferences), expected)
    }

    func testEachSavedValueSurvivesAndOnlyMissingKeysDefault() throws {
        let saved = try object(Data(savedJSON.utf8))
        let defaults = try object(Data(defaultJSON.utf8))
        XCTAssertEqual(try encoded(legacy(saved).preferences), saved as NSDictionary)
        for key in saved.keys.sorted() {
            var partial = saved
            partial.removeValue(forKey: key)
            var expected = partial
            expected[key] = defaults[key]
            XCTAssertEqual(try encoded(legacy(partial).preferences), expected as NSDictionary, key)
            for version in [1, 2] {
                XCTAssertEqual(try encoded(diskPreferences(partial, version: version)), expected as NSDictionary, key)
            }
            let device = try JSONDecoder().decode(
                DevicePreferences.self, from: JSONSerialization.data(withJSONObject: partial))
            XCTAssertEqual(device, DevicePreferences(try legacy(partial).preferences), key)
            // A single explicit value must not be mistaken for a missing value.
            var single = defaults
            single[key] = saved[key]
            XCTAssertEqual(try encoded(legacy([key: saved[key]!]).preferences), single as NSDictionary, key)
        }
    }

    func testClickOpeningDefaultsOnWhenBothOpeningKeysAreAbsent() throws {
        XCTAssertTrue(Preferences().notchClickToOpen)
        XCTAssertTrue(try legacy([:]).preferences.notchClickToOpen)
        XCTAssertTrue(try JSONDecoder().decode(DevicePreferences.self, from: Data("{}".utf8)).notchClickToOpen)
    }

    func testClickOpeningMigratesOnlyLegacyClickAndDoubleClickToOn() throws {
        for trigger in NotchOpenTrigger.allCases {
            let saved = ["notchOpenTrigger": trigger.rawValue]
            let expected = trigger == .click || trigger == .doubleClick
            XCTAssertEqual(try legacy(saved).preferences.notchClickToOpen, expected, trigger.rawValue)
            for version in [1, 2] {
                XCTAssertEqual(try diskPreferences(saved, version: version).notchClickToOpen, expected)
            }
            let device = try JSONDecoder().decode(
                DevicePreferences.self, from: JSONSerialization.data(withJSONObject: saved))
            XCTAssertEqual(device.notchClickToOpen, expected)
            XCTAssertEqual(device.notchOpenTrigger, trigger)
        }
    }

    func testExplicitClickOpeningRoundTripsIndependentlyOfEveryHoverChoice() throws {
        for trigger in NotchOpenTrigger.allCases {
            for enabled in [true, false] {
                let saved: [String: Any] = ["notchOpenTrigger": trigger.rawValue, "notchClickToOpen": enabled]
                let preferences = try legacy(saved).preferences
                XCTAssertEqual(preferences.notchClickToOpen, enabled)
                XCTAssertEqual(preferences.notchOpenTrigger, trigger)
                let device = try JSONDecoder().decode(
                    DevicePreferences.self, from: JSONEncoder().encode(DevicePreferences(preferences)))
                var restored = Preferences()
                device.apply(to: &restored)
                XCTAssertEqual(restored, preferences)
                XCTAssertEqual(try object(JSONEncoder().encode(device))["notchClickToOpen"] as? Bool, enabled)
            }
        }
    }

    func testCompletionErrorUsesConfiguredDayBoundary() throws {
        let day: DayKey = "2026-11-09"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var planner = Planner()
        let task = PlanTask(title: "Sample task", day: day, done: true)
        planner.tasks = [task]
        var beforeBoundary = PlannerEngine(
            planner: planner, now: { day.date(calendar: calendar) }, calendar: calendar)
        XCTAssertEqual(beforeBoundary.today, day.adding(days: -1, calendar: calendar))
        XCTAssertThrowsError(try beforeBoundary.complete(task.id)) { error in
            XCTAssertEqual(
                (error as? PlannerError)?.message, "Reschedule this task for today before completing it.")
        }

        let start = day.start(resetHour: planner.preferences.resetHour, calendar: calendar)
        var atBoundary = PlannerEngine(planner: planner, now: { start }, calendar: calendar)
        XCTAssertEqual(atBoundary.today, day)
        XCTAssertThrowsError(try atBoundary.complete(task.id)) { error in
            XCTAssertEqual((error as? PlannerError)?.message, "Already completed: Sample task.")
            XCTAssertEqual((error as? PlannerError)?.presentationKey, "Already completed: %@.")
            XCTAssertEqual((error as? PlannerError)?.presentationArguments, ["Sample task"])
        }
    }

    func testRolloverKeepsSavedAskPolicyAndUsesAutoOnlyWhenMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for saved in [[:], ["carryMode": "ask"]] {
            let planner = try legacy(saved)
            let file = PlannerFile(
                url: directory.appendingPathComponent("\(planner.preferences.carryMode.rawValue).json"),
                preferences: MemoryPlannerPreferences())
            try file.save(planner)
            var now = Fixture.now
            let pipeline = PlannerCommandPipeline(
                file: file, clock: ClosurePlannerClock { now }, calendar: Fixture.calendar)
            try pipeline.execute(.lifecycle(.launch), origin: .background)
            let added = try pipeline.execute(
                .addTasks(["Synthetic"], day: nil, literal: true, agentID: nil), origin: .user)
            let tasks = added.state.tasks
            now = Fixture.date("2026-11-10 15:00")
            let rolled = try pipeline.execute(.lifecycle(.dayChanged), origin: .background)
            XCTAssertEqual(rolled.state.preferences.carryMode, planner.preferences.carryMode)
            if saved.isEmpty {
                XCTAssertEqual(rolled.state.tasks.count, 2)
                XCTAssertEqual(rolled.state.tasks.first, tasks.first)
                XCTAssertEqual(rolled.state.tasks.last?.carriedTaskID, tasks.first?.id)
                XCTAssertEqual(rolled.state.tasks.last?.day, "2026-11-10")
            } else {
                XCTAssertEqual(rolled.state.tasks, tasks)
            }
            XCTAssertEqual(try file.load(), rolled.state)
        }
    }

    func testMalformedPresentValuesDoNotSilentlyResetPreferences() throws {
        let saved = try object(Data(savedJSON.utf8))
        for key in saved.keys.sorted() where key != "showOnDisplay" {
            XCTAssertThrowsError(try legacy([key: NSNull()]), key)
            XCTAssertThrowsError(try legacy([key: ["bad": "value"]]), key)
        }
        for key in [
            "carryMode", "notchTimerPlacement", "notchOpenTrigger", "blockHeadsUp", "blockEndAction",
            "menuBarDisplay", "meetingHeadsUp", "snoozeMinutes", "phoneEdits", "finishedTaskRetention",
        ] {
            XCTAssertThrowsError(try legacy([key: "future-value"]), key)
        }
    }

    func testEnumRawValuesAreStableAndRoundTrip() throws {
        XCTAssertEqual(CarryMode.allCases.map(\.rawValue), ["ask", "auto", "never"])
        for value in CarryMode.allCases {
            XCTAssertEqual(try JSONDecoder().decode(CarryMode.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(NotchTimerPlacement.allCases.map(\.rawValue), ["right", "left", "hidden", "split"])
        for value in NotchTimerPlacement.allCases {
            XCTAssertEqual(try JSONDecoder().decode(NotchTimerPlacement.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(WorkspaceTimerStyle.allCases.map(\.rawValue), ["dotMatrix", "digital", "minimal"])
        for value in WorkspaceTimerStyle.allCases {
            XCTAssertEqual(try JSONDecoder().decode(WorkspaceTimerStyle.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(
            NotchOpenTrigger.allCases.map(\.rawValue), ["hover", "click", "doubleClick", "nothing", "everything"])
        for value in NotchOpenTrigger.allCases {
            XCTAssertEqual(try JSONDecoder().decode(NotchOpenTrigger.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(HeadsUpInterval.allCases.map(\.rawValue), [0, 5, 10])
        for value in HeadsUpInterval.allCases {
            XCTAssertEqual(try JSONDecoder().decode(HeadsUpInterval.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(BlockEndAction.allCases.map(\.rawValue), ["ask", "takeBreak", "doNothing"])
        for value in BlockEndAction.allCases {
            XCTAssertEqual(try JSONDecoder().decode(BlockEndAction.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(MenuBarDisplay.allCases.map(\.rawValue), ["icon", "timeLeft", "tasksLeft", "hidden"])
        for value in MenuBarDisplay.allCases {
            XCTAssertEqual(try JSONDecoder().decode(MenuBarDisplay.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(SnoozeDuration.allCases.map(\.rawValue), [5, 10, 15])
        for value in SnoozeDuration.allCases {
            XCTAssertEqual(try JSONDecoder().decode(SnoozeDuration.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(PhoneEditPolicy.allCases.map(\.rawValue), ["ignore", "bringBack"])
        for value in PhoneEditPolicy.allCases {
            XCTAssertEqual(try JSONDecoder().decode(PhoneEditPolicy.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(FinishedTaskRetention.allCases.map(\.rawValue), [0, 30, 90])
        for value in FinishedTaskRetention.allCases {
            XCTAssertEqual(
                try JSONDecoder().decode(FinishedTaskRetention.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testNewDevicePreferencesMigratePersistAndStayOutOfExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = MemoryPlannerPreferences()
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"), preferences: adapter)
        let saved = try object(Data(savedJSON.utf8))
        let original = try JSONSerialization.data(withJSONObject: ["version": 1, "preferences": saved])
        try original.write(to: file.url)
        let loaded = try file.load()
        XCTAssertEqual(try encoded(loaded.preferences), saved as NSDictionary)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertNil(adapter.load())
        try file.save(loaded)
        XCTAssertEqual(try file.load(), loaded)
        let persisted = try XCTUnwrap(adapter.load())
        let bytes = try JSONEncoder().encode(persisted)
        let restartedAdapter = MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: bytes))
        let restarted = PlannerFile(url: file.url, preferences: restartedAdapter)
        XCTAssertEqual(try encoded(restarted.load().preferences), saved as NSDictionary)
        let defaultDevice = DevicePreferences(Preferences())
        XCTAssertEqual(try JSONDecoder().decode(DevicePreferences.self, from: Data("{}".utf8)), defaultDevice)
        let all = Set(saved.keys)
        let deviceKeys = Set(try object(bytes).keys)
        let sharedKeys = Set(try object(JSONEncoder().encode(SharedPlannerPreferences(loaded.preferences))).keys)
        XCTAssertEqual(deviceKeys.union(sharedKeys), all)
        XCTAssertTrue(deviceKeys.intersection(sharedKeys).isEmpty)
        let export = directory.appendingPathComponent("export.json")
        try restarted.export(to: export)
        let exported = try object(Data(contentsOf: export))
        XCTAssertEqual(Set(try XCTUnwrap(exported["preferences"] as? [String: Any]).keys), sharedKeys)
        let otherDevice = PlannerFile(url: file.url, preferences: MemoryPlannerPreferences())
        XCTAssertEqual(DevicePreferences(try otherDevice.load().preferences), defaultDevice)
    }

    func testPreferenceUndoRetainsLaterChoicesOnTheSameAndOtherFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { Fixture.now })
        try pipeline.updatePreference(.menuBarDisplay(.timeLeft), origin: .user)
        try pipeline.updatePreference(.menuBarDisplay(.tasksLeft), origin: .background)
        try pipeline.updatePreference(.notchTimePill(true), origin: .background)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().preferences.menuBarDisplay, .tasksLeft)
        XCTAssertTrue(try file.load().preferences.notchTimePill)
        try pipeline.updatePreference(.blockHeadsUp(.off), origin: .user)
        try pipeline.updatePreference(.meetingHeadsUp(.tenMinutes), origin: .background)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().preferences.blockHeadsUp, .fiveMinutes)
        XCTAssertEqual(try file.load().preferences.meetingHeadsUp, .tenMinutes)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().preferences.blockHeadsUp, .off)
        XCTAssertEqual(try file.load().preferences.meetingHeadsUp, .tenMinutes)
    }

    func testEachTypedUpdateUsesTheExistingPersistentCommandPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = MemoryPlannerPreferences()
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"), preferences: adapter)
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        let updates: [(String, PreferenceUpdate)] = [
            ("resetHour", .resetHour(0)),
            ("carryMode", .carryMode(.ask)),
            ("defaultFocusMinutes", .defaultFocusMinutes(50)),
            ("focusCompletionSound", .focusCompletionSound(true)),
            ("notchTimerPlacement", .notchTimerPlacement(.left)),
            ("workspaceTimerStyle", .workspaceTimerStyle(.dotMatrix)),
            ("notchOpenTrigger", .notchOpenTrigger(.doubleClick)),
            ("notchClickToOpen", .notchClickToOpen(false)),
            ("notchTaskCount", .notchTaskCount(true)),
            ("notchOnMonitors", .notchOnMonitors(true)),
            ("showOnDisplay", .showOnDisplay("Synthetic display")),
            ("remindersSync", .remindersSync(true)),
            ("ringOnPhone", .ringOnPhone(true)),
            ("sortWithAI", .sortWithAI(true)),
            ("includeWeekendsInStreak", .includeWeekendsInStreak(false)),
            ("catchScreenshots", .catchScreenshots(true)),
            ("catchCopies", .catchCopies(true)),
            ("workspaceCardOrder", .workspaceCardOrder(["notepad", "focus"])),
            ("hiddenWorkspaceCards", .hiddenWorkspaceCards(["events"])),
            ("hiddenCalendarIDs", .hiddenCalendarIDs(["calendar-a"])),
            ("welcomeCompleted", .welcomeCompleted(true)),
            ("openShortcut", .openShortcut(OpenShortcut(keyCode: 49, modifiers: 9))),
            ("launchAtLogin", .launchAtLogin(false)),
            ("blockHeadsUp", .blockHeadsUp(.tenMinutes)),
            ("blockEndAction", .blockEndAction(.takeBreak)),
            ("notchProgressLine", .notchProgressLine(false)),
            ("notchTimePill", .notchTimePill(true)),
            ("notchNextBlock", .notchNextBlock(true)),
            ("notchReminderDot", .notchReminderDot(false)),
            ("menuBarDisplay", .menuBarDisplay(.timeLeft)),
            ("hideCountsAndTimes", .hideCountsAndTimes(false)),
            ("showCalendarMeetings", .showCalendarMeetings(false)),
            ("meetingHeadsUp", .meetingHeadsUp(.off)),
            ("notifyWhenClosed", .notifyWhenClosed(false)),
            ("persistentReminders", .persistentReminders(false)),
            ("snoozeMinutes", .snoozeMinutes(.fifteenMinutes)),
            ("phoneEdits", .phoneEdits(.bringBack)),
            ("agentsCanEditTasks", .agentsCanEditTasks(false)),
            ("agentsCanControlTime", .agentsCanControlTime(true)),
            ("agentsCanReadParkingLot", .agentsCanReadParkingLot(true)),
            ("showAgentAttribution", .showAgentAttribution(false)),
            ("confirmAgentDeletes", .confirmAgentDeletes(false)),
            ("finishedTaskRetention", .finishedTaskRetention(.ninetyDays)),
        ]
        let saved = try object(Data(savedJSON.utf8))
        for (key, update) in updates {
            let before = try file.load().preferences
            var expectedJSON = try object(JSONEncoder().encode(before))
            expectedJSON[key] = saved[key]
            let expected = try legacy(expectedJSON).preferences
            let result = try pipeline.updatePreference(update, origin: .user)
            XCTAssertEqual(result.state.preferences, expected)
            XCTAssertEqual(try file.load().preferences, expected)
            XCTAssertEqual(try pipeline.undo()?.preferences, before)
            XCTAssertEqual(try pipeline.redo()?.preferences, expected)
        }
        XCTAssertEqual(try encoded(file.load().preferences), try object(Data(savedJSON.utf8)) as NSDictionary)
        XCTAssertThrowsError(try pipeline.inspect { try $0.updatePreference(.notchTimePill(false)) })
        let before = try file.load()
        XCTAssertThrowsError(try pipeline.updatePreference(.defaultFocusMinutes(0), origin: .user))
        XCTAssertEqual(try file.load(), before)
    }
}
