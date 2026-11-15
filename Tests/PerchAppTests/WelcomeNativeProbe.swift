#if WELCOME_NATIVE_PROBE
    import AppKit
    import ApplicationServices
    import PlannerCore
    import SwiftUI
    @testable import PerchApp

    @MainActor private enum WelcomeCopyCheck {
        private static let requiredCopy = [
            "A calmer way through a busy day",
            "Perch sits in your Mac's notch. Three small habits do most of the work.",
            "Write it down", "Give it time", "Park the rest",
            "Start with three things", "Look around first",
            "Click the notch for everything", "Hover for a quick peek",
            "Nothing to allow yet",
            "Calendar", "Notifications", "Microphone",
            "Your tasks stay on this Mac.",
        ]
        private static let forbiddenCopy = ["Add new screenshots to Clips", "Allow"]

        static func run() async throws {
            _ = NSApplication.shared
            guard Bundle.main.bundleIdentifier == nil else { throw WelcomeCopyError.bundledHost }
            guard let dataPath = ProcessInfo.processInfo.environment["PERCH_DATA"] else {
                throw WelcomeCopyError.missingDataPath
            }
            await primeAccessibility()
            let store = PlannerStore(
                file: PlannerFile(url: URL(fileURLWithPath: dataPath), preferences: MemoryPlannerPreferences()),
                watching: false)
            let host = NSHostingView(
                rootView: WelcomeView {}.environmentObject(store)
                    .environment(\.accessibilityEnabled, true))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: WelcomeView.windowSize),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(WelcomeView.windowSize)
            window.center()
            defer { window.close() }
            await activateKeyWindow(window)
            guard window.isKeyWindow else {
                dumpAccessibility(in: window)
                throw WelcomeCopyError.noKeyWindow
            }
            try await requireCopy(in: window)
        }

        private static func activateKeyWindow(_ window: NSWindow) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.contentView?.layoutSubtreeIfNeeded()
                if window.isKeyWindow { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        /// Activate AppKit's lazy AX publication before constructing the nested SwiftUI scroll host.
        /// Keep self-AX off the main actor and limit it to a plain native window, not Welcome bindings.
        private static func primeAccessibility() async {
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.title = "Welcome accessibility fixture"
            primer.contentView = NSTextField(labelWithString: "Welcome accessibility fixture")
            primer.orderFront(nil)
            defer { primer.close() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    AXUIElementSetMessagingTimeout(app, 2)
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    FileHandle.standardError.write(Data("Welcome AX root priming: \(status.rawValue)\n".utf8))
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            AXUIElementSetMessagingTimeout(window, 2)
                            var title: CFTypeRef?
                            let titleResult = AXUIElementCopyAttributeValue(
                                window, kAXTitleAttribute as CFString, &title)
                            guard titleResult == .success,
                                title as? String == "Welcome accessibility fixture"
                            else { continue }
                            var children: CFTypeRef?
                            let result = AXUIElementCopyAttributeValue(
                                window, kAXChildrenAttribute as CFString, &children)
                            FileHandle.standardError.write(
                                Data("Welcome AX window priming: \(result.rawValue)\n".utf8))
                        }
                    }
                    // A denied external AX query is diagnostic, never a reason to skip the real assertions.
                    continuation.resume()
                }
            }
        }

        private static func requireCopy(in window: NSWindow) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            var missing = requiredCopy
            var forbidden: [String] = []
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                let observed = Set(
                    nodes(window).flatMap { node in
                        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                            .compactMap { accessibilityString(attribute(node, $0)) }
                    })
                missing = requiredCopy.filter { !observed.contains($0) }
                forbidden = forbiddenCopy.filter { observed.contains($0) }
                if !forbidden.isEmpty { break }
                if missing.isEmpty { return }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            dumpAccessibility(in: window)
            for label in missing {
                FileHandle.standardError.write(Data("Welcome is missing exact copy: \(label)\n".utf8))
            }
            for label in forbidden {
                FileHandle.standardError.write(Data("Welcome contains forbidden copy: \(label)\n".utf8))
            }
            throw WelcomeCopyError.invalidCopy
        }

        private static func dumpAccessibility(in window: NSWindow) {
            let snapshot = nodes(window).map { node in
                let fields = [
                    "accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue",
                    "accessibilityIdentifier",
                ].map { name in "\(name)=\(String(describing: attribute(node, name)))" }.joined(separator: "; ")
                return "\(String(reflecting: type(of: node))): \(fields)"
            }.joined(separator: "\n")
            let header =
                "Welcome: key=\(window.isKeyWindow); frame=\(window.frame); content=\(String(describing: window.contentView?.frame))"
            let report = header + "\n" + snapshot + "\n"
            FileHandle.standardError.write(Data(report.utf8))
            let directory = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"]
                    ?? FileManager.default.temporaryDirectory.path
            ).appendingPathComponent("native-diagnostics/welcome")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? report.write(
                to: directory.appendingPathComponent("accessibility.txt"), atomically: true, encoding: .utf8)
            if let view = window.contentView,
                let shot = try? AppDelegate.previewPNG(view: view, rect: view.bounds)
            {
                try? shot.data.write(to: directory.appendingPathComponent("welcome.png"))
            }
        }

        private static func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private static func accessibilityString(_ value: Any?) -> String? {
            if let attributed = value as? NSAttributedString { return attributed.string }
            return value as? String
        }

        private static func nodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            @MainActor func walk(_ node: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                var children = [
                    "accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder",
                ]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let view = window.contentView { children.append(view) }
                return [node] + children.flatMap { walk($0) }
            }
            return walk(root)
        }
    }

    private enum WelcomeCopyError: Error {
        case invalidCopy, noKeyWindow, bundledHost, missingDataPath
    }

    enum WelcomeNativeProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await WelcomeCopyCheck.run()
                        FileHandle.standardError.write(Data("PASS: Welcome native accessibility copy\n".utf8))
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Welcome native accessibility copy: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }
    }
#endif
