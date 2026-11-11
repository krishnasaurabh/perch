import PerchUI
import PlannerCore
import SwiftUI

/// Repeat controls bound to a caller-owned draft. They never touch the planner: the owner
/// commits the draft and turns the result into a typed action.
struct RepeatPickerFields: View {
    enum Focus: Hashable { case frequency, interval, unit, weekday(Int), fromCompletion }

    @Binding var draft: RepeatPickerDraft
    var focus: FocusState<Focus?>.Binding
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            frequencyRow
            if draft.frequency == .custom { intervalRow }
            if showsWeekdays { weekdayRow }
            if draft.frequency != .none {
                Toggle(
                    "Count from completion",
                    isOn: Binding(get: { draft.fromCompletion }, set: { draft.setFromCompletion($0) })
                )
                .toggleStyle(.checkbox)
                .font(Theme.meta)
                .focused(focus, equals: .fromCompletion)
                .help("The next copy is counted from the day this one is completed.")
                .accessibilityIdentifier("repeat-from-completion")
            }
            if let issue = draft.visibleIssue {
                StatusLabel(title: issue.message, tone: .danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("repeat-error")
            } else if let preview = RepeatPickerDraft.previewText(draft.preview(), anchor: draft.anchor, locale: locale)
            {
                Text(preview)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("repeat-preview")
            }
        }
        .frame(minWidth: CGFloat(RepeatPickerLayout.compactMinimumWidth), alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repeat")
    }

    private var showsWeekdays: Bool {
        draft.frequency == .weekly || (draft.frequency == .custom && draft.customUnit == .week)
    }

    private var frequencyRow: some View {
        Picker(
            "Repeat",
            selection: Binding(get: { draft.frequency }, set: { draft.select($0) })
        ) {
            ForEach(RepeatPickerDraft.Frequency.allCases, id: \.self) { frequency in
                Text(frequency.title).tag(frequency)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .focused(focus, equals: .frequency)
        .accessibilityLabel("Repeat")
        .accessibilityValue(draft.summary(locale: locale))
        .accessibilityIdentifier("repeat-frequency")
    }

    private var intervalRow: some View {
        let field = HStack(spacing: 4) {
            Text("Every").font(Theme.meta).foregroundStyle(Theme.secondary).accessibilityHidden(true)
            TextField("2", text: Binding(get: { draft.intervalText }, set: { draft.typeInterval($0) }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: CGFloat(RepeatPickerLayout.intervalFieldWidth))
                .focused(focus, equals: .interval)
                .accessibilityLabel("Repeat interval")
                .accessibilityHint(AppL10n.format("A whole number from 1 to %lld", RepeatPickerDraft.maximumInterval))
                .accessibilityIdentifier("repeat-interval")
            Stepper(
                "Repeat interval",
                onIncrement: { draft.stepInterval(by: 1) },
                onDecrement: { draft.stepInterval(by: -1) }
            )
            .labelsHidden()
        }
        let unit = Picker(
            "Repeat unit",
            selection: Binding(get: { draft.customUnit }, set: { draft.setCustomUnit($0) })
        ) {
            ForEach(RepeatPickerDraft.CustomUnit.allCases, id: \.self) { unit in
                Text(unit.title(plural: draft.parsedInterval != 1)).tag(unit)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .focused(focus, equals: .unit)
        .accessibilityLabel("Repeat unit")
        .accessibilityIdentifier("repeat-unit")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.gutter) {
                field
                unit
            }
            VStack(alignment: .leading, spacing: 4) {
                field
                unit
            }
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: CGFloat(RepeatPickerLayout.weekdaySpacing)) {
            ForEach(1...7, id: \.self) { weekday in
                WeekdayToggle(
                    weekday: weekday, selected: draft.weekdays.contains(weekday),
                    focused: focus.wrappedValue == .weekday(weekday)
                ) {
                    draft.toggleWeekday(weekday)
                }
                .focused(focus, equals: .weekday(weekday))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repeat on")
        .accessibilityHint("With no day chosen, it repeats on the task's weekday.")
    }

    private struct WeekdayToggle: View {
        let weekday: Int
        let selected: Bool
        let focused: Bool
        let action: () -> Void
        @Environment(\.locale) private var locale

        var body: some View {
            Button(action: action) {
                Text(RepeatPickerDraft.localizedShortWeekdayNames(locale: locale)[weekday - 1])
                    .font(selected ? Theme.label : Theme.meta)
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .frame(
                        width: CGFloat(RepeatPickerLayout.weekdayTarget),
                        height: CGFloat(RepeatPickerLayout.weekdayTarget)
                    )
                    .background(Circle().fill(selected ? Theme.selectedPill : Theme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .overlay(ControlFocusRing(shape: Circle(), focused: focused))
            .accessibilityLabel(RepeatPickerDraft.localizedWeekdayNames(locale: locale)[weekday - 1])
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("repeat-weekday-\(weekday)")
        }
    }
}

/// A standalone repeat editor with its own draft and Cancel/Done controls.
/// Done (Return) emits a commit only when the draft is valid; Cancel (Escape) discards the draft.
struct RepeatPickerEditor: View {
    let onCommit: (RepeatPickerDraft.Commit) -> Void
    let onCancel: () -> Void
    private let anchor: DayKey?
    @State private var draft: RepeatPickerDraft
    @FocusState private var focus: RepeatPickerFields.Focus?

    init(
        original: TaskRepeat?, anchor: DayKey?, seriesAnchor: DayKey? = nil, calendar: Calendar = .current,
        onCommit: @escaping (RepeatPickerDraft.Commit) -> Void, onCancel: @escaping () -> Void
    ) {
        self.anchor = anchor
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(
            initialValue: RepeatPickerDraft(
                original: original, anchor: anchor, seriesAnchor: seriesAnchor, calendar: calendar))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            RepeatPickerFields(draft: $draft, focus: $focus)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.gutter) {
                    Spacer(minLength: 0)
                    cancelButton
                    doneButton
                }
                VStack(alignment: .trailing, spacing: 4) {
                    doneButton
                    cancelButton
                }
            }
        }
        .padding(Theme.gutter)
        .defaultFocus($focus, .frequency)
        .onChange(of: anchor) { _, day in draft.setAnchor(day) }
    }

    private var cancelButton: some View {
        Button("Cancel", action: cancel)
            .buttonStyle(PillStyle())
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Discards repeat changes")
            .accessibilityIdentifier("repeat-cancel")
    }

    private var doneButton: some View {
        Button("Done", action: commit)
            .buttonStyle(PillStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("repeat-done")
    }

    private func commit() {
        guard let result = draft.commit() else {
            // Move to the field that needs fixing; the message is already shown inline.
            focus = draft.issue?.field == .interval ? .interval : .frequency
            return
        }
        onCommit(result)
    }

    private func cancel() {
        draft.revert()
        onCancel()
    }
}
