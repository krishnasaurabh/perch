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
        let shell = expanded ? g.workspace : g.tuckedNotch
        let outline = g.outline(expanded: expanded)

        ZStack(alignment: .topLeading) {
            // Flat displays never draw a synthetic housing.
            if expanded || g.hasHardwareNotch {
                ZStack(alignment: .top) {
                    outline.fill(Theme.notchBlack)
                    if expanded {
                        WorkspaceView(notchHeight: g.notchSize.height)
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
                    LocalClock(running: closed.needsClock(hasHardwareNotch: g.hasHardwareNotch)) { now in
                        NotchClosedLayer(geometry: g, bounds: window, presentation: closed, now: now) {
                            model.activateClosed(in: store, on: screen)
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
    private func handleDrop(_ providers: [NSItemProvider]) { services.clips.acceptDrop(providers) }
}

/// Closed with a running timer: the notch stays hidden behind the hardware, and a black capsule beside it shows the
/// time in dot-matrix digits. No icon, no accent, no border: one piece of information.
struct TimerPillLayer: View {
    let geometry: NotchGeometry
    let side: NotchTimerPlacement
    let bounds: NSRect
    // Preserve the outgoing value during a dismiss transition after the live store clears it.
    let focus: FocusSession?

    var body: some View {
        let p = geometry.pill(side: side)
        Capsule(style: .continuous).fill(Theme.notchBlack)
            .overlay(digits(width: p.width, height: p.height))
            .frame(width: p.width, height: p.height)
            .offset(x: p.minX - bounds.minX, y: bounds.maxY - p.maxY)
    }

    @ViewBuilder private func digits(width: CGFloat, height: CGFloat) -> some View {
        if let f = focus, f.state != .finished {
            LocalClock(running: f.state == .running) { now in
                let face = NotchTimerPresentation(seconds: f.remaining(at: now) ?? f.elapsed(at: now))
                Group {
                    if face.usesDotMatrix {
                        DotMatrixText(
                            text: face.text, dot: Self.dot(for: face.text, width: width - 16, height: height * 0.68),
                            color: Color.white.opacity(f.state == .running ? 0.95 : 0.6), unlit: .clear)
                    } else {
                        Text(face.text).font(
                            .system(size: ThemeTokens.TypeSize.body, weight: .semibold, design: .monospaced)
                        )
                        .foregroundStyle(Color.white.opacity(f.state == .running ? 0.95 : 0.6))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    AppL10n.format(
                        "%@ timer, %@", AppL10n.text(f.state == .running ? "Running" : "Paused"), face.fullText)
                )
                .help(AppL10n.format("%@ %@", face.fullText, AppL10n.text(f.limit == nil ? "elapsed" : "remaining")))
            }
        }
    }

    /// Largest dot that fits the text in the capsule's inner box (glyphs are 3x5 dots; colons one dot wide).
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
