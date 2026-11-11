import SwiftUI

private struct ControlSurfaceKey: EnvironmentKey {
    static let defaultValue = Color.black
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

struct PillStyle: ButtonStyle {
    var prominent = false
    var disabledReason: String = "This action is currently unavailable."

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, prominent: prominent, disabledReason: disabledReason)
    }

    private struct PillLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let disabledReason: String
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.label)
                .padding(.horizontal, 10)
                .frame(minWidth: Theme.minimumTarget, minHeight: Theme.primaryHeight)
                .foregroundStyle(prominent && enabled ? Theme.onAccent : Theme.text)
                .background(Capsule().fill(fill))
                .overlay(
                    Capsule().strokeBorder(Theme.inputStroke, lineWidth: enabled && configuration.isPressed ? 2 : 1)
                )
                .overlay(ControlFocusRing(shape: Capsule(), focused: enabled && focused))
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .accessibilityHint(enabled ? "" : disabledReason)
        }

        private var fill: Color {
            if !enabled { return Theme.fill }
            if prominent { return Theme.prominent }
            if configuration.isPressed { return Theme.fillPressed }
            return hover ? Theme.fillStrong : Theme.fill
        }
    }
}
