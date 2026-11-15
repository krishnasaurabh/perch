#if AGENT_GUIDANCE_PROBE
    import AppKit
    import SwiftUI
    import ApplicationServices
    @testable import PerchApp
    @testable import PlannerCore

    /// Exercise production controls across the same pane-identity boundary as SettingsView.
    final class AgentGuidanceCheck {
        @MainActor
        func testRetryGuidanceReachesTheRecreatedPaneForEveryApp() async throws {
            for app in AgentConnector.App.allCases {
                let fixture = try AgentGuidanceFixture(app: app)
                defer { fixture.close() }
                try await press("settings.agents.\(app.rawValue).connect", in: fixture.window)
                try guidanceEqual(fixture.attempts, 1)
                try guidanceEqual(fixture.statuses[app], .notConnected)
                try guidanceNotNil(fixture.store.lastError)

                try await leaveAndReturn(fixture)
                // A second failure must also preserve the retry and not present success guidance.
                try await press("settings.error.retry", in: fixture.window)
                try guidanceEqual(fixture.attempts, 2)
                try guidanceRequire(!texts(in: fixture.window).contains(fixture.guidance))
                try await leaveAndReturn(fixture)

                fixture.shouldFail = false
                try await press("settings.error.retry", in: fixture.window)
                try await waitUntil { texts(in: fixture.window).contains(fixture.guidance) }
                try guidanceEqual(fixture.attempts, 3)
                try guidanceEqual(fixture.statuses[app], .connected)
                try guidanceNil(fixture.store.lastError)
                try guidanceRequire(texts(in: fixture.window).contains(AppL10n.text("Connected")))
                try guidanceRequire(nodes(in: fixture.window).contains { identifier($0) == fixture.disconnectID })
                try guidanceRequire(!nodes(in: fixture.window).contains { identifier($0) == "settings.error.retry" })
                try guidanceRequire(AgentConnector.jsonHasServer(fixture.config, path: ["mcpServers"]))
                try await leaveAndReturn(fixture, guidanceVisible: true)
                try guidanceRequire(texts(in: fixture.window).contains(fixture.guidance))
                try guidanceEqual(try Data(contentsOf: fixture.store.file.url), fixture.originalPlanner)

                try await press(fixture.disconnectID, in: fixture.window)
                try await waitUntil { !texts(in: fixture.window).contains(fixture.guidance) }
                try guidanceEqual(fixture.statuses[app], .notConnected)
                try guidanceRequire(!AgentConnector.jsonHasServer(fixture.config, path: ["mcpServers"]))
            }
        }

        @MainActor
        func testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow() async throws {
            let fixture = try AgentGuidanceFixture(app: .cursor)
            defer { fixture.close() }
            try await press("settings.agents.cursor.connect", in: fixture.window)
            try await press("settings.sidebar.general", in: fixture.window)
            try await waitUntil { !texts(in: fixture.window).contains(AppL10n.text("Connected apps")) }
            fixture.shouldFail = false
            try await press("settings.error.retry", in: fixture.window)
            try guidanceNil(fixture.store.lastError)
            try guidanceEqual(fixture.statuses[.cursor], .connected)
            try await press("settings.sidebar.agents", in: fixture.window)
            try await waitUntil { texts(in: fixture.window).contains(fixture.guidance) }

            let otherWindow = try AgentGuidanceFixture(app: .cursor)
            defer { otherWindow.close() }
            try await waitUntil { texts(in: otherWindow.window).contains(AppL10n.text("Connected apps")) }
            try guidanceRequire(!texts(in: otherWindow.window).contains(fixture.guidance))
            try guidanceEqual(otherWindow.attempts, 0)
            try guidanceEqual(otherWindow.statuses[.cursor], .notConnected)
        }

        @MainActor
        private func leaveAndReturn(_ fixture: AgentGuidanceFixture, guidanceVisible: Bool = false) async throws {
            try await press("settings.sidebar.general", in: fixture.window)
            try await waitUntil { !texts(in: fixture.window).contains(AppL10n.text("Connected apps")) }
            try guidanceEqual(fixture.store.lastError != nil, !guidanceVisible)
            try await press("settings.sidebar.agents", in: fixture.window)
            try await waitUntil { texts(in: fixture.window).contains(AppL10n.text("Connected apps")) }
            try await waitUntil { texts(in: fixture.window).contains(fixture.guidance) == guidanceVisible }
        }

        @MainActor
        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            if !condition() {
                for window in NSApp.windows { print(diagnostics(in: window)) }
            }
            try guidanceRequire(condition(), "The hosted Settings state did not settle")
        }

        @MainActor
        private func press(_ id: String, in window: NSWindow) async throws {
            try await waitUntil { nodes(in: window).contains { identifier($0) == id } }
            let controls = nodes(in: window).filter {
                identifier($0) == id && attribute($0, "accessibilityRole") as? String == "AXButton"
            }
            if controls.count != 1 { print(diagnostics(in: window)) }
            try guidanceEqual(controls.count, 1, "Expected one accessible action for \(id)")
            let control = try guidanceUnwrap(controls.first)
            if id.hasSuffix(".connect") {
                try guidanceEqual(attribute(control, "accessibilityValue") as? String, AppL10n.text("Not connected"))
            }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try guidanceUnwrap(
                control.responds(to: selector) ? control.method(for: selector) : nil)
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            try guidanceRequire(unsafeBitCast(implementation, to: Press.self)(control, selector))
            await Task.yield()
        }

        @MainActor
        private func identifier(_ object: NSObject) -> String? {
            attribute(object, "accessibilityIdentifier") as? String
        }

        @MainActor
        private func texts(in window: NSWindow) -> Set<String> {
            Set(
                nodes(in: window).flatMap { node in
                    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                        .compactMap { attribute(node, $0) as? String }
                })
        }

        @MainActor
        private func nodes(in window: NSWindow) -> [NSObject] {
            // SwiftUI's scroll content publishes its semantic nodes during layout.
            // Every read must settle that layout, including reads after pane replacement.
            window.contentView?.layoutSubtreeIfNeeded()
            var result: [NSObject] = []
            var seen = Set<ObjectIdentifier>()
            @MainActor func visit(_ node: NSObject) {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return }
                result.append(node)
                if let view = node as? NSView { view.subviews.forEach(visit) }
                for key in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                {
                    (attribute(node, key) as? [NSObject] ?? []).forEach(visit)
                }
            }
            if let content = window.contentView { visit(content) }
            return result
        }

        @MainActor
        private func diagnostics(in window: NSWindow) -> String {
            let inventory = nodes(in: window).map { node in
                let values = [
                    "accessibilityRole", "accessibilityIdentifier", "accessibilityLabel",
                    "accessibilityTitle", "accessibilityValue",
                ].map { key in
                    "\(key)=\(attribute(node, key) ?? "nil")"
                }.joined(separator: " ")
                let bounds = (node as? NSView).map { String(describing: $0.bounds) } ?? "not a view"
                return "\(type(of: node)) bounds=\(bounds) \(values)"
            }.joined(separator: "\n")
            return "Settings host: visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
                + "responder=\(String(describing: window.firstResponder))\n\(inventory)"
        }

        @MainActor
        private func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
    }

    private enum AgentGuidanceProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try guidanceNil(Bundle.main.bundleIdentifier)
                        // Publish AppKit's AX roots before constructing the SwiftUI settings state.
                        let primer = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
                        primer.isReleasedWhenClosed = false
                        primer.contentView = NSTextField(labelWithString: "Settings fixture")
                        primer.orderFront(nil)
                        await primeAccessibility()
                        primer.close()
                        let check = AgentGuidanceCheck()
                        try await check.testRetryGuidanceReachesTheRecreatedPaneForEveryApp()
                        print("PASS: testRetryGuidanceReachesTheRecreatedPaneForEveryApp")
                        try await check.testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow()
                        print("PASS: testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow")
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Agent guidance: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }

        private nonisolated static func primeAccessibility() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    FileHandle.standardError.write(Data("Agent guidance AX priming: \(status.rawValue)\n".utf8))
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            var children: CFTypeRef?
                            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }
#else
    import Foundation
    import XCTest

    /// Keep both native scenarios outside XCTest's application/AX host.
    final class AgentGuidanceLifetimeTests: XCTestCase {
        private static let result: Result<String, Error> = Result { try runProbe() }

        func testRetryGuidanceReachesTheRecreatedPaneForEveryApp() throws {
            try assertPass("PASS: testRetryGuidanceReachesTheRecreatedPaneForEveryApp")
        }

        func testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow() throws {
            try assertPass("PASS: testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow")
        }

        private func assertPass(_ marker: String) throws {
            let output = try Self.result.get()
            XCTAssertEqual(output.components(separatedBy: .newlines).filter { $0 == marker }.count, 1, output)
        }

        private static func runProbe() throws -> String {
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for item in ["Package.swift", "Sources", "Tests"] {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(item), to: temporary.appendingPathComponent(item))
            }
            let tests = source.deletingLastPathComponent()
            let assertions = try String(
                contentsOf: tests.appendingPathComponent("AgentGuidanceProbeAssertions.swift"), encoding: .utf8)
            let program =
                try String(contentsOf: source, encoding: .utf8) + "\n" + assertions
                + "\nAgentGuidanceProbe.run()\n"
            try program.write(
                to: temporary.appendingPathComponent("Sources/Perch/main.swift"), atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("guidance.log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import os, pathlib, subprocess, sys
                package = pathlib.Path(sys.argv[1])
                tests = package / 'Tests/PerchAppTests'
                support = (tests / 'AgentGuidanceProbeSupport.swift').read_text()
                support = support.replace('#if AGENT_GUIDANCE_SUPPORT', '#if AGENT_GUIDANCE_PROBE', 1)
                support += '\n' + (tests / 'AgentGuidanceProbeAssertions.swift').read_text()
                (package / 'Sources/PerchApp/AgentGuidanceProbeSupport.swift').write_text(support)
                pane = package / 'Sources/PerchApp/Settings/SettingsAgentsPane.swift'
                source = pane.read_text()
                old = 'AgentsSettings(statuses: $statuses, feedback: feedback)'
                new = 'AgentGuidanceFixture.agents(statuses: $statuses, feedback: feedback, store: store)'
                assert source.count(old) == 1, 'The injection seam changed; do not alter production actions'
                pane.write_text(source.replace(old, new, 1))
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', str(package),
                    '-Xswiftc', '-DAGENT_GUIDANCE_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', str(package),
                ], text=True, timeout=30).strip()
                environment = dict(os.environ, PERCH_DATA=str(package / 'isolated-planner.json'))
                subprocess.run([
                    str(pathlib.Path(bin_path) / 'Perch'), '--open', 'settings/agents-connected',
                ], check=True, timeout=120, env=environment)
                """#, temporary.path,
            ]
            process.currentDirectoryURL = temporary
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let result = try String(contentsOf: log, encoding: .utf8)
            FileHandle.standardError.write(Data(result.utf8))
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw NSError(
                    domain: "AgentGuidanceProbe", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: result])
            }
            return result
        }
    }
#endif
