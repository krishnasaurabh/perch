import AppKit
import ApplicationServices  // AX client API (motion driver only)
import PlannerCore
import SwiftUI

/// CI motion capture driver (scripts/motion_capture.sh). Additive and inert unless the flag is passed.
///
///   Perch --motion-script <markers.json>                      drive five transitions on a fixed timeline
///   Perch --motion-script <markers.json> --motion-snapshots <dir>
///                                                             also render the notch window every 16 ms around
///                                                             each transition (in-process fallback, not
///                                                             compositor output; labelled as such)
///
/// The screen itself is recorded externally. Transitions go through the app's own entry points: the
/// "open workspace" notification (menu / ⌥N path), `NotchModel.close()` (Esc path), and the real SwiftUI
/// buttons pressed through this process's own accessibility tree (no Accessibility permission needed).
/// Missing controls fail closed; no model fallback can count as UI evidence.
@MainActor
enum MotionScript {
    private static var runner: Runner?
    // Ordinary launches retain live OS policy; two explicit flags are required.
    nonisolated static var policyOverride: MotionPolicy? {
        let args = CommandLine.arguments
        guard args.contains("--motion-script"), let i = args.firstIndex(of: "--motion-policy"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "normal": return MotionPolicy(reduceMotion: false)
        case "reduced": return MotionPolicy(reduceMotion: true)
        default: return nil
        }
    }
    static var environmentPolicy: [String: Any] = [:]
    static var transactions: [[String: Any]] = []
    struct PolicyProbe: ViewModifier {
        @Environment(\.accessibilityReduceMotion) var systemReduced
        @Environment(\.motionPolicy) var policy
        func body(content: Content) -> some View {
            content.transaction { transaction in
                MainActor.assumeIsolated {
                    guard CommandLine.arguments.contains("--motion-script") else { return }
                    MotionScript.environmentPolicy = ["swiftui_reduce_motion": systemReduced,
                        "resolved_reduce_motion": policy.reduceMotion]
                    var enforced = transaction
                    policy.enforce(on: &enforced)
                    MotionScript.transactions.append(["t": Date().timeIntervalSince1970,
                        "animation": String(describing: transaction.animation),
                        "disables_animations": transaction.disablesAnimations,
                        "enforced_animation": String(describing: enforced.animation),
                        "enforced_disables_animations": enforced.disablesAnimations])
                }
            }
        }
    }

    static func startIfRequested(store: PlannerStore, model: NotchModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--motion-script"), i + 1 < args.count else { return }
        var snapshots: URL?
        if let j = args.firstIndex(of: "--motion-snapshots"), j + 1 < args.count { snapshots = URL(fileURLWithPath: args[j + 1]) }
        let r = Runner(store: store, model: model, markers: URL(fileURLWithPath: args[i + 1]), snapshots: snapshots)
        runner = r
        r.seed()
        r.run()
    }

    @MainActor
    final class Runner {
        let store: PlannerStore
        let model: NotchModel
        let markersURL: URL
        let snapshotDir: URL?
        private var markers: [[String: Any]] = []

        init(store: PlannerStore, model: NotchModel, markers: URL, snapshots: URL?) {
            self.store = store; self.model = model; self.markersURL = markers; self.snapshotDir = snapshots
        }

        /// A small, fixed day with no running timer, so "timer start" is a real start.
        func seed() {
            store.apply { e in
                if e.planner.tasks.isEmpty {
                    _ = try e.addTasks(["Draft launch notes", "Reply to Sam", "Water the plants every 3 days"])
                }
                _ = e.stopTimer()
                e.planner.preferences.welcomeCompleted = true
            }
        }

        struct Step { let name: String; let wait: Double; let capture: Bool; let action: @MainActor () -> String }

        func run() {
            // Keep the captured page transition fixed when other pages are added to the app.
            let target = NotchPage.week
            let steps: [Step] = [
                Step(name: "ready", wait: 4.0, capture: false) { "launch" },  // long still lead-in for alignment
                Step(name: "open", wait: 2.4, capture: true) {
                    NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home); return "perchOpenWorkspace"
                },
                Step(name: "close", wait: 2.4, capture: true) { [model] in model.close(); return "NotchModel.close" },
                Step(name: "reopen", wait: 2.4, capture: false) {
                    NSApp.activate(ignoringOtherApps: true)
                    // SwiftUI builds its macOS accessibility tree lazily, on the first request from an accessibility
                    // client. A CI VM has none (no VoiceOver, no automation), so the panel's tree stays at 0 nodes
                    // and every press misses: all button steps took `direct:` on hosted macos-15 up to cf597e1, and
                    // activating the app did not help. PERCH_MOTION_AX_WAKE=inproc (motion_capture.sh's default)
                    // makes this process its own client: an AX API read of its own windows, off the main thread,
                    // which serves the request. A System Events query from outside wakes it the same way. `ax_nodes`
                    // in each marker records the tree size before that step.
                    let mode = ProcessInfo.processInfo.environment["PERCH_MOTION_AX_WAKE"] ?? "none"
                    if mode == "inproc" {
                        DispatchQueue.global().async {
                            let r = AX.queryOwnWindows()
                            Task { @MainActor in self.axWake = r }
                        }
                    }
                    NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home); return "perchOpenWorkspace"
                },
                // 2.4 s (was 1.4): settle time for SwiftUI to publish the tree after the wake.
                Step(name: "page", wait: 2.4, capture: true) { self.requiredPress(target.title) },
                Step(name: "page-back", wait: 2.4, capture: false) { self.requiredPress(NotchPage.home.title) },
                Step(name: "tick", wait: 2.4, capture: true) { self.requiredPress("Check off task") },
                Step(name: "timer", wait: 2.4, capture: true) { self.requiredPress("Start focus") },
                Step(name: "timer-stop", wait: 2.4, capture: false) { self.requiredPress("End focus session") },
                Step(name: "end", wait: 2.4, capture: false) { [model] in model.close(); return "NotchModel.close" },
            ]
            schedule(steps[...], extra: ["page": target.rawValue])
        }

        private func schedule(_ rest: ArraySlice<Step>, extra: [String: String]) {
            guard let step = rest.first else {
                write(); NSApp.terminate(nil); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) { [self] in
                // How much of the AX tree is visible right before the action (counted before `t`, so it doesn't
                // shift the action). `close` is the pre-wake baseline with the workspace open.
                let axNodes = axCount()
                let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
                let policy: [String: Any] = MotionScript.environmentPolicy.merging([
                    "nsworkspace_reduce_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    "explicit_reduce_motion": model.motionPolicy.reduceMotion,
                    "mode": MotionScript.policyOverride.map { $0.reduceMotion ? "diagnostic-reduced" : "diagnostic-normal" } ?? "production"
                ]) { _, rhs in rhs }
                let state: [String: Any] = ["screen_locked": Self.screenLocked,
                    "lock_key_present": session["CGSSessionScreenIsLocked"] != nil,
                    "on_console": session["kCGSSessionOnConsoleKey"] ?? "unknown", "app_active": NSApp.isActive,
                    "key_window": NSApp.keyWindow != nil, "expanded": model.expanded,
                    "page": model.page.rawValue, "timer_present": store.planner.focus != nil]
                let t = Date().timeIntervalSince1970
                // Frame 0 of every captured clip is grabbed just BEFORE the action runs (t ~ 0), so each clip has a
                // before/after pair even when the host can't animate.
                if step.capture, snapshotDir != nil { preGrab(start: t) }
                let via = step.action()
                var m: [String: Any] = ["name": step.name, "t": t, "uptime": ProcessInfo.processInfo.systemUptime, "via": via]
                if step.name == "page" { m["target"] = extra["page"] ?? "" }
                m["ax_nodes"] = axNodes
                m["policy"] = policy
                m["session"] = state
                m["interaction_ok"] = !via.hasPrefix("FAILED:")
                m["action_end_epoch"] = Date().timeIntervalSince1970
                if step.name == "reopen" {
                    m["ax_wake_mode"] = ProcessInfo.processInfo.environment["PERCH_MOTION_AX_WAKE"] ?? "none"
                    m["ax_trusted"] = AXIsProcessTrusted()
                }
                if let w = axWake { m["ax_wake_inproc"] = w }
                markers.append(m)
                write()
                if step.capture, let dir = snapshotDir {
                    burst(name: step.name, into: dir.appendingPathComponent(step.name), start: t) { self.schedule(rest.dropFirst(), extra: extra) }
                } else {
                    schedule(rest.dropFirst(), extra: extra)
                }
            }
        }

        private func write() {
            let doc: [String: Any] = ["schema": 2, "candidate_sha": ProcessInfo.processInfo.environment["PERCH_CANDIDATE_SHA"] ?? "unknown",
                "source_kind": snapshotDir == nil ? "compositor-driver" : "own-window-driver",
                "transactions": MotionScript.transactions, "markers": markers, "screens": NSScreen.screens.map { ["w": $0.frame.width, "h": $0.frame.height, "scale": $0.backingScaleFactor] }]
            if let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: markersURL) }
        }

        // MARK: Pressing real buttons through our own accessibility tree

        /// Presses the first element labelled `label` in a visible notch window. Returns the `via` string, or nil.
        /// Uses the ObjC accessibility methods directly, so it works for NSViews and SwiftUI's private AX nodes alike.
        private func requiredPress(_ label: String) -> String {
            let requested = ProcessInfo.processInfo.environment["PERCH_MOTION_MISSING_CONTROL"] == label ? "missing-control" : label
            return press(requested) ?? "FAILED:missing-control:\(label)"
        }

        static var screenLocked: Bool {
            (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        }

        private func press(_ label: String) -> String? {
            for w in NSApp.windows where w is NotchPanel && w.isVisible {
                guard let root = w.contentView else { continue }
                if let el = find(label, in: root, depth: 0), AX.press(el) { return "ax-press:\(label)" }
            }
            return nil
        }

        private var axWake: String?

        /// Accessibility descendants of the visible notch panel(s), capped. 0 = SwiftUI hasn't built the tree.
        private func axCount() -> Int {
            var n = 0
            func walk(_ o: NSObject, _ depth: Int) {
                guard depth < 60, n < 5000 else { return }
                for c in AX.children(o) { n += 1; walk(c, depth + 1) }
            }
            for w in NSApp.windows where w is NotchPanel && w.isVisible { if let v = w.contentView { walk(v, 0) } }
            return n
        }

        private func find(_ label: String, in node: NSObject, depth: Int) -> NSObject? {
            guard depth < 60 else { return nil }
            if depth > 0, AX.label(node) == label { return node }
            for c in AX.children(node) {
                if let f = find(label, in: c, depth: depth + 1) { return f }
            }
            return nil
        }

        // MARK: In-process fallback frames (16 ms timer, own-window render, not the compositor)

        private var burstFrames: [(Double, NSBitmapImageRep)] = []

        private func visiblePanelView() -> NSView? {
            NSApp.windows.compactMap({ $0 as? NotchPanel }).first(where: { $0.isVisible })?.contentView
        }

        /// Starts a clip with one frame of the pre-action state.
        private func preGrab(start: TimeInterval) {
            burstFrames = []
            if let view = visiblePanelView() { grab(view, start: start) }
        }

        private func grab(_ view: NSView, start: TimeInterval) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            burstFrames.append((Date().timeIntervalSince1970 - start, rep))
        }

        private func burst(name: String, into dir: URL, start: TimeInterval, done: @escaping @MainActor () -> Void) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let panel = NSApp.windows.compactMap({ $0 as? NotchPanel }).first(where: { $0.isVisible }), let view = panel.contentView
            else { done(); return }
            grab(view, start: start)
            let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self, weak view] _ in
                MainActor.assumeIsolated { if let self, let view { self.grab(view, start: start) } }
            }
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                timer.invalidate()
                var meta: [[String: Any]] = []
                for (i, f) in burstFrames.enumerated() {
                    let file = String(format: "f%03d.png", i)
                    if let png = f.1.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent(file)) }
                    meta.append(["i": i, "t": f.0, "file": file])
                }
                burstFrames = []
                let doc: [String: Any] = ["clip": name, "kind": "in-process-snapshot", "interval_requested_ms": 16,
                                          "pixelsWide": Int(view.bounds.width * panel.backingScaleFactor), "frames": meta]
                if let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
                    try? d.write(to: dir.appendingPathComponent("frames.json"))
                }
                done()
            }
        }
    }
}

/// Minimal runtime calls into the NSAccessibility informal protocol (NSViews and SwiftUI's own AX nodes).
private enum AX {
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool

    private static func object(_ o: NSObject, _ name: String) -> Any? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue()
    }

    static func label(_ o: NSObject) -> String? { object(o, "accessibilityLabel") as? String }
    static func children(_ o: NSObject) -> [NSObject] { (object(o, "accessibilityChildren") as? [Any])?.compactMap { $0 as? NSObject } ?? [] }

    /// Reads this process's windows and their children through the public AX client API, which is the request
    /// that makes SwiftUI build its tree. Must run off the main thread (the main thread answers it). Returns the
    /// AXError codes and counts, e.g. "windows=0:1 children=0:3" (-25211 = API disabled: no Accessibility grant).
    static func queryOwnWindows() -> String {
        let app = AXUIElementCreateApplication(getpid())
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
        let wins = (v as? [AXUIElement]) ?? []
        var kids = 0, ke: AXError = .success
        for w in wins {
            var c: CFTypeRef?
            ke = AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &c)
            kids += (c as? [AXUIElement])?.count ?? 0
        }
        return "windows=\(e.rawValue):\(wins.count) children=\(ke.rawValue):\(kids)"
    }

    static func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel), let imp = o.method(for: sel) else { return false }
        return unsafeBitCast(imp, to: BoolGetter.self)(o, sel)
    }
}
