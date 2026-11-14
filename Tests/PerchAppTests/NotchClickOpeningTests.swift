import AppKit
import PlannerCore
import XCTest
@testable import PerchApp

@MainActor
private final class ClosedActivationReceiver: NSView {
    var received: (@MainActor (NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { received?(event) }
    override func mouseUp(with event: NSEvent) { received?(event) }
    override func keyDown(with event: NSEvent) { received?(event) }
    override func keyUp(with event: NSEvent) { received?(event) }
}

@MainActor
private final class ClosedActivationNotifications {
    var destinations: [Bool] = []
}

final class NotchClickOpeningTests: XCTestCase {
    @MainActor
    func testClosedActivationUsesIndependentClickChoiceWithNativeEvents() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        let receiver = ClosedActivationReceiver(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(
            contentRect: receiver.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = receiver
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(receiver))

        let screen = NotchScreenState(
            id: 73,
            geometry: NotchGeometry(
                screen: .init(
                    frame: CGRect(x: 0, y: 0, width: 960, height: 600),
                    visibleFrame: CGRect(x: 0, y: 0, width: 960, height: 566))))
        let notifications = ClosedActivationNotifications()
        let observer = NotificationCenter.default.addObserver(
            forName: .perchOpenWorkspace, object: nil, queue: nil
        ) { note in
            let isToday = (note.object as? NotchPage) == .home
            MainActor.assumeIsolated { notifications.destinations.append(isToday) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for trigger in NotchOpenTrigger.allCases {
            for clickEnabled in [false, true] {
                store.updatePrefs {
                    $0.notchOpenTrigger = trigger
                    $0.notchClickToOpen = clickEnabled
                }
                XCTAssertNil(store.lastError)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .keyDown, .keyUp] {
                    for clickCount in [1, 2] {
                        let pointer = type == .leftMouseDown || type == .leftMouseUp
                        let expected = !pointer || clickEnabled || (trigger == .doubleClick && clickCount >= 2)
                        let context = "\(trigger), click \(clickEnabled), \(type), count \(clickCount)"
                        let model = NotchModel()
                        let before = notifications.destinations.count
                        var delivered = false
                        receiver.received = { event in
                            delivered = true
                            XCTAssertTrue(
                                NSApp.currentEvent === event, "Receiver must observe the queued event: \(context)")
                            XCTAssertEqual(NSApp.currentEvent?.type, event.type, context)
                            if pointer { XCTAssertEqual(NSApp.currentEvent?.clickCount, clickCount, context) }
                            model.activateClosed(in: store, on: screen)
                        }
                        let event: NSEvent
                        if pointer {
                            event = try XCTUnwrap(
                                NSEvent.mouseEvent(
                                    with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 1, clickCount: clickCount, pressure: 1))
                        } else {
                            event = try XCTUnwrap(
                                NSEvent.keyEvent(
                                    with: type, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
                        }
                        try Self.dispatchQueuedEvent(event)
                        XCTAssertTrue(delivered, "Native event did not reach the receiver: \(context)")
                        XCTAssertEqual(notifications.destinations.count - before, expected ? 1 : 0, context)
                        XCTAssertEqual(model.screenID, expected ? screen.id : 0, context)
                        XCTAssertEqual(model.geometry, expected ? screen.geometry : nil, context)
                        if expected { XCTAssertEqual(notifications.destinations.last, true, context) }
                    }
                }
            }
        }
        receiver.received = nil
    }

    @MainActor
    func testSettingsOpeningBindingMigratesReloadsAndControlsPointerActivation() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = ClosedActivationReceiver(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: receiver.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = receiver
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(receiver))
        let screen = NotchScreenState(
            id: 73,
            geometry: NotchGeometry(
                screen: .init(
                    frame: CGRect(x: 0, y: 0, width: 960, height: 600),
                    visibleFrame: CGRect(x: 0, y: 0, width: 960, height: 566))))
        let notifications = ClosedActivationNotifications()
        let observer = NotificationCenter.default.addObserver(
            forName: .perchOpenWorkspace, object: nil, queue: nil
        ) { note in
            let isToday = (note.object as? NotchPage) == .home
            MainActor.assumeIsolated { notifications.destinations.append(isToday) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        @MainActor func verifyActivation(_ store: PlannerStore, single: Bool, double: Bool, context: String) throws {
            let cases: [(NSEvent.EventType, Int, Bool)] = [
                (.leftMouseDown, 1, single), (.leftMouseUp, 1, single),
                (.leftMouseDown, 2, double), (.leftMouseUp, 2, double), (.keyDown, 0, true),
            ]
            for (type, count, expected) in cases {
                let model = NotchModel()
                let before = notifications.destinations.count
                var delivered = false
                receiver.received = { event in
                    delivered = true
                    XCTAssertTrue(NSApp.currentEvent === event, context)
                    model.activateClosed(in: store, on: screen)
                }
                let event: NSEvent
                if type == .keyDown {
                    event = try XCTUnwrap(
                        NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                            keyCode: 49))
                } else {
                    event = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: count, pressure: 1))
                }
                try Self.dispatchQueuedEvent(event)
                XCTAssertTrue(delivered, context)
                XCTAssertEqual(notifications.destinations.count - before, expected ? 1 : 0, context)
                XCTAssertEqual(model.screenID, expected ? screen.id : 0, context)
                XCTAssertEqual(model.geometry, expected ? screen.geometry : nil, context)
                if expected { XCTAssertEqual(notifications.destinations.last, true, context) }
            }
        }

        for initial in [NotchOpenTrigger.nothing, .hover] {
            let url = root.appendingPathComponent("\(initial.rawValue).json")
            let legacy = try JSONSerialization.data(withJSONObject: [
                "version": 1, "preferences": ["notchOpenTrigger": initial.rawValue],
            ])
            try legacy.write(to: url)
            var adapter = MemoryPlannerPreferences()
            var store = PlannerStore(file: PlannerFile(url: url, preferences: adapter), watching: false)
            XCTAssertNil(store.lastError)
            XCTAssertFalse(store.prefs.notchClickToOpen)
            try store.file.save(store.file.load())
            @MainActor func reload() throws -> PlannerStore {
                let bytes = try JSONEncoder().encode(XCTUnwrap(adapter.load()))
                adapter = MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: bytes))
                let reloaded = PlannerStore(file: PlannerFile(url: url, preferences: adapter), watching: false)
                XCTAssertNil(reloaded.lastError)
                return reloaded
            }
            store = try reload()
            XCTAssertEqual(store.prefs.notchOpenTrigger, initial)
            XCTAssertFalse(store.prefs.notchClickToOpen)
            try verifyActivation(store, single: false, double: false, context: "Migrated \(initial)")

            for (choice, click, single, double) in [
                (NotchOpenTrigger.click, true, true, true), (.hover, true, true, true),
                (.doubleClick, false, false, true), (.hover, false, false, false), (.click, true, true, true),
            ] {
                let binding = SettingsView.openingPreference(store: store)
                XCTAssertEqual(binding.wrappedValue, store.prefs.notchOpenTrigger)
                binding.wrappedValue = choice
                XCTAssertNil(store.lastError)
                XCTAssertEqual(binding.wrappedValue, choice)
                store = try reload()
                XCTAssertEqual(store.prefs.notchOpenTrigger, choice)
                XCTAssertEqual(store.prefs.notchClickToOpen, click)
                try verifyActivation(store, single: single, double: double, context: "\(initial) -> \(choice)")
            }
        }
        receiver.received = nil
    }

    /// AppKit copies posted events. Compare their payload, then require the
    /// production action to read the exact event dequeued by the application.
    @MainActor private static func dispatchQueuedEvent(_ event: NSEvent) throws {
        NSApp.postEvent(event, atStart: true)
        let mask = NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)
        let dequeued = try XCTUnwrap(
            NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true))
        XCTAssertEqual(dequeued.type, event.type)
        XCTAssertEqual(dequeued.timestamp, event.timestamp)
        XCTAssertEqual(dequeued.windowNumber, event.windowNumber)
        XCTAssertEqual(dequeued.locationInWindow, event.locationInWindow)
        XCTAssertEqual(dequeued.modifierFlags, event.modifierFlags)
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            XCTAssertEqual(dequeued.clickCount, event.clickCount)
        } else {
            XCTAssertEqual(dequeued.characters, event.characters)
            XCTAssertEqual(dequeued.keyCode, event.keyCode)
        }
        XCTAssertTrue(NSApp.currentEvent === dequeued, "Dequeue must establish the event the production action reads")
        NSApp.sendEvent(dequeued)
    }
}
