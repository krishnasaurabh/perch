import PerchUI
import SwiftUI

/// A named on/off control. Native accessibility exposes the label, value and toggle action.
struct PerchSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var surface: DesignTokens.Surface = .paper
    var keyboardFocusable = true
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var direction

    static var knobTravel: CGFloat {
        DesignTokens.Size.switchWidth.value - DesignTokens.Size.switchHeight.value
    }
    static var knobInset: CGFloat {
        (DesignTokens.Size.switchHeight.value - DesignTokens.Size.switchKnob.value) / 2
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? Theme.doneFill : Color.token(.switchOff))
                .designMotion(.hover, value: isOn)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(isOn ? Theme.onDone : Color.token(.white))
                        .frame(width: DesignTokens.Size.switchKnob.value, height: DesignTokens.Size.switchKnob.value)
                        .padding(.leading, Self.knobInset)
                        .offset(x: (isOn ? Self.knobTravel : .zero) * (direction == .rightToLeft ? -1 : 1))
                        .designMotion(.pop, value: isOn)
                }
                .frame(width: DesignTokens.Size.switchWidth.value, height: DesignTokens.Size.switchHeight.value)
                .overlay(FocusRing(shape: Capsule(), focused: focused && enabled, surface: surface))
        }
        .buttonStyle(PerchSwitchStyle())
        .focusable(enabled && keyboardFocusable)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(AppL10n.text(title), isOn: $isOn)
                .toggleStyle(.switch)
                .disabled(!enabled)
        }
    }
}

private struct PerchSwitchStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.perchControlFeedback(pressed: configuration.isPressed)
    }
}
