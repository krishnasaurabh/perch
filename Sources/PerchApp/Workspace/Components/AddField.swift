import PerchUI
import SwiftUI

/// Task capture with an explicit accessible label, separate from its prompt.
/// The owner supplies persistence, dictation, and any checklist-specific Tab handling.
struct AddField: View {
    let label: String
    @Binding var text: String
    var prompt: String? = nil
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: () -> Void = {}
    let onDictate: () -> Void

    init(
        _ label: String, text: Binding<String>, prompt: String? = nil,
        focus: FocusState<Bool>.Binding? = nil, onSubmit: @escaping () -> Void = {},
        onDictate: @escaping () -> Void
    ) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.focus = focus
        self.onSubmit = onSubmit
        self.onDictate = onDictate
    }

    var body: some View {
        SurfaceTextEntry(
            label: label, text: $text, prompt: prompt, focus: focus,
            onSubmit: onSubmit, onDictate: onDictate)
    }
}

/// Plain paper input for a colored card. No capture icon or dictation action.
struct PerchField: View {
    let label: String
    @Binding var text: String
    var prompt: String? = nil
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: () -> Void = {}

    init(
        _ label: String, text: Binding<String>, prompt: String? = nil,
        focus: FocusState<Bool>.Binding? = nil, onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.focus = focus
        self.onSubmit = onSubmit
    }

    var body: some View {
        SurfaceTextEntry(label: label, text: $text, prompt: prompt, focus: focus, onSubmit: onSubmit)
    }
}

private struct SurfaceTextEntry: View {
    let label: String
    @Binding var text: String
    let prompt: String?
    let focus: FocusState<Bool>.Binding?
    let onSubmit: () -> Void
    var onDictate: (() -> Void)? = nil
    @FocusState private var localFocus: Bool
    @FocusState private var microphoneFocused: Bool
    @Environment(\.designSurface) private var parentSurface

    private var isCapture: Bool { onDictate != nil }
    private var surface: PerchSurface { isCapture ? .field : .paper }
    private var editing: FocusState<Bool>.Binding { focus ?? $localFocus }
    private var radius: CGFloat { isCapture ? Theme.Size.addFieldRadius.value : SurfaceMetrics.fieldRadius }
    private var fieldIdentifier: String {
        if isCapture { return "capture-add-task" }
        return "surface-text-field"
    }

    var body: some View {
        HStack(spacing: SurfaceMetrics.gap) {
            if isCapture {
                // TODO: use the custom Add icon from the buttons and icons foundation lane.
                Image(systemName: "plus")
                    .perchFont(.body)
                    .foregroundStyle(Theme.foreground(.ink2, on: surface))
                    .accessibilityHidden(true)
            }
            TextField(
                text: $text,
                prompt: Text(AppL10n.text(prompt ?? label)).foregroundStyle(Theme.foreground(.ink2, on: surface))
            ) {
                Text(AppL10n.text(label))
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .perchFont(.body)
            .foregroundStyle(Theme.foreground(.ink, on: surface))
            .focused(editing)
            .focusEffectDisabled()
            .accessibilityLabel(Text(AppL10n.text(label)))
            .accessibilityIdentifier(fieldIdentifier)
            .onSubmit(onSubmit)

            if let onDictate {
                Button(action: onDictate) {
                    // TODO: use the custom Dictate icon from the buttons and icons foundation lane.
                    Image(systemName: "mic")
                        .perchFont(.body)
                        .frame(width: Theme.Size.minimumTarget.value, height: Theme.Size.minimumTarget.value)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.foreground(.ink2, on: surface))
                .focused($microphoneFocused)
                .focusEffectDisabled()
                .overlay(
                    SurfaceFocusRing(
                        shape: RoundedRectangle(cornerRadius: SurfaceMetrics.gap),
                        focused: microphoneFocused, surface: surface)
                )
                .accessibilityLabel(AppL10n.text("Dictate instead"))
                .help(AppL10n.text("Dictate instead"))
            }
        }
        .padding(.leading, isCapture ? Theme.Size.sheetPadding.value : SurfaceMetrics.textInset)
        .padding(.trailing, isCapture ? SurfaceMetrics.gap : SurfaceMetrics.textInset)
        .padding(.vertical, SurfaceMetrics.gap)
        .frame(minHeight: isCapture ? Theme.Size.addFieldHeight.value : Theme.Size.taskRowHeight.value)
        .background(RoundedRectangle(cornerRadius: radius).fill(Theme.fill(surface)))
        .overlay {
            if editing.wrappedValue {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.brandFill, lineWidth: Theme.Size.fieldFocusWidth.value)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(
            SurfaceFocusRing(
                shape: RoundedRectangle(cornerRadius: radius), focused: editing.wrappedValue,
                surface: parentSurface ?? .paper)
        )
        .environment(\.controlSurface, Theme.fill(surface))
        .environment(\.designSurface, surface)
    }
}

/// A ring outside layout: focus does not resize the field or move its text.
private struct SurfaceFocusRing<S: InsettableShape>: View {
    let shape: S
    let focused: Bool
    let surface: PerchSurface

    var body: some View {
        if focused {
            shape.inset(by: -Theme.Size.focusGap.value - Theme.Size.focusWidth.value / 2)
                .stroke(Theme.foreground(.focusRing, on: surface), lineWidth: Theme.Size.focusWidth.value)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
