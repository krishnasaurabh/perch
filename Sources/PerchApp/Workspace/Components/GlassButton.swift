import PerchUI
import SwiftUI

@available(*, deprecated, message: "Use PerchButton with an icon label.")
struct GlassButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = Theme.text
    var size: CGFloat = DesignTokens.Size.minimumTarget.value
    var disabledReason: String = "This action is currently unavailable."
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(enabled ? tint : Theme.tertiary)
                .frame(width: max(size, Theme.minimumTarget), height: max(size, Theme.minimumTarget))
        }
        .buttonStyle(IconStyle(hover: hover, focused: focused))
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .help(enabled ? AppL10n.text(help) : AppL10n.text(disabledReason))
        .accessibilityLabel(AppL10n.text(help))
        .accessibilityHint(enabled ? "" : AppL10n.text(disabledReason))
    }

    private struct IconStyle: ButtonStyle {
        let hover: Bool
        let focused: Bool
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    Circle().fill(
                        !enabled
                            ? Theme.fill
                            : configuration.isPressed ? Theme.fillPressed : hover ? Theme.fillStrong : Theme.fill)
                )
                .overlay(
                    Circle().strokeBorder(Theme.inputStroke, lineWidth: DesignTokens.Size.checkboxStroke.value / 2)
                )
                .overlay(ControlFocusRing(shape: Circle(), focused: focused && enabled))
                .contentShape(Circle())
        }
    }
}
