import PerchUI
import SwiftUI

private struct ControlSurfaceKey: EnvironmentKey {
    static let defaultValue = Color.token(.band)
}

extension EnvironmentValues {
    /// The actual painted surface immediately outside a control's focus ring.
    var controlSurface: Color {
        get { self[ControlSurfaceKey.self] }
        set { self[ControlSurfaceKey.self] = newValue }
    }
}

/// Drawn outside layout so focus never moves text or changes the hit target.
struct ControlFocusRing<S: InsettableShape>: View {
    let shape: S
    let focused: Bool
    @Environment(\.controlSurface) private var surface

    var body: some View {
        if focused {
            shape.inset(by: -Theme.focusGap / 2)
                .stroke(surface, lineWidth: Theme.focusGap)
                .overlay(
                    shape.inset(by: -Theme.focusGap - Theme.focusWidth / 2)
                        .stroke(Theme.info, lineWidth: Theme.focusWidth)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@available(*, deprecated, message: "Use PerchButton.")
struct PillStyle: PrimitiveButtonStyle {
    var prominent = false
    var disabledReason: String = "This action is currently unavailable."
    /// Opt into a Tab stop whose native focus also drives the shared ring.
    var focus: FocusState<Bool>.Binding? = nil

    func makeBody(configuration: Configuration) -> some View {
        FocusablePill(
            configuration: configuration, prominent: prominent, disabledReason: disabledReason, externalFocus: focus)
    }

    private struct FocusablePill: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let prominent: Bool
        let disabledReason: String
        let externalFocus: FocusState<Bool>.Binding?
        @Environment(\.isEnabled) private var enabled
        @FocusState private var focused: Bool

        var body: some View {
            // Register focus on the actual button, not the primitive-style wrapper.
            if let externalFocus {
                Button(configuration)
                    .buttonStyle(
                        VisualStyle(
                            prominent: prominent, disabledReason: disabledReason, focused: externalFocus.wrappedValue)
                    )
                    .focusable(enabled)
                    .focused(externalFocus)
                    .focusEffectDisabled()
            } else {
                // Preserve existing callers' native focus behavior.
                Button(configuration)
                    .buttonStyle(VisualStyle(prominent: prominent, disabledReason: disabledReason, focused: focused))
                    .focused($focused)
                    .focusEffectDisabled()
            }
        }
    }

    private struct VisualStyle: ButtonStyle {
        let prominent: Bool
        let disabledReason: String
        let focused: Bool

        func makeBody(configuration: Configuration) -> some View {
            PillLabel(
                configuration: configuration, prominent: prominent, disabledReason: disabledReason, focused: focused)
        }
    }

    private struct PillLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let disabledReason: String
        let focused: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.label)
                .padding(.horizontal, DesignTokens.Size.segmentRadius.value)
                .frame(minWidth: Theme.minimumTarget, minHeight: Theme.primaryHeight)
                .foregroundStyle(prominent && enabled ? Theme.onAccent : Theme.text)
                .background(Capsule().fill(fill))
                .overlay(
                    Capsule().strokeBorder(
                        Theme.inputStroke,
                        lineWidth: enabled && configuration.isPressed
                            ? DesignTokens.Size.checkboxStroke.value : DesignTokens.Size.checkboxStroke.value / 2)
                )
                .overlay(ControlFocusRing(shape: Capsule(), focused: enabled && focused))
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .accessibilityHint(enabled ? "" : AppL10n.text(disabledReason))
        }

        private var fill: Color {
            if !enabled { return Theme.fill }
            if prominent { return Theme.prominent }
            if configuration.isPressed { return Theme.fillPressed }
            return hover ? Theme.fillStrong : Theme.fill
        }
    }
}
