import Foundation
import SwiftUI

#if DEBUG || PERCH_TESTING
    import AppKit
    import PlannerCore

    extension AppDelegate {
        /// Add a one-line registration when a new window, pane or notch state lands.
        static var previewTargets: [String: PreviewTarget] {
            [
                "today": .workspace(.home),
                "week": .workspace(.week),
                "settings": .window("settings") { $0.openSettings() },
                "your-week": .window("dashboard") { DashboardWindow.show(store: $0.store, tab: .insights) },
                "history": .window("dashboard") { DashboardWindow.show(store: $0.store, tab: .history) },
                "projects": .window("dashboard") { DashboardWindow.show(store: $0.store, tab: .projects) },
                "surfaces": .window("surface-preview") { _ in SurfacePreview.show(focused: false) },
                "surfaces-focused": .window("surface-preview") { _ in SurfacePreview.show(focused: true) },
            ]
        }

        static func previewTarget(_ name: String) throws -> PreviewTarget {
            guard let target = previewTargets[name] else { throw PlannerError("Unknown open target: \(name)") }
            return target
        }

        struct PreviewTarget {
            let open: @MainActor (AppDelegate) -> Void
            let surface: @MainActor (AppDelegate) -> (NSWindow, NSRect)?

            static func workspace(_ page: NotchPage) -> Self {
                Self(
                    open: { app in
                        NotificationCenter.default.post(name: .perchOpenWorkspace, object: page)
                    },
                    surface: { app in
                        guard app.model.expanded, app.model.page == page, let geometry = app.model.geometry,
                            let window = NSApp.windows.first(where: {
                                $0 is NotchPanel && $0.isVisible && $0.frame == geometry.window
                            }), let view = window.contentView
                        else { return nil }
                        let local = geometry.workspace.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
                        return (window, view.convert(local, from: nil))
                    })
            }

            static func window(_ id: String, open: @escaping @MainActor (AppDelegate) -> Void) -> Self {
                Self(
                    open: open,
                    surface: { _ in
                        guard let window = WindowHost.windows[id], window.isVisible, let view = window.contentView
                        else {
                            return nil
                        }
                        return (window, view.bounds)
                    })
            }
        }

        struct PreviewBatch: Decodable {
            struct Shot: Decodable { let name: String; let arguments: [String] }
            let output: String
            let appearance: String
            let reduceMotion: Bool
            let shots: [Shot]
        }

        private static var previewBatch: PreviewBatch?
        private static var previewNow = PlannerPreviewScenarios.referenceDate
        private static var previewReceipts: [[String: Any]] = []
        private static var preparedShot: String?
        static var activePreviewFixture: PlannerPreviewScenarios.Fixture?
        static var snapshotDate: Date? {
            previewBatch != nil || activePreviewFixture != nil ? previewNow : nil
        }

        static func previewOption(_ flag: String, in arguments: [String] = CommandLine.arguments) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        /// Validate targets before opening storage. Ordinary app launches remain unchanged.
        static func makePreviewStore() -> PlannerStore {
            do {
                if let target = previewOption("--open") { _ = try previewTarget(target) }
                if let name = previewOption("--appearance") {
                    NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
                }
                if let path = previewOption("--redesign-shots") {
                    let batch = try JSONDecoder().decode(
                        PreviewBatch.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                    guard batch.appearance == previewOption("--appearance"),
                        batch.reduceMotion == CommandLine.arguments.contains("--reduce-motion"),
                        batch.output.hasPrefix("/"), batch.output != "/", !batch.shots.isEmpty,
                        Set(batch.shots.map(\.name)).count == batch.shots.count
                    else { throw PlannerError("Invalid snapshot batch.") }
                    for shot in batch.shots {
                        guard shot.name.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil,
                            let target = previewOption("--open", in: shot.arguments), previewTargets[target] != nil,
                            previewOption("--scenario", in: shot.arguments) != nil
                        else { throw PlannerError("Unknown target or invalid shot: \(shot.name)") }
                        try AppLaunchConfiguration.validate(
                            arguments: shot.arguments, environment: ProcessInfo.processInfo.environment)
                        var index = 0
                        while index < shot.arguments.count {
                            guard ["--open", "--scenario"].contains(shot.arguments[index]) else {
                                throw PlannerError("Unsupported snapshot option.")
                            }
                            index += 2
                        }
                    }
                    previewBatch = batch
                }
                if previewBatch != nil
                    || previewOption("--scenario").map(PlannerPreviewScenarios.names.contains) == true
                {
                    if let name = previewOption("--scenario") {
                        previewNow = try PlannerPreviewScenarios.make(name).now
                    }
                    return PlannerStore(now: { previewNow }, watching: false)
                }
                return PlannerStore()
            } catch { previewFailure(error) }
        }

        static func previewFailure(_ error: Error) -> Never {
            FileHandle.standardError.write(Data("Perch preview: \(error)\n".utf8))
            exit(64)
        }

        /// Returns true when explicit preview navigation owns startup (and suppresses Welcome).
        func startPreviewIfRequested() -> Bool {
            let args = CommandLine.arguments
            if Self.previewBatch != nil {
                runPreviewShot(at: 0)
                return true
            }
            if args.contains("--demo") { seedDemo() }
            if let name = Self.previewOption("--scenario") { seedScenario(name) }
            if let target = Self.previewOption("--open"), let registration = Self.previewTargets[target] {
                DispatchQueue.main.async { registration.open(self) }
                return true
            }
            if args.contains("--preview-open") {
                let page = Self.previewOption("--page").flatMap(NotchPage.init(rawValue:))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.open(page: page, pinned: true) }
                return true
            }
            return false
        }

        private func runPreviewShot(at index: Int) {
            guard let batch = Self.previewBatch else { return }
            if index == batch.shots.count {
                do {
                    let url = URL(fileURLWithPath: batch.output).appendingPathComponent("result.json")
                    try JSONSerialization.data(withJSONObject: Self.previewReceipts, options: [.sortedKeys]).write(
                        to: url, options: .atomic)
                    NSApp.terminate(nil)
                } catch { Self.previewFailure(error) }
                return
            }
            let shot = batch.shots[index]
            do {
                for window in Array(WindowHost.windows.values) { window.close() }
                model.close()
                model.dismissActivity()
                model.editingTaskID = nil
                model.detailsTaskID = nil
                Self.preparedShot = nil
                let scenario = Self.previewOption("--scenario", in: shot.arguments)!
                let fixture = try PlannerPreviewScenarios.install(scenario, in: store.file)
                Self.activePreviewFixture = fixture
                Self.previewNow = fixture.now
                store.reloadFromDisk(external: false)
                guard store.planner == fixture.planner else {
                    throw PlannerError("Preview reload did not match the fixture.")
                }
                let target = Self.previewOption("--open", in: shot.arguments)!
                // Let closed-window notifications finish before reusing a registered host.
                DispatchQueue.main.async {
                    Self.previewTargets[target]!.open(self)
                    self.capturePreviewShot(shot, target: target, index: index, attempt: 0)
                }
            } catch { Self.previewFailure(error) }
        }

        private func capturePreviewShot(_ shot: PreviewBatch.Shot, target: String, index: Int, attempt: Int) {
            // Bounded settling includes real SwiftUI layout, without N application launches.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let batch = Self.previewBatch else { return }
                guard let (window, rect) = Self.previewTargets[target]?.surface(self),
                    let view = window.contentView, rect.width > 0, rect.height > 0
                else {
                    if attempt < 7 {
                        self.capturePreviewShot(shot, target: target, index: index, attempt: attempt + 1); return
                    }
                    Self.previewFailure(PlannerError("No visible surface for \(shot.name)."))
                }
                // Two settling passes keep the first frame of an opening animation out of the image.
                if attempt == 0 { self.capturePreviewShot(shot, target: target, index: index, attempt: 1); return }
                do {
                    let appearance =
                        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
                    guard appearance == batch.appearance else {
                        throw PlannerError("Snapshot appearance did not apply.")
                    }
                    if let text = Self.activePreviewFixture?.captureText, !text.isEmpty {
                        guard target == "today", let editor = window.firstResponder as? NSTextView, editor.isEditable
                        else {
                            if attempt < 7 {
                                self.capturePreviewShot(shot, target: target, index: index, attempt: attempt + 1);
                                return
                            }
                            throw PlannerError("Snapshot capture field did not become ready.")
                        }
                        if Self.preparedShot != shot.name {
                            editor.insertText(
                                text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                            Self.preparedShot = shot.name
                            self.capturePreviewShot(shot, target: target, index: index, attempt: attempt + 1)
                            return
                        }
                        guard editor.string == text else { throw PlannerError("Snapshot capture text did not apply.") }
                    }
                    let image = try Self.previewPNG(view: view, rect: rect)
                    try image.data.write(
                        to: URL(fileURLWithPath: batch.output).appendingPathComponent(shot.name + ".png"),
                        options: .atomic)
                    Self.previewReceipts.append([
                        "name": shot.name, "target": target, "scenario": Self.activePreviewFixture!.name,
                        "width": image.width, "height": image.height, "scale": 2,
                        "appearance": appearance, "reduceMotion": self.model.motionPolicy.reduceMotion,
                    ])
                    self.runPreviewShot(at: index + 1)
                } catch { Self.previewFailure(error) }
            }
        }

        struct PreviewPNG {
            let data: Data
            let width: Int
            let height: Int
        }

        static func previewPNG(view: NSView, rect: NSRect) throws -> PreviewPNG {
            let bounds = rect.integral
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                view.bounds.contains(bounds)
            else { throw PlannerError("Snapshot bounds are outside the visible surface.") }
            view.layoutSubtreeIfNeeded()
            let width = Int(bounds.width), height = Int(bounds.height)
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw PlannerError("Could not allocate snapshot.") }
            bitmap.size = bounds.size
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw PlannerError("Could not encode snapshot.")
            }
            return PreviewPNG(data: data, width: width, height: height)
        }

        private static func legacyPreview(_ name: String) throws -> PlannerPreview {
            switch name {
            case "empty": return .empty
            case "three": return .three
            case "timer": return .timer
            case "insights": return .insights
            default: throw PlannerError("Unknown preview scenario: \(name)")
            }
        }
        /// Sample day for screenshots (`--demo`), only into an empty planner.
        func seedDemo() {
            guard store.planner.tasks.isEmpty else { return }
            store.apply { e in
                let added = try e.addTasks([
                    "Draft release notes !high #launch for 50 min", "Call the bank at 4pm",
                    "Merge the auth branch #work",
                    "Water the plants every 3 days", "Plan team offsite friday", "Renew car registration next monday",
                    "Learn piano someday",
                ])
                _ = try e.complete(added[2].id)
                try e.writeNotepad(on: e.today, text: "Try batching email to 11 and 4\nQuestions for the design sync")
                _ = try e.startTimer(task: added[0].id, minutes: 50)
                try e.updatePrefs { $0.welcomeCompleted = true }
            }
        }

        /// Fixed planner states for CI snapshots (`--scenario <name>`), only into an empty planner.
        /// `empty`: nothing yet. `three`: three tasks for today. `timer`: the same with a focus session running.
        /// `insights`: two weeks of finished tasks and focus, for the Insights page.
        func seedScenario(_ name: String) {
            guard store.planner.tasks.isEmpty else { return }
            do {
                if PlannerPreviewScenarios.names.contains(name) {
                    guard store.planner.notes.isEmpty, store.planner.projects.isEmpty,
                        store.planner.focus == nil, store.planner.focusSegments.isEmpty
                    else { throw PlannerError("Preview initialization needs an empty planner.") }
                    let fixture = try PlannerPreviewScenarios.install(name, in: store.file)
                    Self.activePreviewFixture = fixture
                    store.reloadFromDisk(external: false)
                } else {
                    store.send(.seedPreview(try Self.legacyPreview(name)), origin: .background)
                }
            } catch { Self.previewFailure(error) }
        }
    }
#endif

extension View {
    @ViewBuilder
    func previewEnvironment() -> some View {
        #if DEBUG || PERCH_TESTING
            environment(\.motionPolicyOverride, MotionScript.policyOverride)
        #else
            self
        #endif
    }
}

/// Inert in distribution builds; the clock subtree opts in with one shared hook.
@MainActor
enum PreviewClock {
    static var date: Date? {
        #if DEBUG || PERCH_TESTING
            AppDelegate.snapshotDate
        #else
            nil
        #endif
    }
}

/// Explicit preview window appearance; fixed-fill surfaces retain their own ink schemes.
@MainActor
enum PreviewAppearance {
    static var scheme: ColorScheme? {
        #if DEBUG || PERCH_TESTING
            guard let name = AppDelegate.previewOption("--appearance") else { return nil }
            return name == "dark" ? .dark : .light
        #else
            nil
        #endif
    }
}
