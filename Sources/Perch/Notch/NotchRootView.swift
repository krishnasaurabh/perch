import PlannerCore
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
    private var activity: NotchActivity? { active ? model.activity : nil }

    var body: some View {
        let g = screen.geometry
        let window = g.window
        let timer = NotchModel.timerShowing(store)
        let shape = g.shape(expanded: expanded, timer: timer, activity: activity != nil)
        // Closed with only a timer: the hidden notch plus a separate capsule, drawn as two shapes.
        let pillSide: NotchTimerPlacement? = (!expanded && activity == nil) ? timer : nil
        // Beside a housing the open shell hangs from the top edge; on a flat screen it floats below the menu bar.
        // Same outline the controller hit-tests (`NotchGeometry.shapeContains`).
        let outline = g.outline(expanded: expanded)

        ZStack(alignment: .topLeading) {
            if let side = pillSide {
                TimerPillLayer(geometry: g, side: side, bounds: shape)
                    .frame(width: shape.width, height: shape.height, alignment: .topLeading)
                    .offset(x: shape.minX - window.minX, y: window.maxY - shape.maxY)
                    .transition(.opacity)
            } else {
            ZStack(alignment: .top) {
                // The open shell is drawn without a shadow.
                outline
                    .fill(Theme.notchBlack)

                Group {
                    if expanded {
                        // Normal mode scales/fades with the shell; reduced mode inserts at final geometry.
                        WorkspaceView(notchHeight: g.notchSize.height)
                            // Retain the disappearing content above the opaque shell during removal.
                            // Otherwise ZStack can draw its still-running transition behind the fill.
                            .zIndex(1)
                            .transition(motionPolicy.workspaceTransition)
                    } else {
                        ClosedNotchView(notch: g.notchSize, activity: activity)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, expanded ? 10 : 0)
            }
            .frame(width: shape.width, height: shape.height)
            .clipShape(outline)
            .contentShape(outline)
            .onDrop(of: [.fileURL, .url, .plainText, .image], isTargeted: nil) { providers in
                handleDrop(providers); return true
            }
            // The window is flush with the screen top; the shape is too, except an open workspace on a flat screen.
            .offset(x: shape.minX - window.minX, y: window.maxY - shape.maxY)
            }
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .ignoresSafeArea()
        .motion(expanded ? Motion.open : Motion.close, value: expanded)
        .motion(activity == nil ? Motion.activityDismiss : Motion.activity, value: activity)
        .preferredColorScheme(.dark)
        // Ink tokens resolve against the scheme: the shell is always "dark". Cards override it for themselves.
        .environment(\.colorScheme, .dark)
        .opacity(hidden ? 0 : 1)
        .motionBoundary()
    }

    /// Flat screen with "Draw a notch on external displays" off: nothing drawn until it opens or shows something there.
    private var hidden: Bool {
        !screen.geometry.hasHardwareNotch && !store.prefs.notchOnMonitors && !expanded && activity == nil
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

/// Closed state with a nudge: a strip below the notch. Nothing to show: nothing drawn beyond the housing.
struct ClosedNotchView: View {
    let notch: CGSize
    let activity: NotchActivity?

    var body: some View {
        VStack(spacing: 0) {
            if let a = activity {
                Spacer().frame(height: notch.height)
                // Mask reveal: the strip sits at its final size and the growing shape (clipped above) uncovers it.
                ActivityStrip(activity: a).padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }
}

/// Closed with a running timer: the notch stays hidden behind the hardware, and a black capsule beside it shows the
/// time in dot-matrix digits. No icon, no accent, no border: one piece of information.
struct TimerPillLayer: View {
    let geometry: NotchGeometry
    let side: NotchTimerPlacement
    let bounds: NSRect
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel

    var body: some View {
        let n = geometry.tuckedNotch, p = geometry.pill(side: side)
        ZStack(alignment: .topLeading) {
            geometry.outline(expanded: false).fill(Theme.notchBlack)
                .frame(width: n.width, height: n.height)
                .offset(x: n.minX - bounds.minX, y: bounds.maxY - n.maxY)
            Capsule(style: .continuous).fill(Theme.notchBlack)
                .overlay(digits(width: p.width, height: p.height))
                .frame(width: p.width, height: p.height)
                .offset(x: p.minX - bounds.minX, y: bounds.maxY - p.maxY)
        }
    }

    @ViewBuilder private func digits(width: CGFloat, height: CGFloat) -> some View {
        if let f = store.planner.focus, f.state != .finished {
            let text = TimerText.clock(f.remaining(at: model.now) ?? f.elapsed(at: model.now))
            DotMatrixText(text: text, dot: Self.dot(for: text, width: width - 24, height: height * 0.52),
                          color: Color.white.opacity(f.state == .running ? 0.95 : 0.6), unlit: .clear)
        }
    }

    /// Largest dot that fits the text in the capsule's inner box (glyphs are 3x5 dots; colons one dot wide).
    static func dot(for text: String, width: CGFloat, height: CGFloat) -> CGFloat {
        let colons = CGFloat(text.filter { $0 == ":" }.count), digits = CGFloat(text.count) - colons
        let units = digits * 3.9 + colons + CGFloat(max(0, text.count - 1)) * 1.2
        return max(1, min(width / units, height / 6.8, 2.2))
    }
}

/// Upcoming-event nudges, reminder rings, finished timers: with actions right in the notch.
struct ActivityStrip: View {
    let activity: NotchActivity
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services

    var body: some View {
        HStack(spacing: 10) {
            // Static reminder icon, without a swinging animation.
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(services.timeline.subtitle(for: activity, now: model.now)).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            actions
            GlassButton(symbol: "xmark", help: "Dismiss", size: 22) { model.dismissActivity() }
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
            pill("Start") {
                store.apply { try $0.startTimer(task: id.uuidString, minutes: nil) }
                model.dismissActivity()
            }
            pill("Snooze 5 min") { store.apply { try $0.snooze(id.uuidString, minutes: 5) }; model.dismissActivity() }
            pill("Done") { store.apply { try $0.complete(id.uuidString) }; model.dismissActivity() }
        case .focusDone(let id):
            if let id { pill("Mark done") { store.apply { try $0.complete(id.uuidString) }; model.dismissActivity() } }
            pill("+5 min") { store.apply { $0.extendTimer(minutes: 5) }; model.dismissActivity() }
        case .clip:
            pill("Open line") { model.dismissActivity(); model.open(page: .clips) }
        default: EmptyView()
        }
    }

    func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Theme.fill))
        }.buttonStyle(.plain)
    }
}
