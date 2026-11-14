import PerchUI
import SwiftUI

/// A single primary action, an additional choice, or a quiet way out.
enum PerchButtonKind { case main, soft, quiet }

enum PerchButtonSize: CaseIterable {
    case regular, strip, small
    var height: CGFloat {
        switch self {
        case .regular: return DesignTokens.Size.buttonHeight.value
        case .strip: return DesignTokens.Size.stripButtonHeight.value
        case .small: return DesignTokens.Size.smallButtonHeight.value
        }
    }
}

struct PerchButton<Label: View>: View {
    typealias Kind = PerchButtonKind
    typealias Size = PerchButtonSize

    var kind: Kind = .main
    var size: Size = .regular
    var surface: DesignTokens.Surface = .paper
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    init(
        kind: Kind = .main, size: Size = .regular, surface: DesignTokens.Surface = .paper,
        action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label
    ) {
        self.kind = kind
        self.size = size
        self.surface = surface
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(PerchButtonStyle(kind: kind, size: size, surface: surface, focused: focused))
            .focusable(enabled)
            .focused($focused)
            .focusEffectDisabled()
    }
}

extension PerchButton where Label == Text {
    init(
        _ title: String, kind: Kind = .main, size: Size = .regular,
        surface: DesignTokens.Surface = .paper, action: @escaping () -> Void
    ) {
        self.init(kind: kind, size: size, surface: surface, action: action) { Text(AppL10n.text(title)) }
    }
}

private struct PerchButtonStyle: ButtonStyle {
    let kind: PerchButton<Text>.Kind
    let size: PerchButton<Text>.Size
    let surface: DesignTokens.Surface
    let focused: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .perchFont(.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignTokens.Size.buttonSidePadding.value)
            .padding(.vertical, DesignTokens.Size.stepCheckboxRadius.value)
            .frame(minWidth: DesignTokens.Size.minimumTarget.value, minHeight: size.height)
            .background(Capsule().fill(fill))
            .overlay(FocusRing(shape: Capsule(), focused: focused && enabled, surface: surface))
            .perchControlFeedback(pressed: configuration.isPressed)
    }

    private var fill: Color {
        switch kind {
        case .main: return Theme.brandFill
        case .soft: return Theme.fill(surface == .paper || surface == .sheet ? .field : .paper)
        case .quiet: return .clear
        }
    }

    private var foreground: Color {
        if !enabled { return kind == .main ? Theme.onBrand : Theme.ink2 }
        switch kind {
        case .main: return Theme.onBrand
        case .soft: return Theme.ink
        case .quiet: return Theme.ink2
        }
    }
}

/// Shared feedback transforms the paint, not the minimum pointer target.
private struct PerchControlFeedback: ViewModifier {
    let pressed: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && pressed && !policy.reduceMotion ? DesignTokens.Motion.pressScale : 1)
            .designMotion(.press, value: pressed)
            .offset(
                y: enabled && hovered && !pressed && !policy.reduceMotion ? -DesignTokens.Size.hoverLift.value : .zero
            )
            .designMotion(.hover, value: hovered)
            .frame(minWidth: DesignTokens.Size.minimumTarget.value, minHeight: DesignTokens.Size.minimumTarget.value)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

extension View {
    func perchControlFeedback(pressed: Bool) -> some View {
        modifier(PerchControlFeedback(pressed: pressed))
    }
}
