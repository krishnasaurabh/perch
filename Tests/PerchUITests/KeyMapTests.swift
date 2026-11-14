import XCTest

@testable import PerchUI

final class KeyMapTests: XCTestCase {
    func testSheetCopyAndOrdering() {
        XCTAssertEqual(KeyMap.columns, [[.anywhere, .writing, .time], [.checklist, .week]])
        XCTAssertEqual(KeyMap.Group.allCases.map(\.title), ["Anywhere", "Writing", "Time", "The checklist", "Week"])
        XCTAssertEqual(KeyMap.Group.allCases.map(\.surface), [.paper, .butter, .blush, .paper, .mint])
        XCTAssertEqual(
            KeyMap.entries.map(\.label),
            [
                "Open Perch, ready to type", "Close it", "Undo the last change",
                "Add the task", "Make it a step", "Move it back out",
                "Start time on the task", "Pause or continue", "Add five minutes",
                "Move between tasks", "Check it off", "Open the task", "Show or hide its steps",
                "Move it up or down", "Delete, with Undo", "Park it for later",
                "Go to Week", "Move between days", "Push a task a day",
            ])
        XCTAssertEqual(
            KeyMap.entries.map(\.keyCaps),
            [
                ["⌥", "N"], ["Esc"], ["⌘", "Z"], ["↩"], ["Tab"], ["⇧", "Tab"],
                ["⌘", "↩"], ["⌘", "P"], ["⌘", "+"], ["↑", "↓"], ["Space"], ["↩"],
                ["→", "←"], ["⌥", "↑"], ["⌫"], ["⌘", "K"], ["⌘", "2"], ["←", "→"], ["⌥", "→"],
            ])
        XCTAssertEqual(Set(KeyMap.entries.map(\.id)).count, KeyMap.entries.count)
        XCTAssertEqual(KeyMap.help.keyCaps, ["?"])
    }

    func testEveryEntryWithAHandlerHasAnExecutableBinding() {
        var handled: [KeyMap.Handler] = []
        let bindings = Dictionary(
            uniqueKeysWithValues: KeyMap.Handler.allCases.map { handler in
                (
                    handler,
                    {
                        handled.append(handler); return true
                    }
                )
            })
        let registry = KeyMap.Bindings(handlers: bindings)
        XCTAssertTrue(registry.unboundEntries.isEmpty)
        for entry in KeyMap.boundEntries {
            for gesture in entry.gestures {
                let previousCount = handled.count
                XCTAssertTrue(registry.handle(gesture.example, context: .application), entry.id.rawValue)
                XCTAssertEqual(handled.count, previousCount + 1)
                XCTAssertEqual(handled.last, entry.handler)
            }
        }
    }

    func testMissingOrDecliningHandlerDoesNotConsumeTheEvent() {
        let empty = KeyMap.Bindings(handlers: [:])
        XCTAssertEqual(Set(empty.unboundEntries.map(\.id)), Set(KeyMap.boundEntries.map(\.id)))
        XCTAssertFalse(empty.handle(KeyMap.help.gestures[0].example, context: .application))
        let declined = KeyMap.Bindings(handlers: [.showKeys: { false }])
        XCTAssertFalse(declined.handle(KeyMap.help.gestures[0].example, context: .application))
    }

    func testHelpRecognizesTypedQuestionMarkWithoutAssumingKeyboardLayout() {
        let bindings = KeyMap.Bindings(handlers: [.showKeys: { true }])
        for input in [
            KeyMap.Input(keyCode: 44, characters: "?", modifiers: .shift),
            KeyMap.Input(keyCode: 27, characters: "?", modifiers: []),
        ] {
            XCTAssertTrue(bindings.handle(input, context: .application))
        }
        XCTAssertFalse(bindings.handle(.init(keyCode: 44, characters: "/", modifiers: []), context: .application))
        XCTAssertFalse(
            bindings.handle(.init(keyCode: 44, characters: "?", modifiers: [.command, .shift]), context: .application))
    }

    func testEditingModalAndRepeatEventsAreLeftToTheirOwners() {
        var count = 0
        let handlers = Dictionary(
            uniqueKeysWithValues: KeyMap.Handler.allCases.map {
                (
                    $0,
                    {
                        count += 1; return true
                    }
                )
            })
        let bindings = KeyMap.Bindings(handlers: handlers)
        for entry in KeyMap.boundEntries {
            let input = entry.gestures[0].example
            XCTAssertFalse(bindings.handle(input, context: .modal), entry.id.rawValue)
            var repeated = input
            repeated.isRepeat = true
            XCTAssertFalse(bindings.handle(repeated, context: .application), entry.id.rawValue)
        }
        for id in [KeyMap.Action.showKeys, .close, .undo] {
            let entry = KeyMap.allEntries.first { $0.id == id }!
            XCTAssertFalse(bindings.handle(entry.gestures[0].example, context: .textEditing))
        }
        XCTAssertEqual(count, 0)
    }

    func testCommandBindingsRequireExactModifiersAndAcceptShiftedPlus() {
        var count = 0
        let bindings = KeyMap.Bindings(handlers: [
            .addFiveMinutes: {
                count += 1; return true
            }
        ])
        XCTAssertTrue(
            bindings.handle(.init(keyCode: 24, characters: "+", modifiers: [.command, .shift]), context: .application))
        XCTAssertTrue(bindings.handle(.init(keyCode: 69, characters: "+", modifiers: .command), context: .application))
        XCTAssertFalse(bindings.handle(.init(keyCode: 24, characters: "=", modifiers: .command), context: .application))
        XCTAssertFalse(
            bindings.handle(.init(keyCode: 24, characters: "+", modifiers: [.command, .option]), context: .application))
        XCTAssertEqual(count, 2)
    }

    func testScreenOwnedEntriesRemainExplicitlyDeferred() {
        XCTAssertEqual(
            Set(KeyMap.pendingEntries.map(\.id)),
            [
                .openPerch, .addTask, .indentStep, .outdentStep, .startTaskTime,
                .moveTaskSelection, .checkTask, .openTask, .showSteps, .reorderTask,
                .deleteTask, .parkTask, .moveDaySelection, .pushTaskDay,
            ])
        let bindings = KeyMap.Bindings(
            handlers: Dictionary(uniqueKeysWithValues: KeyMap.Handler.allCases.map { ($0, { true }) }))
        for entry in KeyMap.pendingEntries {
            for gesture in entry.gestures {
                XCTAssertFalse(bindings.handle(gesture.example, context: .application), entry.id.rawValue)
            }
        }
    }

    func testKeyMapInkContrastAndLayout() {
        for appearance in DesignTokens.Appearance.allCases {
            for group in KeyMap.Group.allCases {
                XCTAssertGreaterThanOrEqual(contrast(.ink, group.surface.fill, appearance), 4.5)
            }
            XCTAssertGreaterThanOrEqual(contrast(.ink, .field, appearance), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(.ink2, .sheet, appearance), 4.5)
        }
        XCTAssertEqual(KeyMap.Layout.width, 820)
        XCTAssertEqual(KeyMap.Layout.height, 568)
        XCTAssertEqual(KeyMap.Layout.columnGap, 12)
        XCTAssertEqual(KeyMap.Layout.rowHeight, 32)
        XCTAssertEqual(KeyMap.Layout.keyHeight, 26)
    }

    private func contrast(
        _ ink: DesignTokens.ColorToken, _ fill: DesignTokens.ColorToken, _ appearance: DesignTokens.Appearance
    ) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((hex >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(ink.hex(in: appearance)), b = luminance(fill.hex(in: appearance))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
