import AppKit
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
/// When a button can't be found, the step falls back to the same mutation the button makes and says so
/// in the markers file (`via`).
@MainActor
enum MotionScript {
    private static var runner: Runner?

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
            let target = NotchPage(rawValue: "insights") ?? .week
            let steps: [Step] = [
                Step(name: "ready", wait: 4.0, capture: false) { "launch" },  // long still lead-in for alignment
                Step(name: "open", wait: 1.6, capture: true) {
                    NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home); return "perchOpenWorkspace"
                },
                Step(name: "close", wait: 1.6, capture: true) { [model] in model.close(); return "NotchModel.close" },
                Step(name: "reopen", wait: 1.4, capture: false) {
                    NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home); return "perchOpenWorkspace"
                },
                Step(name: "page", wait: 1.4, capture: true) { [model] in
                    self.press(target.title, else: {
                        withAnimation(.spring(response: 0.3)) { model.page = target }
                        return "direct:model.page=\(target.rawValue)"
                    })
                },
                Step(name: "page-back", wait: 1.2, capture: false) { [model] in
                    self.press(NotchPage.home.title, else: { model.page = .home; return "direct:model.page=home" })
                },
                Step(name: "tick", wait: 1.6, capture: true) { [store] in
                    self.press("Mark as complete", else: {
                        guard let t = store.engine.tasks(on: .day(store.today)).first(where: { !$0.done }) else { return "none" }
                        store.apply { try $0.complete(t.id.uuidString) }
                        Confetti.fire()
                        return "direct:complete"
                    })
                },
                Step(name: "timer", wait: 1.6, capture: true) { [store] in
                    self.press("Start", else: {
                        store.apply { try $0.startTimer(task: nil, minutes: 25) }
                        return "direct:startTimer"
                    })
                },
                Step(name: "end", wait: 1.0, capture: false) { [model] in model.close(); return "NotchModel.close" },
            ]
            schedule(steps[...], extra: ["page": target.rawValue])
        }

        private func schedule(_ rest: ArraySlice<Step>, extra: [String: String]) {
            guard let step = rest.first else {
                write(); NSApp.terminate(nil); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) { [self] in
                let t = Date().timeIntervalSince1970
                let via = step.action()
                var m: [String: Any] = ["name": step.name, "t": t, "uptime": ProcessInfo.processInfo.systemUptime, "via": via]
                if step.name == "page" { m["target"] = extra["page"] ?? "" }
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
            let doc: [String: Any] = ["markers": markers, "screens": NSScreen.screens.map { ["w": $0.frame.width, "h": $0.frame.height, "scale": $0.backingScaleFactor] }]
            if let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: markersURL) }
        }

        // MARK: Pressing real buttons through our own accessibility tree

        /// Presses the first element labelled `label` in a visible notch window. Returns the `via` string, or nil.
        /// Uses the ObjC accessibility methods directly, so it works for NSViews and SwiftUI's private AX nodes alike.
        private func press(_ label: String, else fallback: () -> String) -> String { press(label) ?? fallback() }

        private func press(_ label: String) -> String? {
            for w in NSApp.windows where w is NotchPanel && w.isVisible {
                guard let root = w.contentView else { continue }
                if let el = find(label, in: root, depth: 0), AX.press(el) { return "ax-press:\(label)" }
            }
            return nil
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

        private func grab(_ view: NSView, start: TimeInterval) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            burstFrames.append((Date().timeIntervalSince1970 - start, rep))
        }

        private func burst(name: String, into dir: URL, start: TimeInterval, done: @escaping @MainActor () -> Void) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let panel = NSApp.windows.compactMap({ $0 as? NotchPanel }).first(where: { $0.isVisible }), let view = panel.contentView
            else { done(); return }
            burstFrames = []
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

    static func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel), let imp = o.method(for: sel) else { return false }
        return unsafeBitCast(imp, to: BoolGetter.self)(o, sel)
    }
}
