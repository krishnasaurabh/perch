#if GALLERY_NATIVE_PROBE
    import AppKit
    import ApplicationServices
    import SwiftUI
    @testable import PerchApp

    @MainActor private enum GalleryActionCheck {
        static func run() async throws {
            _ = NSApplication.shared
            guard Bundle.main.bundleIdentifier == nil else { throw GalleryInteractionError.bundledHost }
            await primeAccessibility()
            let host = NSHostingView(
                rootView: GalleryPage(page: .motion)
                    .environment(\.accessibilityEnabled, true)
                    .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: GalleryPage.Page.motion.size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            defer { window.close() }
            await activateKeyWindow(window)
            guard window.isKeyWindow else {
                dumpAccessibility(in: window)
                throw GalleryInteractionError.noKeyWindow
            }

            try press(try await find("Start it now", role: "AXButton", in: window))
            _ = try await find("Pause", role: "AXButton", in: window)
            try press(try await find("Pause", role: "AXButton", in: window))
            _ = try await find("Start", role: "AXButton", in: window)
            try press(try await find("+5 min", role: "AXButton", in: window))
            _ = try await find("30 minutes left of 45", in: window)
            try press(try await find("Back to 24:10", role: "AXButton", in: window))
            _ = try await find("25 minutes left of 45", in: window)
            try press(try await find("15", role: "AXButton", in: window))
            _ = try await find("15 minutes left of 15", in: window)
            let step = try await find("Complete Write the smoke tests", role: "AXCheckBox", in: window)
            try press(step)
            _ = try await find("10:00 – 10:45 · 3 of 4 steps", in: window)
            let headsUp = try await find("Heads-up before a block ends", role: "AXCheckBox", in: window)
            guard (attribute(headsUp, "accessibilityValue") as? NSNumber)?.intValue == 1 else {
                throw GalleryInteractionError.invalidSwitchValue
            }
            try press(headsUp)
            let toggled = try await find("Heads-up before a block ends", role: "AXCheckBox", value: 0, in: window)
            guard (attribute(toggled, "accessibilityValue") as? NSNumber)?.intValue == 0 else {
                throw GalleryInteractionError.invalidSwitchValue
            }
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
        /// Keep self-AX off the main actor and limit it to a plain native window, not gallery bindings.
        private static func primeAccessibility() async {
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.title = "Gallery accessibility fixture"
            primer.contentView = NSTextField(labelWithString: "Gallery accessibility fixture")
            primer.orderFront(nil)
            defer { primer.close() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    AXUIElementSetMessagingTimeout(app, 2)
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    FileHandle.standardError.write(Data("Gallery AX root priming: \(status.rawValue)\n".utf8))
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            AXUIElementSetMessagingTimeout(window, 2)
                            var title: CFTypeRef?
                            let titleResult = AXUIElementCopyAttributeValue(
                                window, kAXTitleAttribute as CFString, &title)
                            guard titleResult == .success,
                                title as? String == "Gallery accessibility fixture"
                            else { continue }
                            var children: CFTypeRef?
                            let result = AXUIElementCopyAttributeValue(
                                window, kAXChildrenAttribute as CFString, &children)
                            FileHandle.standardError.write(
                                Data("Gallery AX window priming: \(result.rawValue)\n".utf8))
                        }
                    }
                    // A denied external AX query is diagnostic, never a reason to skip the real assertions.
                    continuation.resume()
                }
            }
        }

        private static func find(_ label: String, role: String? = nil, value: Int? = nil, in window: NSWindow)
            async throws -> NSObject
        {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                if let node = nodes(window).first(where: { node in
                    let values = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                        .compactMap { attribute(node, $0) as? String }
                    return values.contains(label)
                        && (role == nil || attribute(node, "accessibilityRole") as? String == role)
                        && (value == nil || (attribute(node, "accessibilityValue") as? NSNumber)?.intValue == value)
                }) {
                    return node
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            dumpAccessibility(in: window)
            FileHandle.standardError.write(Data("Gallery is missing \(label)\n".utf8))
            throw GalleryInteractionError.missingElement
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
                "Gallery: key=\(window.isKeyWindow); frame=\(window.frame); content=\(String(describing: window.contentView?.frame))"
            let report = header + "\n" + snapshot + "\n"
            FileHandle.standardError.write(Data(report.utf8))
            let directory = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"]
                    ?? FileManager.default.temporaryDirectory.path
            ).appendingPathComponent("native-diagnostics/gallery")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? report.write(
                to: directory.appendingPathComponent("accessibility.txt"), atomically: true, encoding: .utf8)
            if let view = window.contentView,
                let shot = try? AppDelegate.previewPNG(view: view, rect: view.bounds)
            {
                try? shot.data.write(to: directory.appendingPathComponent("gallery.png"))
            }
        }

        private static func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private static func press(_ node: NSObject) throws {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard node.responds(to: selector), let implementation = node.method(for: selector) else {
                throw GalleryInteractionError.missingPress
            }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            guard unsafeBitCast(implementation, to: Press.self)(node, selector) else {
                throw GalleryInteractionError.pressRejected
            }
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

    private enum GalleryInteractionError: Error {
        case missingElement, missingPress, pressRejected, invalidSwitchValue, noKeyWindow, bundledHost
    }

    enum GalleryNativeProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await GalleryActionCheck.run()
                        FileHandle.standardError.write(Data("PASS: Gallery native actions and visible state\n".utf8))
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Gallery native actions: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }
    }
#endif
