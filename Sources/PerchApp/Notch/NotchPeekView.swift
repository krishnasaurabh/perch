import AppKit
import PlannerCore
import PerchUI
import SwiftUI

/// Only the current action and a small capture field; explicit opening still reaches Today.
struct NotchPeekView: View {
    var bandHeight: CGFloat = .zero
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var draft = ""
    @State private var scheme: ColorScheme = .light
    @FocusState private var typing: Bool
    @FocusState private var blockFocused: Bool

    private var peek: NotchPeekPresentation { NotchPeekPresentation(planner: store.planner, today: store.today) }

    var body: some View {
        VStack(spacing: .zero) {
            Theme.band.frame(height: bandHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: NotchPeekLayout.gap) {
                    if peek.showsBlock {
                        current
                    } else {
                        Text("Nothing planned yet").perchFont(.body).foregroundStyle(Theme.ink2)
                    }
                    capture
                    HStack(spacing: .zero) {
                        Text(AppL10n.format("%lld more today", peek.moreToday))
                            .perchFont(.detail).foregroundStyle(Theme.ink2)
                        Spacer(minLength: .zero)
                        PerchButton("Click or ⌥N for everything", kind: .quiet, size: .small, surface: .sheet) {
                            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
                        }
                    }
                    if let error = store.lastError {
                        Text(error.message).perchFont(.detail).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(NotchPeekLayout.inset)
            }
            .background {
                Theme.sheet.overlay {
                    Canvas { context, size in
                        context.fill(DotGridSheet<EmptyView>.gridPath(in: size), with: .color(Theme.dot))
                    }
                    .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            .environment(\.designSurface, .sheet)
        }
        .frame(width: NotchPeekLayout.width)
        .environment(\.colorScheme, PreviewAppearance.scheme ?? scheme)
        .background(PeekAppearanceBridge { scheme = $0 }.allowsHitTesting(false))
        .onChange(of: typing) { _, value in
            if model.peeking && model.expanded { model.pinned = value }
        }
        .onKeyPress("p", phases: .down) { key in
            guard key.modifiers == .command, peek.focus != nil else { return .ignored }
            model.togglePeekBlock(in: store)
            return .handled
        }
        .onKeyPress("+", phases: .down) { key in
            guard key.modifiers.contains(.command), peek.focus != nil else { return .ignored }
            store.apply { try $0.extendTimer(minutes: 5) }
            return .handled
        }
        // Give the peek its own semantic group: an inherited container identifier must
        // not replace the time and action identifiers inside the scroll view.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notch.peek")
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: SurfaceMetrics.compactGap) {
            HStack(spacing: NotchPeekLayout.gap) {
                VStack(alignment: .leading, spacing: .zero) {
                    Text(peek.title).perchFont(.currentTask).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    LocalClock(running: peek.focus?.state == .running) { now in
                        Text(summary(peek.task, now: now)).perchFont(.detail).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let focus = peek.focus {
                    LocalClock(running: focus.state == .running) { now in
                        let time = NotchBlockTimePresentation(focus: focus, now: now)
                        VStack(spacing: .zero) {
                            Text(time.face.fullText)
                                .perchFont(.cardTitle).foregroundStyle(Theme.ink)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(time.valueDescription)
                        .accessibilityIdentifier("notch.peek.time")
                        .help(time.valueDescription)
                    }
                }
                blockButton
            }
            if let task = peek.task, let step = peek.nextStep {
                // TODO: t_314c0739 — use TaskStepRow when the checklist component reaches main.
                PeekStepRow(taskID: task.id, step: step)
            }
        }
        .padding(.horizontal, NotchPeekLayout.blockInset)
        .padding(.vertical, NotchPeekLayout.inset)
        .background(RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value).fill(Theme.butter))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value)
                .strokeBorder(Theme.edge(.butter), lineWidth: Theme.Size.cardEdge.value)
        )
        .environment(\.designSurface, .butter)
    }

    private var blockButton: some View {
        let title = peek.focus == nil ? "Start" : peek.focus?.state == .paused ? "Continue" : "Pause"
        return Button {
            model.togglePeekBlock(in: store)
        } label: {
            Group {
                if peek.focus == nil {
                    Text(AppL10n.text(title)).perchFont(.button)
                } else {
                    Image(systemName: peek.focus?.state == .paused ? "play.fill" : "pause.fill").perchFont(
                        .detailStrong)
                }
            }
            .foregroundStyle(Theme.onBrand)
            .frame(minWidth: Theme.Size.smallButtonHeight.value, minHeight: Theme.Size.smallButtonHeight.value)
            .padding(.horizontal, peek.focus == nil ? SurfaceMetrics.compactGap : .zero)
            .background(Capsule().fill(Theme.brandFill))
        }
        .buttonStyle(PeekBlockButtonStyle())
        .focusable().focused($blockFocused).focusEffectDisabled()
        .overlay(FocusRing(shape: Capsule(), focused: blockFocused, surface: .butter))
        .accessibilityLabel(AppL10n.text(title))
        .accessibilityIdentifier("notch.peek.block")
    }

    private var capture: some View {
        HStack(spacing: NotchPeekLayout.gap) {
            Image(systemName: "plus").perchFont(.body).foregroundStyle(Theme.ink2).accessibilityHidden(true)
            PerchField("Add a task, or park a thought", text: $draft, focus: $typing) {
                submit(park: NSEvent.modifierFlags.contains(.command))
            }
            .onKeyPress(.return, phases: .down) { key in
                guard key.modifiers == .command else { return .ignored }
                submit(park: true)
                return .handled
            }
        }
        .padding(.horizontal, NotchPeekLayout.blockInset)
        .frame(minHeight: Theme.Size.addFieldHeight.value)
        .background(RoundedRectangle(cornerRadius: Theme.Size.addFieldRadius.value).fill(Theme.paper))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Size.addFieldRadius.value)
                .strokeBorder(Theme.edge(.paper), lineWidth: Theme.Size.cardEdge.value))
    }

    private func submit(park: Bool = false) {
        if model.submitPeek(draft, park: park, in: store) { draft = "" }
    }

    private func summary(_ task: PlanTask?, now: Date) -> String {
        var bits: [String] = []
        if let focus = peek.focus {
            if focus.state == .paused {
                bits.append(AppL10n.text("Paused"))
            } else if let remaining = focus.remaining(at: now) {
                let end = now.addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
                bits.append(AppL10n.format("Until %@", end))
            }
        } else if let start = task?.startAt {
            bits.append(start.formatted(date: .omitted, time: .shortened))
        }
        if let task, !task.steps.isEmpty {
            bits.append(AppL10n.format("%lld of %lld steps", task.steps.filter(\.done).count, task.steps.count))
        }
        return bits.joined(separator: " · ")
    }
}

private struct PeekBlockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.perchControlFeedback(pressed: configuration.isPressed)
    }
}

private struct PeekStepRow: View {
    let taskID: UUID
    let step: Subtask
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        HStack(spacing: SurfaceMetrics.gap) {
            PerchCheckbox(
                title: step.title,
                isOn: Binding(
                    get: { step.done },
                    set: { value in
                        store.updateTask(taskID) { task in
                            if let index = task.steps.firstIndex(where: { $0.id == step.id }) {
                                task.steps[index].done = value
                            }
                        }
                    }), kind: .step, surface: .paper)
            Text(step.title).perchFont(.button).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: .zero)
            Text("next step").perchFont(.detail).foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, SurfaceMetrics.gap)
        .frame(minHeight: Theme.Size.stepRowHeight.value)
        .background(RoundedRectangle(cornerRadius: SurfaceMetrics.gap).fill(Theme.paper))
    }
}

@MainActor
extension NotchModel {
    @discardableResult
    func submitPeek(_ input: String, park: Bool = false, in store: PlannerStore) -> Bool {
        guard let capture = NotchPeekCapture(input, park: park) else { return false }
        switch capture {
        case .task(let text): return store.addTasks([text], on: .day(store.today)) != nil
        case .thought(let text): return store.apply { try $0.parkThought(text) } != nil
        }
    }

    func togglePeekBlock(in store: PlannerStore) {
        let peek = NotchPeekPresentation(planner: store.planner, today: store.today)
        if let focus = peek.focus {
            store.apply { if focus.state == .paused { try $0.resumeTimer() } else { try $0.pauseTimer() } }
        } else if let task = peek.task {
            store.apply { try $0.startTimer(task: task.id, minutes: task.minutes ?? store.prefs.defaultFocusMinutes) }
        }
    }
}

private struct PeekAppearanceBridge: NSViewRepresentable {
    let changed: (ColorScheme) -> Void
    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView(); view.changed = changed; return view
    }
    func updateNSView(_ view: AppearanceView, context: Context) { view.changed = changed; view.refresh() }
    final class AppearanceView: NSView {
        var changed: ((ColorScheme) -> Void)?
        private var last: ColorScheme?
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
        func refresh() {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value: ColorScheme = dark ? .dark : .light
            guard value != last else { return }
            last = value
            DispatchQueue.main.async { [weak self] in self?.changed?(value) }
        }
    }
}

#if DEBUG || PERCH_TESTING
    extension AppDelegate.PreviewTarget {
        static func tasklessPeek(stopwatch: Bool, empty: Bool = false) -> Self {
            .window("notch-peek-preview") { app in
                guard let fixture = AppDelegate.activePreviewFixture else { return }
                do {
                    try PlannerPreviewScenarios.installTasklessBlock(
                        fixture, in: app.store.file, stopwatch: stopwatch, empty: empty)
                    app.store.reloadFromDisk(external: false)
                    Self.peek.open(app)
                } catch {
                    preconditionFailure("Could not prepare block preview: \(error)")
                }
            }
        }

        static var peek: Self {
            .window("notch-peek-preview") { app in
                WindowHost.show(
                    "notch-peek-preview", title: "Perch",
                    size: CGSize(width: NotchPeekLayout.width, height: NotchPeekLayout.contentHeight)
                ) {
                    NotchPeekView().environmentObject(app.store).environmentObject(app.model)
                        .motionDiagnostics(model: app.model)
                }
            }
        }
    }
#endif
