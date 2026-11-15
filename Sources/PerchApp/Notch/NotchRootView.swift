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

            if !expanded {
                if let activity {
                    ActivityStrip(activity: activity)
                        .padding(10)
                        .frame(width: g.activityRect.width, height: g.activityRect.height)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.notchBlack))
                        .onDrop(of: [.fileURL, .url, .plainText, .image], isTargeted: nil) { providers in
                            handleDrop(providers); return true
                        }
                        .offset(x: g.activityRect.minX - window.minX, y: window.maxY - g.activityRect.maxY)
                        .transition(.opacity)
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
        .motion(activity == nil ? Motion.activityDismiss : Motion.activity, value: activity)
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

    /// Files and images become file/image clips; links and text become text clips. Then Clips opens on this screen.
    private func handleDrop(_ providers: [NSItemProvider]) {
        let clips = services.clips
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in clips.add(.file(url), source: "dropped") } }
                }
            } else if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in clips.add(.text(url.absoluteString), source: "dropped") } }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s { Task { @MainActor in clips.add(.text(s), source: "dropped") } }
                }
            } else if p.hasItemConformingToTypeIdentifier("public.image") {
                p.loadDataRepresentation(forTypeIdentifier: "public.image") { d, _ in
                    if let d { Task { @MainActor in clips.add(.image(d), source: "dropped") } }
                }
            }
        }
        if model.screenID != screen.id {
            model.screenID = screen.id
            model.geometry = screen.geometry
        }
        model.open(page: .clips)
    }
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

/// Upcoming-event nudges, reminder rings, finished timers: with actions right in the notch.
struct ActivityStrip: View {
    let activity: PresentedNotchActivity
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services

    @State private var actionFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Theme.heading).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title).font(Theme.label).foregroundStyle(Theme.text).lineLimit(1)
                        .help(activity.title)
                    LocalClock(running: needsCountdown) { now in
                        // Read the notification owner's record while this short-lived card is visible.
                        // Never label an overdue timestamp alone as a missed notification.
                        Text(subtitle(at: now)).font(Theme.meta)
                            .foregroundStyle(actionFailed ? Theme.danger : Theme.secondary)
                            .lineLimit(1)
                            .help(actionFailed ? (store.lastError?.message ?? subtitle(at: now)) : subtitle(at: now))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassButton(symbol: "xmark", help: "Dismiss", size: Theme.minimumTarget) {
                    model.dismissPresentedActivity(in: store.planner)
                }
                .accessibilityIdentifier("notch.dismiss")
            }
            HStack(spacing: 6) {
                actions
                Spacer(minLength: 0)
            }
        }
        .onChange(of: activity.id) { _, _ in actionFailed = false }
    }

    private func subtitle(at now: Date) -> String {
        if actionFailed { return AppL10n.text("Action failed. Please try again.") }
        if case .reminder(let id) = activity.kind,
            NotchReminderPresentation.isMissed(
                task: store.planner.tasks.first { $0.id == id }, records: services.reminders.records, now: now)
        {
            return AppL10n.text("Missed reminder · delivery unconfirmed")
        }
        return services.timeline.subtitle(for: activity, now: now)
    }

    private var needsCountdown: Bool {
        switch activity.kind {
        case .eventSoon, .reminder: return true
        default: return false
        }
    }

    private var icon: String {
        switch activity.kind {
        case .reminder: return "bell.fill"
        case .focusDone: return "checkmark.seal.fill"
        case .eventSoon: return "calendar"
        case .clip: return "paperclip"
        case .message: return "sparkles"
        }
    }

    @ViewBuilder private var actions: some View {
        switch activity.kind {
        case .reminder(let id):
            pill("Start focus", identifier: "notch.start") {
                perform { try $0.startTimer(task: id, minutes: nil) }
            }
            pill("Snooze 5 min", identifier: "notch.snooze") {
                perform { try $0.snooze(id, minutes: 5) }
            }
            pill("Done", identifier: "notch.done") {
                perform { try $0.complete(id) }
            }
        case .focusDone(let id):
            if let id {
                pill("Mark done", identifier: "notch.done") {
                    perform { try $0.complete(id) }
                }
            }
            pill("+5 min", identifier: "notch.extend") {
                perform { try $0.extendTimer(minutes: 5) }
            }
        case .clip:
            pill("Open line", identifier: "notch.openClips") {
                model.dismissActivity(); model.open(page: .clips)
            }
        default: EmptyView()
        }
    }

    /// Keep failed actions visible, including failures flushing an in-progress edit.
    func perform<T>(_ action: (PlannerCommands) throws -> T) {
        actionFailed = !model.performActivityAction(in: store, action)
    }

    private func pill(_ title: String, identifier: String, _ action: @escaping () -> Void) -> some View {
        Button(AppL10n.text(title), action: action)
            .buttonStyle(PillStyle())
            .accessibilityIdentifier(identifier)
    }
}
