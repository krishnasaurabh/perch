#if CHECKLIST_PREVIEW_SEQUENCE_PROBE
    import AppKit
    import ApplicationServices
    import EventKit
    @testable import PerchApp
    @testable import PlannerCore

    @MainActor
    private enum ChecklistPreviewSequenceProbe {
        static func run() {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    try await checkSequences()
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("FAIL: checklist preview sequence: \(error)\n".utf8))
                    exit(1)
                }
            }
            application.run()
        }

        private static func checkSequences() async throws {
            try require(Bundle.main.bundleIdentifier == nil, "The preview fixture must run unbundled")
            let calendarStatus = EKEventStore.authorizationStatus(for: .event)
            try require(
                calendarStatus == .notDetermined || calendarStatus == .denied || calendarStatus == .restricted,
                "The preview fixture must not read an authorized calendar")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = PlannerFile(
                url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            var planner = Planner()
            planner.preferences.welcomeCompleted = true
            planner.preferences.catchCopies = false
            planner.preferences.catchScreenshots = false
            planner.preferences.remindersSync = false
            planner.preferences.resetHour = 0
            try file.save(planner)
            let app = AppDelegate()
            app.store = PlannerStore(file: file, now: { PlannerPreviewScenarios.referenceDate }, watching: false)
            app.model = NotchModel()
            app.services = Services(store: app.store)
            let voice = app.services.voice
            let permissionError = AppL10n.text(
                "Allow Speech Recognition for Perch under System Settings › Privacy & Security.")
            let listening = AppL10n.text("Listening. Tap the mic to stop.")
            let expectedText = "Call Sam at 1:30 PM\nWrite notes for 20 min"

            for (state, name) in [(ChecklistPreviewState.voiceError, "error"), (.dictating, "dictating")] {
                ChecklistPreview.show(state, app: app)
                let first = try await capture("\(name)-before-multiline", in: directory)
                if state == .voiceError {
                    try require(voice.state == .error(permissionError), "Error preview seeds synthetic voice error")
                    try require(
                        first.identifiers.contains("capture-dictation-error"), "Error capture exposes its banner")
                    try require(first.text.contains(permissionError), "Error capture contains the permission guidance")
                } else {
                    try require(voice.state == .listening, "Dictating preview seeds synthetic listening state")
                    try require(first.identifiers.contains("capture-listening"), "Dictating capture exposes listening")
                    try require(first.text.contains(listening), "Dictating capture contains listening guidance")
                    try require(
                        first.text.contains(AppL10n.text("Stop listening")), "Dictating capture offers Stop listening")
                }
                // Match the batch runner: close the prior host and drain its registration
                // before opening the next shot, while retaining the same delegate/services.
                try await closePreview()
                ChecklistPreview.show(.multiline, app: app)
                let second = try await capture("\(name)-then-multiline", in: directory)
                try require(app.services.voice === voice, "The sequence must reuse the same voice service")
                try require(voice.state == .idle, "\(name) -> multiline resets synthetic voice state")
                try require(
                    second.captureValues.contains(expectedText), "\(name) -> multiline shows the multiline draft")
                try require(
                    !second.text.contains(permissionError), "\(name) -> multiline has no permission-error string")
                try require(
                    !second.identifiers.contains("capture-dictation-error"), "\(name) -> multiline has no error banner")
                try require(
                    !second.identifiers.contains("capture-listening"), "\(name) -> multiline has no listening banner")
                try require(!second.text.contains(listening), "\(name) -> multiline has no listening guidance")
                try require(
                    !second.text.contains(AppL10n.text("Stop listening")),
                    "\(name) -> multiline has no pending listening control")
                try require(
                    !second.text.contains(AppL10n.text("Try adding the dictated task again")),
                    "\(name) -> multiline has no pending-dictation retry")
                try require(
                    second.text.contains(AppL10n.text("Dictate instead")), "\(name) -> multiline restores the idle mic")
                try await closePreview()
                FileHandle.standardError.write(
                    Data("PASS: checklist \(name) -> multiline voice presentation is clean\n".utf8))
            }
        }

        private struct Capture {
            var identifiers: Set<String>
            var text: Set<String>
            var captureValues: Set<String>
        }

        private static func capture(_ name: String, in directory: URL) async throws -> Capture {
            await settle()
            await Task.detached {
                let application = AXUIElementCreateApplication(getpid())
                var raw: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
                for window in (raw as? [AXUIElement]) ?? [] {
                    var children: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                }
            }.value
            await settle()
            guard let window = WindowHost.windows["checklist-preview"], window.isVisible,
                let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)
            else { throw failure("\(name): visible preview capture is required") }
            root.layoutSubtreeIfNeeded()
            root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw failure("\(name): capture must render a PNG")
            }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            let elements = nodes(root)
            return Capture(
                identifiers: Set(elements.map { text($0, "accessibilityIdentifier") }),
                text: Set(
                    elements.flatMap { node in
                        ["accessibilityLabel", "accessibilityValue"].map { text(node, $0) }
                    }),
                captureValues: Set(
                    elements.filter { text($0, "accessibilityIdentifier") == "capture-add-task" }
                        .map { text($0, "accessibilityValue") }))
        }

        private static func closePreview() async throws {
            WindowHost.windows["checklist-preview"]?.close()
            await settle()
            try require(WindowHost.windows["checklist-preview"] == nil, "Closed preview must clear its registration")
        }

        private static func settle() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { continuation.resume() }
            }
        }

        private static func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private static func text(_ node: NSObject, _ name: String) -> String {
            let value = attribute(node, name)
            return (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        }

        private static func nodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            func walk(_ node: NSObject, depth: Int) -> [NSObject] {
                guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                var children: [NSObject] = []
                for name in [
                    "accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder",
                ] {
                    children += (attribute(node, name) as? [NSObject]) ?? []
                }
                children += (node as? NSView)?.subviews ?? []
                return [node] + children.flatMap { walk($0, depth: depth + 1) }
            }
            return walk(root, depth: 0)
        }

        private static func failure(_ message: String) -> NSError {
            NSError(domain: "ChecklistPreviewSequence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        private static func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw failure(message) }
        }
    }
#else
    import Foundation
    import XCTest

    /// Keep permission-backed services out of the XCTest host, as in the other native probes.
    final class ChecklistPreviewSequenceTests: XCTestCase {
        func testErrorAndDictatingPreviewsDoNotLeakIntoLaterMultilineCaptures() throws {
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for item in ["Package.swift", "Sources", "Tests"] {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(item), to: temporary.appendingPathComponent(item))
            }
            let program = try String(contentsOf: source, encoding: .utf8) + "\nChecklistPreviewSequenceProbe.run()\n"
            try program.write(
                to: temporary.appendingPathComponent("Sources/Perch/main.swift"), atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("sequence.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import os, pathlib, subprocess, sys
                package = sys.argv[1]
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', package,
                    '-Xswiftc', '-DCHECKLIST_PREVIEW_SEQUENCE_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', package,
                ], text=True, timeout=30).strip()
                environment = dict(os.environ, PERCH_DATA=str(pathlib.Path(package) / 'synthetic-planner.json'))
                subprocess.run([
                    str(pathlib.Path(bin_path) / 'Perch'), '-AppleLanguages', '(en)',
                ], env=environment, check=True, timeout=60)
                """#, temporary.path,
            ]
            process.currentDirectoryURL = temporary
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let result = try String(contentsOf: log, encoding: .utf8)
            FileHandle.standardError.write(Data(result.utf8))
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0, "Native checklist preview sequence failed:\n\(result)")
            for state in ["error", "dictating"] {
                let marker = "PASS: checklist \(state) -> multiline voice presentation is clean"
                XCTAssertEqual(result.components(separatedBy: marker).count - 1, 1, "Missing or duplicate: \(marker)")
            }
        }
    }
#endif
