import PerchUI
import SwiftUI

/// The task is round; a step is square. The accessible name always includes its title.
struct PerchCheckbox: View {
    enum Kind: CaseIterable {
        case task, step
        var diameter: CGFloat {
            self == .task ? DesignTokens.Size.taskCheckboxSize.value : DesignTokens.Size.stepCheckboxSize.value
        }
        var radius: CGFloat {
            self == .task ? diameter / 2 : DesignTokens.Size.stepCheckboxRadius.value
        }
    }

    let title: String
    @Binding var isOn: Bool
    var kind: Kind = .task
    var surface: DesignTokens.Surface = .paper
    var keyboardFocusable = true
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    @KeyframesBuilder<Double>
    static func popKeyframes(isOn: Bool, reduceMotion: Bool) -> some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(
                isOn && !reduceMotion ? DesignTokens.Motion.tickScale : 1,
                duration: DesignTokens.MotionToken.pop.duration / 2)
            CubicKeyframe(
                1, duration: DesignTokens.MotionToken.pop.duration / 2, startVelocity: .zero, endVelocity: .zero)
        }
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            PerchCheckboxFace(isOn: isOn, kind: kind)
                .overlay(
                    FocusRing(
                        shape: RoundedRectangle(cornerRadius: kind.radius),
                        focused: focused && enabled, surface: surface))
        }
        .buttonStyle(PerchCheckboxStyle())
        .focusable(enabled && keyboardFocusable)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { Text(AppL10n.format("Complete %@", title)) }
                .toggleStyle(.checkbox)
                .disabled(!enabled)
        }
    }
}

private struct PerchCheckboxStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.perchControlFeedback(pressed: configuration.isPressed)
    }
}

private struct PerchCheckboxFace: View {
    let isOn: Bool
    let kind: PerchCheckbox.Kind
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        RoundedRectangle(cornerRadius: kind.radius)
            .fill(isOn ? Theme.doneFill : kind == .step ? Theme.paper : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: kind.radius)
                    .strokeBorder(isOn ? Theme.doneFill : Theme.ink, lineWidth: DesignTokens.Size.checkboxStroke.value)
            )
            .designMotion(.tickFill, value: isOn)
            .overlay {
                PerchCheckMark()
                    .trim(from: .zero, to: isOn ? 1 : .zero)
                    .stroke(
                        Theme.onDone,
                        style: StrokeStyle(
                            lineWidth: DesignTokens.Size.checkboxStroke.value, lineCap: .round, lineJoin: .round)
                    )
                    .designMotion(.tickDraw, value: isOn)
            }
            .frame(width: kind.diameter, height: kind.diameter)
            .keyframeAnimator(initialValue: 1.0, trigger: isOn) { content, scale in
                content.scaleEffect(policy.reduceMotion ? 1 : scale)
            } keyframes: { _ in
                PerchCheckbox.popKeyframes(isOn: isOn, reduceMotion: policy.reduceMotion)
            }
    }
}

/// Unit coordinates scale the same round-ended stroke for tasks and steps.
struct PerchCheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.51))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.70))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.77, y: rect.minY + rect.height * 0.32))
        }
    }
}
