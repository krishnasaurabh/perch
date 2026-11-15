// Replaces App/main.swift only in the temporary CI probe package (scripts/check_capture_contrast.sh).
// Renders the real Today capture field resting (passive reveal) and focused (explicit open), empty and with three
// tasks, plus the Week page, so scripts/measure_capture_contrast.py can measure the rendered prompt (review F02).
import AppKit
import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
#endif
import SwiftUI

// BEGIN WEEK FOOTER MEASUREMENT (copied into the isolated app library)
@MainActor enum WeekFooterMeasurements {
    static var views: [ObjectIdentifier: (String, NSView)] = [:]

    static func save(into directory: URL) throws {
        var rows: [[String: Any]] = []
        for (day, view) in views.values {
            guard let window = view.window, let root = window.contentView,
                let screen = window.screen,
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let rect = root.convert(view.bounds, from: view)
            // The horizontal scroll backing also contains offscreen days. Sample
            // every fully visible footer, never a clipped or detached label.
            guard rect.width > 0, rect.height > 0, root.bounds.contains(rect) else { continue }
            let image = "notch-\(number.uint32Value)-open.png"
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(image).path) else { continue }
            let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
            rows.append([
                "image": image, "day": day,
                "xywh": [rect.minX, top, rect.width, rect.height],
                "canvas": [root.bounds.width, root.bounds.height],
            ])
        }
        guard !rows.isEmpty else {
            throw NSError(
                domain: "CaptureContrast", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not sample Week Add a task footers"])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("week-footers.json"))
    }
}

struct WeekFooterMeasure: NSViewRepresentable {
    let day: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        WeekFooterMeasurements.views[ObjectIdentifier(view)] = (day, view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        WeekFooterMeasurements.views[ObjectIdentifier(view)] = (day, view)
    }
}
// END WEEK FOOTER MEASUREMENT

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

@MainActor
func settle() async {
    try? await Task.sleep(nanoseconds: 900_000_000)
}

@MainActor
func captureEditor() -> NSTextView? {
    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
    return editor
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTURE_CONTRAST_OUTPUT"]!)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            require(delegate.store.planner.tasks.isEmpty, "isolated planner starts empty")
            delegate.store.updatePrefs {
                $0.catchCopies = false; $0.catchScreenshots = false
            }
            // Another app-owned window keeps the keyboard during passive reveals, as in the empty-state probe.
            let other = NSPanel(
                contentRect: NSRect(x: 80, y: 80, width: 180, height: 80),
                styleMask: [.titled], backing: .buffered, defer: false)
            let otherField = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 24))
            other.contentView?.addSubview(otherField)

            // Local async funcs are not inferred main-actor from the enclosing Task closure (Swift 6 CLT).
            @MainActor func passive(_ name: String) async {
                delegate.model.close()
                await settle()
                NSApp.activate(ignoringOtherApps: true)
                other.makeKeyAndOrderFront(nil)
                other.makeFirstResponder(otherField)
                await settle()
                require(other.isKeyWindow, "\(name): fixture window is key before the passive reveal")
                delegate.model.open(page: .home)
                await settle()
                require(delegate.model.captureFocusRequest == nil, "\(name): passive reveal requests no capture focus")
                // The fixture's own text field holds a field editor, so check which window owns the keyboard.
                require(
                    other.isKeyWindow && NSApp.keyWindow === other, "\(name): passive reveal leaves capture unfocused")
                delegate.notch.snapshot(into: output.appendingPathComponent(name))
                other.orderOut(nil)
            }

            @MainActor func explicit(_ name: String) async {
                delegate.model.close()
                await settle()
                NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
                await settle()
                require(delegate.model.captureFocusRequest != nil, "\(name): explicit open requests capture focus")
                require(captureEditor() != nil, "\(name): explicit open focuses capture")
                require(captureEditor()?.string == "", "\(name): capture is empty, so the prompt is visible")
                delegate.notch.snapshot(into: output.appendingPathComponent(name))
            }

            await passive("empty-home-unfocused")
            await explicit("empty-home-focused")

            // Three tasks for today. No clock times: once 2pm/5pm have passed, the parser rolls those to tomorrow.
            delegate.store.apply {
                try $0.addTasks(["Prep slides for the review !high #work", "Call mom", "Buy flowers"], on: nil)
            }
            await settle()
            require(delegate.store.engine.tasks(on: .day(delegate.store.today)).count == 3, "three tasks for today")
            await passive("three-home-unfocused")
            await explicit("three-home-focused")

            // Typing still reaches capture and adds through the parser after the prompt restyle.
            captureEditor()?.insertText(
                "Call the dentist tomorrow at 9am", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            delegate.notch.snapshot(into: output.appendingPathComponent("three-home-typed"))
            if let window = NSApp.keyWindow,
                let enter = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            {
                NSApp.sendEvent(enter)
            }
            await settle()
            let added = delegate.store.planner.tasks.first { $0.title == "Call the dentist" }
            require(added != nil, "Return adds the typed task with the parsed title")
            require(added?.day.map { $0 > delegate.store.today } == true, "parser moves \"tomorrow\" past today")
            require(added?.remindAt != nil, "parser reads the 9am reminder")
            require(captureEditor()?.string == "", "capture clears and stays focused after add")

            // Exercise the adaptive Week host in both appearances, independently of the runner's desktop.
            let previousAppearance = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .darkAqua)
            delegate.model.page = .week
            await settle()
            require(
                NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                "week: dark appearance is active")
            delegate.notch.snapshot(into: output.appendingPathComponent("week"))
            do { try WeekFooterMeasurements.save(into: output.appendingPathComponent("week")) } catch {
                require(false, "could not sample dark Week footers: \(error)")
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            await settle()
            require(
                NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                "week-light: light appearance is active")
            delegate.notch.snapshot(into: output.appendingPathComponent("week-light"))
            do { try WeekFooterMeasurements.save(into: output.appendingPathComponent("week-light")) } catch {
                require(false, "could not sample light Week footers: \(error)")
            }
            NSApp.appearance = previousAppearance
            require(delegate.store.lastError == nil, "no store error")
            for name in [
                "empty-home-unfocused", "empty-home-focused", "three-home-unfocused", "three-home-focused",
                "three-home-typed", "week", "week-light",
            ] {
                let files =
                    (try? FileManager.default.contentsOfDirectory(
                        at: output.appendingPathComponent(name),
                        includingPropertiesForKeys: nil)) ?? []
                require(
                    files.contains { $0.pathExtension == "png" && NSImage(contentsOf: $0) != nil },
                    "snapshot exists and decodes: \(name)")
            }
            print("Capture contrast probe passed. Snapshots: \(output.path)")
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}
