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
                        NSApp.sendEvent(event)
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
}
