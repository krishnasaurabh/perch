import PlannerCore
import PerchUI
import SwiftUI

/// Everything drawn inside one screen's notch window: the closed silhouette (timer, nudges) and, on the active
/// screen, the expanded workspace. The window is fixed; the shape is placed at the frame `NotchLayout` computed.
struct NotchRootView: View {
    static var expandedSize: CGSize { NotchGeometry.workspaceSize }

    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services
    @EnvironmentObject var screen: NotchScreenState
    @Environment(\.motionPolicy) private var motionPolicy

    private var active: Bool { model.screenID == screen.id }
    private var expanded: Bool { active && model.expanded }
    private var activity: PresentedNotchActivity? { active ? model.displayedActivity : nil }

    var body: some View {
        let g = screen.geometry
        let window = g.window
        let closed = model.closed(in: store, screenID: screen.id)
        let shell =
            expanded
            ? (model.peeking
                ? NotchPeekLayout.frame(workspace: g.workspace, bandHeight: g.notchSize.height) : g.workspace)
            : g.tuckedNotch
        let outline = g.outline(expanded: expanded)

        ZStack(alignment: .topLeading) {
            // Flat displays never draw a synthetic housing.
            if expanded || g.hasHardwareNotch {
                ZStack(alignment: .top) {
                    outline.fill(Theme.notchBlack)
                    if expanded {
                        Group {
                            if model.peeking {
                                NotchPeekView(bandHeight: g.notchSize.height)
                            } else {
                                WorkspaceView(notchHeight: g.notchSize.height)
                            }
                        }
                        // Keep outgoing content above the shell during removal.
                        .zIndex(1)
                        .transition(motionPolicy.workspaceTransition)
                        .padding(.horizontal, .zero)
                    }
                }
                .frame(width: shell.width, height: shell.height)
                .clipShape(outline)
                .contentShape(outline)
                .onDrop(of: [.fileURL, .url, .plainText, .image], isTargeted: nil) { providers in
                    handleDrop(providers); return true
                }
                .offset(x: shell.minX - window.minX, y: window.maxY - shell.maxY)
                .designMotion(.pop, value: shell.width)
            }

            if !expanded || activity != nil {
                if let activity {
                    NotchStripLayer(activity: activity)
                } else {
                    LocalClock(
                        running: store.prefs.notchNextBlock || closed.needsClock(hasHardwareNotch: g.hasHardwareNotch)
                    ) { now in
                        NotchPrivacyClosedLayer(
                            geometry: g, bounds: window, presentation: closed, now: now,
                            hideValues: store.prefs.hideCountsAndTimes
                        ) {
                            model.activateClosed(in: store, on: screen)
                        }
                        if g.hasHardwareNotch {
                            let pills = model.pills(in: store, now: now)
                            NotchPills(
                                pills: pills,
                                frames: NotchPillLayout.frames(
                                    pills: pills, housing: g.notchRect, placement: store.prefs.notchTimerPlacement),
                                bounds: window
                            ) { model.peek(on: screen) }
                        }
                    }
                    .designMotion(.hover, value: closed)
                }
            }
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .ignoresSafeArea()
        .motion(expanded ? Motion.open : Motion.close, value: expanded)
        .designMotion(activity == nil ? .hover : .pop, value: activity)
        .preferredColorScheme(PreviewAppearance.scheme ?? .dark)
        // Ink tokens resolve against the scheme: the shell is always "dark". Cards override it for themselves.
        .environment(\.colorScheme, .dark)
        .opacity(hidden ? 0 : 1)
        .motionBoundary()
    }

    /// No housing and no enabled drawn notch: nothing until it opens or shows something there.
    private var hidden: Bool {
        let closed = model.closed(in: store, screenID: screen.id)
        return !screen.geometry.hasHardwareNotch && !closed.hasBlock && !closed.reminder
            && !expanded && activity == nil
    }

    /// Explicit drops are the only way content enters the shelf.
    private func handleDrop(_ providers: [NSItemProvider]) {
        if model.screenID != screen.id { model.close(); model.screenID = screen.id; model.geometry = screen.geometry }
        services.clips.acceptDrop(providers)
    }
}

/// Compatibility surface for timer-only callers; live side pills use the portable layout.
struct TimerPillLayer: View {
    let geometry: NotchGeometry
    let side: NotchTimerPlacement
    let bounds: NSRect
    let focus: FocusSession?

    var body: some View {
        let rect = geometry.pill(side: side)
        if let focus, focus.state != .finished {
            LocalClock(running: focus.state == .running) { now in
                let time = NotchBlockTimePresentation(focus: focus, now: now)
                NotchPillFace(text: time.face.text, showsDot: focus.state == .running, paused: focus.state == .paused)
                    .frame(width: rect.width, height: rect.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(time.accessibilityLabel)
                    .help(time.accessibilityLabel)
                    .offset(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY)
            }
        }
    }

    static func dot(for text: String, width: CGFloat, height: CGFloat) -> CGFloat {
        NotchTimerPresentation.dot(for: text, width: width, height: height)
    }
}

/// A single actionable occurrence. Failures leave the same strip available.
struct ActivityStrip: View {
    let activity: PresentedNotchActivity
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var services: Services
    @EnvironmentObject private var model: NotchModel
    @State private var actionFailed = false
    @State private var confirmingRestore = false
    @State private var scheme: ColorScheme = .light

    var body: some View {
        VStack(spacing: .zero) {
            if activity.stripKind == .dropShelf {
                DropShelf(clips: services.clips)
            } else {
                NotchStripClock(
                    running: activity.stripKind == .undo || activity.eventStart != nil,
                    interval: activity.eventStart == nil
                        ? NotchStripMetrics.clockInterval : NotchStripMetrics.countdownInterval
                ) { date in
                    NotchStripContent(
                        activity: activity.updatingTime(at: date),
                        fraction: model.strips?.fraction(at: date) ?? 1,
                        action: { choice in
                            actionFailed = !(model.strips?.answer(choice, activity: activity) ?? false)
                        },
                        showFiles: { model.strips?.showRecoveryFiles() },
                        restore: { confirmingRestore = true })
                }
            }
            if actionFailed {
                Text(AppL10n.text("That change couldn't be saved. Please try again."))
                    .perchFont(.detail).foregroundStyle(Theme.ink2)
                    .padding(NotchStripMetrics.gap).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fill(activity.stripKind.surface))
            }
        }
        .environment(\.colorScheme, PreviewAppearance.scheme ?? scheme)
        .background(StripAppearanceBridge { scheme = $0 }.allowsHitTesting(false))
        .onChange(of: activity.id) { _, _ in actionFailed = false }
        .confirmationDialog(AppL10n.text("Restore the latest backup?"), isPresented: $confirmingRestore) {
            Button(AppL10n.text("Restore backup")) { actionFailed = !(model.strips?.restoreBackup() ?? false) }
            Button(AppL10n.text("Not now"), role: .cancel) {}
        } message: {
            Text(AppL10n.text("This replaces the current planner. The original recovery files are kept."))
        }
    }
}
