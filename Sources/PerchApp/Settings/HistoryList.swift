import AppKit
import PerchUI
import PlannerCore
import SwiftUI

struct HistoryList: View {
    @EnvironmentObject var store: PlannerStore
    @State private var query = ""
    @State private var agentFilter: String?
    var body: some View {
        let history = store.planner.tasks.filter { ($0.day.map { $0 < store.today } ?? false) }
        let agents = Array(Set(history.compactMap(\.agentID))).sorted()
        let past = history.filter { agentFilter == nil || $0.agentID == agentFilter }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let groups = Dictionary(grouping: past, by: { $0.day! }).sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                DashboardHistorySearch(query: $query).frame(width: 280, height: 24)
                Picker("Agent", selection: $agentFilter) {
                    Text("All agents").tag(String?.none)
                    ForEach(agents, id: \.self) { name in
                        Text(AgentName.short(name) ?? name).tag(String?.some(name))
                    }
                }.frame(width: 150)
            }
            if groups.isEmpty {
                Text(
                    AppL10n.text(query.isEmpty ? "Finished days show up here." : "No matches. Change the search text.")
                )
                .foregroundStyle(Theme.secondary)
            }
            ForEach(groups, id: \.key) { day, tasks in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(day.date().formatted(.dateTime.weekday(.wide).month().day())).font(Theme.heading)
                        Text(AppL10n.format("%lld/%lld done", tasks.filter(\.done).count, tasks.count)).foregroundStyle(
                            Theme.secondary)
                    }
                    ForEach(tasks) { t in DashboardTaskLine(task: t) }
                    let note = store.engine.notepad(on: day)
                    if !note.isEmpty {
                        Text(note).font(Theme.body).foregroundStyle(Theme.secondary).padding(.leading, 22)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A native search editor whose Tab commands use the dashboard's explicit
/// key-view links instead of being swallowed by the SwiftUI field editor.
struct DashboardHistorySearch: NSViewRepresentable {
    @Binding var query: String

    func makeNSView(context: Context) -> DashboardSearchField {
        let field = DashboardSearchField()
        field.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
        field.placeholderString = AppL10n.text("Search history")
        field.setAccessibilityLabel(AppL10n.text("Search history"))
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: ThemeTokens.TypeSize.body)
        field.focusRingType = .exterior
        return field
    }

    func updateNSView(_ field: DashboardSearchField, context: Context) {
        field.onChange = { query = $0 }
        if field.stringValue != query { field.stringValue = query }
    }
}

final class DashboardSearchField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    private var navigationMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let navigationMonitor { NSEvent.removeMonitor(navigationMonitor) }
        navigationMonitor = nil
        guard window != nil else { return }
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleNavigation(event) ?? false }
            return handled ? nil : event
        }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            DashboardKeyLoop.install(in: window)
        }
    }

    /// SwiftUI's hosting responder can consume Tab before the text delegate.
    /// Consume only this field's navigation, never text or another window's keys.
    func handleNavigation(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48, !event.isARepeat,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let window, event.window === window,
            let editor = currentEditor(), window.firstResponder === editor
        else { return false }
        DashboardKeyLoop.install(in: window)
        let target = event.modifierFlags.contains(.shift) ? previousKeyView : nextValidKeyView
        guard let target else { return false }
        return window.makeFirstResponder(target)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let window { DashboardKeyLoop.install(in: window) }
    }

    func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === self, let window else { return false }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            guard let previous = previousValidKeyView else { return false }
            return window.makeFirstResponder(previous)
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            guard let next = nextValidKeyView else { return false }
            return window.makeFirstResponder(next)
        }
        return false
    }
}
