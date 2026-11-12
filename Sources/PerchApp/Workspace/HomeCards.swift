import PlannerCore
import PerchUI
import SwiftUI

/// The running focus timer, on the lavender time card. On Today it appears only while a session is active.
struct FocusCard: View {
    @EnvironmentObject var store: PlannerStore
    @State private var minutes = 25

    var body: some View {
        let f = store.planner.focus
        let active = f.map { $0.state != .finished } ?? false
        let task = f?.taskID.flatMap { id in store.planner.tasks.first { $0.id == id } }

        VStack(alignment: .leading, spacing: 10) {
            CardHeading(
                active ? (task?.title ?? AppL10n.text("Just focusing")) : AppL10n.text("Focus"),
                trailing: AnyView(styleMenu))
            // When the timer is the only card beside the tasks it fills the column; the face centres in it.
            Spacer(minLength: 0)
            LocalClock(running: f?.state == .running) { now in
                VStack(spacing: 6) {
                    face(f, at: now)
                    if let f, active {
                        Text(status(f)).font(Theme.meta).foregroundStyle(Theme.secondary)
                        if let limit = f.limit {
                            FocusProgress(fraction: min(1, f.elapsed(at: now) / limit)).frame(width: 150)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            controls(f, active: active)
        }
        .card(.timer)
        .onAppear { minutes = store.prefs.defaultFocusMinutes }
    }

    private func status(_ f: FocusSession) -> String {
        if f.state == .paused { return AppL10n.text("Paused") }
        return f.limit == nil ? AppL10n.text("Elapsed") : AppL10n.text("Remaining")
    }

    @ViewBuilder func face(_ f: FocusSession?, at now: Date) -> some View {
        let secs: Double = {
            guard let f, f.state != .finished else { return Double(minutes * 60) }
            return f.remaining(at: now) ?? f.elapsed(at: now)
        }()
        let text = TimerText.clock(secs)
        let dim = f?.state == .paused
        switch store.prefs.workspaceTimerStyle {
        case .digital:
            // The default face: the 32 pt semibold timer token with monospaced digits, so the value reads at a glance
            // and the digits don't shift as they tick.
            Text(text).font(.system(size: 32, weight: .semibold).monospacedDigit())
                .foregroundStyle(dim ? Theme.secondary : Theme.text)
        case .dotMatrix:
            // Opt-in: decorative, and harder to read at a glance.
            DotMatrixText(text: text, dot: text.count > 5 ? 4.5 : 6.5, color: dim ? Theme.secondary : Theme.accent)
        case .minimal:
            Text(text).font(.system(size: 30, weight: .light).monospacedDigit()).foregroundStyle(
                dim ? Theme.secondary : Theme.text)
        }
    }

    @ViewBuilder func controls(_ f: FocusSession?, active: Bool) -> some View {
        HStack(spacing: 8) {
            if active, let f {
                let running = f.state == .running
                Button {
                    store.apply { e in running ? try e.pauseTimer() : try e.resumeTimer() }
                } label: {
                    Label(
                        AppL10n.text(running ? "Pause" : "Continue"), systemImage: running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PillStyle(prominent: true))
                .help(AppL10n.text(running ? "Pause timer" : "Continue timer"))
                if f.limit != nil {
                    GlassButton(symbol: "goforward.5", help: "Add five minutes", size: 26) {
                        store.apply { try $0.extendTimer(minutes: 5) }
                    }
                }
                GlassButton(symbol: "stop.fill", help: "End focus session", size: 26) {
                    store.apply { _ = try $0.stopTimer() }
                }
                if let id = f.taskID {
                    GlassButton(symbol: "checkmark", help: "Mark done", tint: Theme.done, size: 26) {
                        store.apply { try $0.complete(id) }
                    }
                }
            } else {
                Stepper(value: $minutes, in: 5...180, step: 5) {
                    Text(AppL10n.format("%lld min", minutes)).font(
                        .system(size: 11.5, weight: .semibold).monospacedDigit())
                }
                .controlSize(.small)
                Spacer()
                Button("Start") { store.apply { try $0.startTimer(task: nil, minutes: minutes) } }.buttonStyle(
                    PillStyle(prominent: true))
                Button {
                    store.apply { try $0.startStopwatch(taskID: nil) }
                } label: {
                    Image(systemName: "stopwatch")
                }
                .buttonStyle(PillStyle()).help("Count up with no limit")
            }
        }
        .frame(maxWidth: .infinity)
    }

    var styleMenu: some View {
        Menu {
            Picker(
                "Timer face",
                selection: Binding(
                    get: { store.prefs.workspaceTimerStyle },
                    set: { v in store.updatePrefs { $0.workspaceTimerStyle = v } })
            ) {
                Text("Digital").tag(WorkspaceTimerStyle.digital)
                Text("Minimal").tag(WorkspaceTimerStyle.minimal)
                Text("Dot grid").tag(WorkspaceTimerStyle.dotMatrix)
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Timer face")
    }
}

/// Thin token-drawn progress track: the native linear ProgressView all but vanishes on the lavender card.
struct FocusProgress: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chartPlanned)
                Capsule().fill(Theme.text).frame(width: max(4, g.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Focus progress")
        .accessibilityValue(AppL10n.format("%lld percent", Int(fraction * 100)))
    }
}

/// A daily notepad. Saves as you type. ⌘↩ turns the current line into a task. Off by default on Today.
struct NotepadCard: View {
    var day: DayKey?
    @EnvironmentObject var store: PlannerStore
    @FocusState private var editing: Bool
    @State private var flash: String?

    var body: some View {
        let d = day ?? store.today
        let readOnly = d < store.today
        VStack(alignment: .leading, spacing: 8) {
            CardHeading(
                AppL10n.text("Notepad"),
                trailing: AnyView(
                    Text(flash ?? AppL10n.text("⌘↩ makes a task")).font(Theme.meta).foregroundStyle(
                        flash == nil ? Theme.tertiary : Theme.accent)))
            ScratchpadEditor(
                text: Binding(
                    get: { store.text(for: .notepad(d)) },
                    set: { store.setText($0, for: .notepad(d)) }), isEditable: !readOnly, placeholder: "Jot a note",
                surface: CardTone.tile.fill,
                onCommandReturn: { line in
                    let clean = line.trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty,
                        let t = store.addTasks([clean], on: .day(max(d, store.today)))?.first
                    else { return }
                    flash = AppL10n.format("Added “%@”", t.title)
                }, onEndEditing: { store.flushPendingText() }
            )
            .focused($editing)
        }
        .card(.tile)
        .task(id: flash) {
            guard flash != nil else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            if !Task.isCancelled { flash = nil }
        }
        .onChange(of: d) { _, _ in store.flushPendingText() }
        .onChange(of: editing) { _, active in if !active { store.flushPendingText() } }
        .onDisappear { store.flushPendingText() }
    }
}

/// NSTextView so ⌘↩ can read the line under the cursor. Lives on a dark tile, so its ink is white.
struct ScratchpadEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var placeholder = ""
    /// The surface the editor sits on. Overflow fades into this colour, so it must be the card's own fill token.
    var surface: Color = CardTone.tile.fill
    var onCommandReturn: (String) -> Void
    var onEndEditing: () -> Void = {}

    /// Height of the bottom fade drawn over overflowing text.
    static let fadeHeight: CGFloat = 24

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        // Text running past the bottom edge fades into the card instead of being cut mid-glyph. The fade is an AppKit
        // view drawn over the clip view (a SwiftUI mask doesn't reach into this NSScrollView on every macOS), and it
        // shows only while there is more text below the visible area.
        let fade = OverflowFadeView(frame: NSRect(x: 0, y: 0, width: scroll.bounds.width, height: Self.fadeHeight))
        fade.autoresizingMask = [.width]
        fade.color = NSColor(surface)
        fade.isHidden = true
        scroll.addSubview(fade, positioned: .above, relativeTo: scroll.contentView)
        context.coordinator.fade = fade
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12.5)
        tv.textColor = NSColor.white.withAlphaComponent(0.9)
        tv.insertionPointColor = NSColor(Theme.owl)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.string = text
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        let tv = v.documentView as! NSTextView
        tv.isEditable = isEditable
        if tv.string != text { tv.string = text }
        context.coordinator.parent = self
        context.coordinator.fade?.color = NSColor(surface)
        context.coordinator.refreshFade()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadEditor
        weak var fade: OverflowFadeView?
        weak var scroll: NSScrollView?
        init(_ p: ScratchpadEditor) { parent = p }
        deinit { NotificationCenter.default.removeObserver(self) }

        /// Re-check overflow whenever the text grows or shrinks, the card resizes, or the user scrolls.
        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            let nc = NotificationCenter.default
            nc.addObserver(
                self, selector: #selector(viewChanged), name: NSView.boundsDidChangeNotification, object: clip)
            nc.addObserver(
                self, selector: #selector(viewChanged), name: NSView.frameDidChangeNotification, object: clip)
            nc.addObserver(
                self, selector: #selector(viewChanged), name: NSView.frameDidChangeNotification,
                object: scroll.documentView)
            refreshFade()
        }

        @objc private func viewChanged(_ n: Notification) { refreshFade() }

        /// Pin the fade to the visible bottom edge and show it only while text continues below that edge.
        func refreshFade() {
            guard let scroll, let fade, let doc = scroll.documentView else { return }
            let h = min(ScratchpadEditor.fadeHeight, scroll.bounds.height)
            fade.frame = NSRect(
                x: 0, y: scroll.isFlipped ? scroll.bounds.height - h : 0, width: scroll.bounds.width, height: h)
            let visible = scroll.contentView.bounds
            fade.isHidden = !EdgeFade.showsBottomFade(
                contentHeight: Double(doc.frame.height),
                visibleOffset: Double(visible.minY),
                visibleHeight: Double(visible.height))
        }

        func textDidEndEditing(_ n: Notification) { parent.onEndEditing() }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            refreshFade()
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)),
                NSApp.currentEvent?.modifierFlags.contains(.command) == true
            else { return false }
            let ns = tv.string as NSString
            let line = ns.substring(with: ns.lineRange(for: tv.selectedRange()))
            parent.onCommandReturn(line.trimmingCharacters(in: .newlines))
            return true
        }
    }
}

/// A ramp from clear to the card's surface colour, drawn over the bottom of the notepad's scroll view. It is a plain
/// drawn view (not a layer mask), so it also shows in the in-process `--snapshot` renders, and it never takes clicks.
final class OverflowFadeView: NSView {
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); clipsToBounds = true }
    required init?(coder: NSCoder) { super.init(coder: coder); clipsToBounds = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // A linear gradient paints an unbounded strip, and views don't clip to bounds by default since macOS 14,
            // so clip explicitly or the ramp bleeds across neighbouring cards.
            NSBezierPath(rect: bounds).addClip()
            // Flipped: transparent at the top (y = 0), the full surface colour at the bottom edge.
            NSGradient(starting: color.withAlphaComponent(0), ending: color)?
                .draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: bounds.height), options: [])
        }
    }
}

/// Today's calendar events. Checking one off is local to Perch; Calendar is unchanged. On Today the card appears only
/// when there are events left today.
struct AgendaCard: View {
    @EnvironmentObject var services: Services
    var body: some View { AgendaBody(calendar: services.calendar) }
}

private struct AgendaBody: View {
    @ObservedObject var calendar: CalendarService
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeading(AppL10n.text("Today's agenda"))
            if !calendar.hasAccess {
                Text("Allow calendar access to list today's events here.").font(Theme.meta).foregroundStyle(
                    Theme.secondary)
                Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }.buttonStyle(PillStyle())
            } else {
                // Ended events stay listed so they can still be checked off (or reopened) for the rest of the day.
                let events = calendar.events
                if events.isEmpty {
                    Text("Nothing else on the calendar today.").font(Theme.meta).foregroundStyle(Theme.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(events.prefix(4)) { e in
                            let completed = store.planner.completedCalendarEventIDs.contains(e.id)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Toggle(
                                    e.title,
                                    isOn: Binding(
                                        get: { store.planner.completedCalendarEventIDs.contains(e.id) },
                                        set: { value in
                                            store.apply { try $0.setCalendarEventCompleted(e.id, completed: value) }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .accessibilityLabel(AppL10n.format("Complete calendar event: %@", e.title))
                                .help(
                                    completed
                                        ? "Mark incomplete in Perch" : "Mark complete in Perch (Calendar is unchanged)")
                                Text(
                                    e.allDay
                                        ? AppL10n.text("All day")
                                        : e.start.formatted(date: .omitted, time: .shortened)
                                )
                                .font(Theme.meta.monospacedDigit()).foregroundStyle(Theme.secondary)
                                .frame(width: 58, alignment: .leading)
                                Text(e.title).font(Theme.title).lineLimit(1)
                                    .strikethrough(completed)
                                    .foregroundStyle(completed ? Theme.secondary : Theme.text)
                            }
                        }
                        if events.count > 4 {
                            Text(AppL10n.format("+%lld more", events.count - 4))
                                .font(Theme.meta).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
        }
        .card(.timer)
    }
}
