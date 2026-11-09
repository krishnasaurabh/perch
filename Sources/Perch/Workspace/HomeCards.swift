import PlannerCore
import SwiftUI

/// The focus timer: dot-matrix / digital / minimal faces, countdown or stopwatch, +5 min.
struct FocusCard: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var minutes = 25
    @State private var picking = false

    var body: some View {
        let f = store.planner.focus
        let active = f.map { $0.state != .finished } ?? false
        let task = f?.taskID.flatMap { id in store.planner.tasks.first { $0.id == id } }

        VStack(alignment: .leading, spacing: 10) {
            CardHeading("Focus", symbol: "timer", trailing: AnyView(styleMenu))
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                face(f)
                Text(active ? (task?.title ?? "Just focusing") : "Pick something to focus on")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(active ? Theme.text : Theme.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                if let f, active, let limit = f.limit {
                    ProgressView(value: min(1, f.elapsed(at: model.now) / limit))
                        .progressViewStyle(.linear).tint(Theme.accent).frame(width: 140)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            controls(f, active: active)
        }
        .card()
        .onAppear { minutes = store.prefs.defaultFocusMinutes }
    }

    @ViewBuilder func face(_ f: FocusSession?) -> some View {
        let secs: Double = {
            guard let f, f.state != .finished else { return Double(minutes * 60) }
            return f.remaining(at: model.now) ?? f.elapsed(at: model.now)
        }()
        let text = TimerText.clock(secs)
        let running = f?.state == .running
        switch store.prefs.workspaceTimerStyle {
        case .dotMatrix:
            DotMatrixText(text: text, dot: text.count > 5 ? 5 : 7, color: running ? Theme.accent : Theme.text.opacity(0.85))
        case .digital:
            Text(text).font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(running ? Theme.accent : Theme.text)
        case .minimal:
            Text(text).font(.system(size: 30, weight: .light).monospacedDigit()).foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder func controls(_ f: FocusSession?, active: Bool) -> some View {
        HStack(spacing: 8) {
            if active, let f {
                GlassButton(symbol: f.state == .running ? "pause.fill" : "play.fill",
                            help: f.state == .running ? "Pause timer" : "Continue timer", tint: Theme.accent, size: 30) {
                    store.apply { e in f.state == .running ? try e.pauseTimer() : try e.resumeTimer() }
                }
                if f.limit != nil { GlassButton(symbol: "goforward.5", help: "Extend by 5 min", size: 30) { store.apply { $0.extendTimer(minutes: 5) } } }
                GlassButton(symbol: "stop.fill", help: "Stop timer", size: 30) { store.apply { _ = $0.stopTimer() } }
                if let id = f.taskID {
                    GlassButton(symbol: "checkmark", help: "Mark done", tint: Theme.done, size: 30) { store.apply { try $0.complete(id.uuidString) } }
                }
            } else {
                Stepper(value: $minutes, in: 5...180, step: 5) {
                    Text("\(minutes) min").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                }
                .controlSize(.small)
                Spacer()
                Button("Start") { store.apply { try $0.startTimer(task: nil, minutes: minutes) } }.buttonStyle(PillStyle(prominent: true))
                Button { store.apply { $0.startStopwatch(taskID: nil) } } label: { Image(systemName: "stopwatch") }
                    .buttonStyle(PillStyle()).help("Count up with no limit")
            }
        }
        .frame(maxWidth: .infinity)
    }

    var styleMenu: some View {
        Menu {
            Picker("Timer face", selection: Binding(get: { store.prefs.workspaceTimerStyle }, set: { v in store.updatePrefs { $0.workspaceTimerStyle = v } })) {
                Text("Dot grid").tag(WorkspaceTimerStyle.dotMatrix)
                Text("Digital").tag(WorkspaceTimerStyle.digital)
                Text("Minimal").tag(WorkspaceTimerStyle.minimal)
            }
        } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// A daily notepad. Saves as you type. ⌘↩ turns the current line into a task.
struct NotepadCard: View {
    var day: DayKey?
    @EnvironmentObject var store: PlannerStore
    @State private var text = ""
    @State private var loadedFor: DayKey?
    @State private var saveWork: DispatchWorkItem?
    @State private var flash: String?

    var body: some View {
        let d = day ?? store.today
        let readOnly = d < store.today
        VStack(alignment: .leading, spacing: 8) {
            CardHeading("Notepad", symbol: "square.and.pencil", trailing: AnyView(
                Text(flash ?? "⌘↩ makes a task").font(.system(size: 9.5)).foregroundStyle(flash == nil ? Theme.tertiary : Theme.accent)))
            ScratchpadEditor(text: $text, isEditable: !readOnly, placeholder: "Jot a note", onCommandReturn: { line in
                let clean = line.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty, let t = store.apply({ try $0.lineToTask(clean, day: max(d, store.today)) }) ?? nil else { return }
                flash = "Added “\(t.title)”"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { flash = nil }
            })
        }
        .card()
        .onAppear { load(d) }
        .onChange(of: d) { _, nd in load(nd) }
        .onChange(of: store.planner.notes) { _, _ in
            // Reflect an agent's write_notepad unless the user is mid-edit.
            if saveWork == nil { let fresh = store.engine.notepad(on: d); if fresh != text { text = fresh } }
        }
        .onChange(of: text) { _, new in
            guard loadedFor == d, !readOnly, new != store.engine.notepad(on: d) else { return }
            saveWork?.cancel()
            let w = DispatchWorkItem { store.apply { $0.setNotepad(on: d, text: new) }; saveWork = nil }
            saveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        }
    }

    func load(_ d: DayKey) { text = store.engine.notepad(on: d); loadedFor = d }
}

/// NSTextView so ⌘↩ can read the line under the cursor.
struct ScratchpadEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var placeholder = ""
    var onCommandReturn: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12.5)
        tv.textColor = NSColor.white.withAlphaComponent(0.9)
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.string = text
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        let tv = v.documentView as! NSTextView
        tv.isEditable = isEditable
        if tv.string != text { tv.string = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadEditor
        init(_ p: ScratchpadEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            let ns = tv.string as NSString
            let line = ns.substring(with: ns.lineRange(for: tv.selectedRange()))
            parent.onCommandReturn(line.trimmingCharacters(in: .newlines))
            return true
        }
    }
}

/// Today's calendar events; completion is local to Perch, not synced to Calendar.
struct AgendaCard: View {
    @EnvironmentObject var services: Services
    var body: some View { AgendaBody(calendar: services.calendar) }
}

private struct AgendaBody: View {
    @ObservedObject var calendar: CalendarService
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeading("Schedule", symbol: "calendar")
            if !calendar.hasAccess {
                HStack {
                    Text("Allow calendar access to list today's events here.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }.buttonStyle(PillStyle())
                }
            } else {
                // Keep ended events available to check off (or reopen) for the rest of the day.
                let events = calendar.events
                if events.isEmpty {
                    Text("Your calendars are clear today.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(events) { e in
                                let completed = store.planner.completedCalendarEventIDs.contains(e.id)
                                HStack(spacing: 7) {
                                    Toggle(e.title, isOn: Binding(
                                        get: { store.planner.completedCalendarEventIDs.contains(e.id) },
                                        set: { value in
                                            store.apply { try $0.setCalendarEventCompleted(e.id, completed: value) }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .frame(width: 32, height: 32)
                                    .accessibilityLabel("Complete calendar event: \(e.title)")
                                    .help(completed ? "Mark incomplete in Perch" : "Mark complete in Perch (Calendar is unchanged)")
                                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: e.colorHex)).frame(width: 3)
                                        .opacity(completed ? 0.5 : 1)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                            .strikethrough(completed)
                                            .foregroundStyle(completed ? Theme.secondary : Theme.text)
                                        Text(e.allDay ? "All day" : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                            .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
                                .frame(width: 210, alignment: .leading)
                            }
                        }
                    }.scrollIndicators(.never)
                }
            }
        }
        .card(padding: 10)
    }
}

/// Small insights summary; the dashboard has the full charts.
struct InsightsCard: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        let i = store.engine.insights()
        VStack(alignment: .leading, spacing: 8) {
            CardHeading("Insights", symbol: "chart.bar", trailing: AnyView(
                Text("\(i.today.completedCalendarEvents) events done")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .help("Calendar events checked off in Perch today. \(i.allTimeCompletedCalendarEvents) all time.")
            ))
            HStack(spacing: 14) {
                stat("\(i.streak)", "day streak", "flame.fill")
                stat("\(i.today.completed)/\(i.today.planned)", "done today", "checkmark.circle")
                stat(TimerText.short(i.today.focusSeconds), "focused", "timer")
                Spacer()
                SparkBars(values: i.lastSeven.map { Double($0.completed) })
                    .frame(width: 90, height: 34)
            }
        }
        .card(padding: 10)
    }

    func stat(_ v: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.accent)
                Text(v).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
            }
            Text(label).font(.system(size: 9.5)).foregroundStyle(Theme.secondary)
        }
    }
}

struct SparkBars: View {
    let values: [Double]
    var body: some View {
        let m = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == values.count - 1 ? Theme.accent : Color.white.opacity(0.25))
                    .frame(height: max(3, CGFloat(v / m) * 34))
            }
        }
    }
}
