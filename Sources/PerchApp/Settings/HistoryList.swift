import AppKit
import PerchUI
import PlannerCore
import SwiftUI

struct HistoryList: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var query = ""
    @State private var filter: HistoryModel.Filter = .everything
    @State private var expanded: [DayKey: Bool] = [:]
    @State private var showAll = Set<DayKey>()
    #if DEBUG || PERCH_TESTING
        @ObservedObject private var preview = HistoryPreviewState.shared
    #endif

    var body: some View {
        let history = HistoryModel(engine: store.engine, query: query, filter: filter)
        ReviewColumns(weights: [1.6, 1]) {
            Card(.paper) {
                VStack(alignment: .leading, spacing: Theme.Size.cardGap.value) {
                    if history.groups.isEmpty && history.undated.isEmpty {
                        Text(
                            AppL10n.text(
                                query.isEmpty && filter == .everything
                                    ? "Finished tasks show up here." : "No matches. Try another search or filter.")
                        )
                        .foregroundStyle(Theme.ink2)
                    }
                    ForEach(history.groups, id: \.day) { group in
                        dayGroup(group)
                        if group.day != history.groups.last?.day { Divider().overlay(Theme.edge(.paper)) }
                    }
                    if !history.undated.isEmpty {
                        Text("Earlier tasks").perchFont(.stripTitle)
                        ForEach(history.undated) { task in taskRow(task) }
                    }
                    Spacer(minLength: .zero)
                }
                .frame(
                    minHeight: Theme.Size.peekWidth.value - Theme.Size.cardPadding.value * 2,
                    alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: SurfaceMetrics.fieldRadius) {
                Card(.paper) {
                    VStack(alignment: .leading, spacing: SurfaceMetrics.gap / 2) {
                        DashboardHistorySearch(query: $query)
                            .frame(height: Theme.Size.buttonHeight.value)
                            .padding(.bottom, SurfaceMetrics.compactGap)
                        ForEach(HistoryModel.Filter.allCases, id: \.self) { item in
                            HistoryFilterButton(title: Self.title(item), selected: filter == item) {
                                filter = item
                                expanded = [:]
                            }
                        }
                    }
                }
                Card(.mint) {
                    VStack(alignment: .leading, spacing: SurfaceMetrics.gap / 2) {
                        Text("So far this week").perchFont(.stripTitle)
                        Spacer(minLength: Theme.Size.buttonHeight.value)
                        Text(AppL10n.format("%lld done", history.weekDone)).perchFont(.timer)
                        Text(AppL10n.format("across %lld days", history.weekActiveDays))
                            .foregroundStyle(Theme.ink2)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .perchFont(.body)
        #if DEBUG || PERCH_TESTING
            .onReceive(preview.$filter) {
                filter = $0; query = ""; expanded = [:]
            }
        #endif
    }

    private func dayGroup(_ group: HistoryModel.Group) -> some View {
        let open = expanded[group.day] ?? group.initiallyExpanded
        let tasks = showAll.contains(group.day) ? group.tasks : Array(group.tasks.prefix(3))
        return VStack(alignment: .leading, spacing: Theme.Size.checkboxStroke.value) {
            HStack(spacing: SurfaceMetrics.gap) {
                Text(
                    group.day.date(calendar: store.engine.calendar).formatted(
                        .dateTime.weekday(.wide).month(.abbreviated).day())
                )
                .perchFont(.stripTitle)
                .foregroundStyle(open ? Theme.ink : Theme.ink2)
                Text(AppL10n.format("%lld done", group.tasks.count)).perchFont(.detailStrong)
                    .foregroundStyle(Theme.doneText)
                Spacer(minLength: .zero)
                PerchButton(open ? "Close" : "Open", kind: .quiet, size: .small) {
                    expanded[group.day] = !open
                }
                .accessibilityLabel(AppL10n.format(open ? "Close %@" : "Open %@", group.day.raw))
            }
            if open {
                ForEach(tasks) { task in taskRow(task) }
                if group.tasks.count > tasks.count {
                    PerchButton(
                        AppL10n.format("and %lld more", group.tasks.count - tasks.count),
                        kind: .quiet, size: .small
                    ) {
                        showAll.insert(group.day)
                    }
                }
            }
        }
    }

    private func taskRow(_ task: PlanTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SurfaceMetrics.gap) {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.doneFill)
                .frame(width: Theme.Size.taskCheckboxSize.value)
                .accessibilityHidden(true)
            Text(task.title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SurfaceMetrics.gap)
            VStack(alignment: .trailing, spacing: Theme.Size.checkboxStroke.value) {
                if let minutes = task.minutes {
                    Text(AppL10n.format("%lld min in a block", minutes))
                } else if task.focusedSeconds > 0 {
                    Text(AppL10n.format("%lld min in a block", Int(task.focusedSeconds / 60)))
                }
                if let agent = AgentName.short(task.agentID) {
                    Text(AppL10n.format("Added by %@", agent))
                }
            }
            .perchFont(.detail).foregroundStyle(Theme.ink2)
        }
        .frame(minHeight: Theme.Size.taskRowHeight.value)
        .accessibilityElement(children: .combine)
    }

    static func title(_ filter: HistoryModel.Filter) -> String {
        switch filter {
        case .everything: AppL10n.text("Everything")
        case .carried: AppL10n.text("Carried over at least once")
        case .time: AppL10n.text("Had time set aside")
        case .agent: AppL10n.text("Added by an agent")
        }
    }
}

private struct HistoryFilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title).perchFont(selected ? .detailStrong : .pill)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.pillMaxHeight.value, alignment: .leading)
                .padding(.horizontal, SurfaceMetrics.fieldRadius)
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value)
                        .fill(selected ? Theme.butter : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(
            FocusRing(
                shape: RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value),
                focused: focused, surface: .paper)
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor
    final class HistoryPreviewState: ObservableObject {
        static let shared = HistoryPreviewState()
        @Published var filter: HistoryModel.Filter = .everything
    }
#endif

/// A native search editor whose Tab commands use the dashboard's explicit
/// key-view links instead of being swallowed by the SwiftUI field editor.
struct DashboardHistorySearch: NSViewRepresentable {
    @Binding var query: String

    func makeNSView(context: Context) -> DashboardSearchField {
        let field = DashboardSearchField()
        field.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
        field.placeholderString = AppL10n.text("Find a finished task")
        field.setAccessibilityLabel(AppL10n.text("Find a finished task"))
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font =
            NSFont(
                name: DesignTokens.FontResource.postScriptName(for: .medium), size: DesignTokens.TypeRole.body.spec.size
            )
            ?? .systemFont(ofSize: DesignTokens.TypeRole.body.spec.size)
        field.textColor = NSColor(Theme.ink)
        field.backgroundColor = NSColor(Theme.field)
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
