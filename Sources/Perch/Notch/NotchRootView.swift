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
        let shape = g.shape(expanded: expanded, timer: NotchModel.timerShowing(store), activity: activity != nil)
        // Beside a housing the open shell hangs from the top edge; on a flat screen it floats below the menu bar.
        // Same outline the controller hit-tests (`NotchGeometry.shapeContains`).
        let outline = g.outline(expanded: expanded)

        ZStack(alignment: .topLeading) {
            ZStack(alignment: .top) {
                // The open shell is drawn without a shadow.
                outline
                    .fill(Theme.notchBlack)

                Group {
                    if expanded {
                        // Normal mode scales/fades with the shell; reduced mode inserts at final geometry.
                        WorkspaceView(notchHeight: g.notchSize.height)
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
        .frame(width: window.width, height: window.height, alignment: .topLeading)
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

/// Closed state: owl on the left wing, running timer (or open-task count) on the right, nudges below.
/// The middle gap is exactly the notch, so the wings sit beside the camera housing.
struct ClosedNotchView: View {
    let notch: CGSize
    let activity: NotchActivity?
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                wing(left: true)
                Spacer().frame(width: notch.width)
                wing(left: false)
            }
            .frame(height: notch.height)

            // Mask reveal: the strip sits at its final size and the growing shape (clipped above) uncovers it.
            if let a = activity {
                ActivityStrip(activity: a).padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder func wing(left: Bool) -> some View {
        let placement = store.prefs.notchTimerPlacement
        let focus = store.planner.focus.flatMap { $0.state == .finished ? nil : $0 }
        let showTimer = focus != nil && placement != .hidden && (placement == .left) == left
        HStack(spacing: 5) {
            if showTimer, let f = focus {
                Circle().fill(f.state == .running ? Theme.accent : Theme.secondary).frame(width: 6, height: 6)
                Text(TimerText.clock(f.remaining(at: model.now) ?? f.elapsed(at: model.now)))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(f.state == .running ? Theme.text : Theme.secondary)
            } else if left {
                OwlMark(size: 16, awake: true)
            } else {
                let open = store.engine.tasks(on: .day(store.today)).filter { !$0.done }.count
                if open > 0 {
                    Text("\(open)").font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
        // Clear the concave shoulder (topRadius) so content never touches the visible edge.
        .padding(.horizontal, 8 + NotchGeometry.radii(expanded: false).top)
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
