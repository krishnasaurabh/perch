import PerchUI
import PlannerCore
import SwiftUI

/// Edits one optional day through a `DateFieldDraft`. It never touches the planner:
/// edits stay in the bound draft, and Apply hands a validated `Commit` to the caller,
/// which turns it into a typed action. Pass `nil` for both callbacks when an enclosing
/// form owns Save and Cancel; the editor then neither shows them nor captures Escape.
struct DateFieldEditor: View {
    /// Visible field name, such as "Deadline". Also used for labels and identifiers.
    let field: String
    @Binding var draft: DateFieldDraft
    var onCommit: ((DateFieldDraft.Commit) -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @FocusState private var focus: DateFieldControl?

    private var key: String { field.lowercased() }
    private var localizedField: String { AppL10n.text(field) }
    private var hasActions: Bool { onCommit != nil || onCancel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            adaptiveLayout
            inlineIssue
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizedField)
        .onExitCommand(perform: exitAction)
        .onAppear {
            // An enclosing form chooses its own initial focus.
            if hasActions { focus = draft.entry == .none ? .add : .text }
        }
    }

    private var exitAction: (() -> Void)? {
        guard onCancel != nil else { return nil }
        return cancel
    }

    private var adaptiveLayout: some View {
        // Each step down stacks more so the controls never clip in a narrow window.
        // Every layout keeps the same keyboard order: text, picker, clear, cancel, apply.
        ViewThatFits(in: .horizontal) {
            wideLayout
            mediumLayout
            compactLayout
        }
    }

    @ViewBuilder private var wideLayout: some View {
        HStack(spacing: Theme.gutter) {
            entryRow
            if hasActions { Spacer(minLength: 0); actions }
        }
    }

    @ViewBuilder private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            entryRow
            if hasActions { actions }
        }
    }

    @ViewBuilder private var compactLayout: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            entryStacked
            if hasActions { actions }
        }
    }

    @ViewBuilder private var inlineIssue: some View {
        if let issue = draft.visibleIssue {
            let tone: StatusLabel.Tone = issue.severity == .error ? .danger : .warning
            StatusLabel(title: issue.message, tone: tone)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(key)-date-issue")
        }
    }

    @ViewBuilder private var entryRow: some View {
        if draft.entry == .none {
            noneRow
        } else {
            HStack(spacing: Theme.gutter) {
                textField; picker; clearButton
            }
        }
    }

    @ViewBuilder private var entryStacked: some View {
        if draft.entry == .none {
            noneRow
        } else {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                textField
                HStack(spacing: Theme.gutter) {
                    picker; clearButton
                }
            }
        }
    }

    private var noneRow: some View {
        HStack(spacing: Theme.gutter) {
            Text("No date").font(Theme.body).foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("\(key)-date-none")
            button(.add, title: "Add date") {
                draft.addSuggested()
                focus = .text
            }
        }
    }

    private var textField: some View {
        TextField("YYYY-MM-DD", text: Binding(get: { draft.text }, set: { draft.type($0) }))
            .textFieldStyle(.roundedBorder)
            .font(Theme.body.monospacedDigit())
            .frame(minWidth: 96, idealWidth: 110, maxWidth: 130)
            .focused($focus, equals: .text)
            .onSubmit(commit)
            .accessibilityLabel(DateFieldControl.text.accessibilityLabel(field: localizedField))
            .accessibilityValue(draft.accessibilityValue(calendar: calendar, locale: locale))
            .accessibilityIdentifier(DateFieldControl.text.identifier(field: key))
    }

    private var picker: some View {
        DatePicker(
            localizedField,
            selection: Binding(
                get: { draft.pickerDate(calendar: calendar) },
                set: { draft.select($0, calendar: calendar) }),
            displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .fixedSize()
        .focused($focus, equals: .picker)
        .accessibilityLabel(DateFieldControl.picker.accessibilityLabel(field: localizedField))
        .accessibilityIdentifier(DateFieldControl.picker.identifier(field: key))
    }

    private var clearButton: some View {
        button(.clear, title: "Clear") {
            draft.clear()
            focus = .add
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.gutter) {
            if onCancel != nil { button(.cancel, title: "Cancel", action: cancel) }
            if onCommit != nil {
                button(.commit, title: "Apply", prominent: true, action: commit)
                    .disabled(!draft.canCommit)
            }
        }
    }

    @ViewBuilder private func button(
        _ control: DateFieldControl, title: String, prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        if control == .add || control == .clear {
            NativeDateButtonIdentity(
                identifier: control.identifier(field: key), label: control.accessibilityLabel(field: localizedField),
                action: action
            ) {
                styledButton(control, title: title, prominent: prominent, action: action)
            }
            .fixedSize()
        } else {
            styledButton(control, title: title, prominent: prominent, action: action)
        }
    }

    private func styledButton(
        _ control: DateFieldControl, title: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(AppL10n.text(title), action: action)
            .buttonStyle(
                PillStyle(prominent: prominent, disabledReason: draft.visibleIssue?.message ?? "Fix the date first.")
            )
            .fixedSize()
            .focused($focus, equals: control)
            .accessibilityLabel(control.accessibilityLabel(field: localizedField))
            .accessibilityIdentifier(control.identifier(field: key))
    }

    private func commit() {
        guard let onCommit else { return }
        if let result = draft.commit() {
            onCommit(result)
        } else {
            focus = draft.entry == .none ? .add : .text
        }
    }

    private func cancel() {
        guard let onCancel else { return }
        draft.revert()
        onCancel()
    }
}
