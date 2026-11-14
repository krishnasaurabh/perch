import AppKit
import PerchUI
import SwiftUI

/// Two to four choices share one Tab stop. Arrows follow visual order; Home/End select the ends.
struct PerchSegmented<Value: Hashable>: View {
    let title: String
    let items: [(value: Value, label: String)]
    @Binding var selection: Value
    var surface: DesignTokens.Surface = .paper
    @Namespace private var highlight
    @FocusState private var focused: Value?
    @AccessibilityFocusState private var accessibilityFocus: Value?
    @State private var groupHasFocus = false
    @State private var restorationID = UUID()
    @State private var focusAnchor = PerchSegmentFocusAnchorView()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var direction

    static var inset: CGFloat {
        DesignTokens.Size.segmentRadius.value - DesignTokens.Size.segmentItemRadius.value
    }
    static var itemHeight: CGFloat {
        max(DesignTokens.Size.minimumTarget.value, DesignTokens.Size.segmentHeight.value - inset * 2)
    }

    var body: some View {
        HStack(spacing: .zero) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = selection == item.value
                Button {
                    selection = item.value
                } label: {
                    Text(AppL10n.text(item.label))
                        .perchFont(.detailStrong)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DesignTokens.Size.stepCheckboxRadius.value)
                        .frame(minWidth: DesignTokens.Size.minimumTarget.value, minHeight: Self.itemHeight)
                        .foregroundStyle(selected ? Color.token(.paper) : Theme.ink)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: DesignTokens.Size.segmentItemRadius.value)
                                    .fill(Theme.ink)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .overlay(
                            FocusRing(
                                shape: RoundedRectangle(cornerRadius: DesignTokens.Size.segmentItemRadius.value),
                                focused: focused == item.value && enabled, surface: surface))
                }
                .buttonStyle(PerchSegmentStyle())
                .focusable(enabled && selected)
                .focused($focused, equals: item.value)
                .focusEffectDisabled()
                .accessibilityLabel(AppL10n.text(item.label))
                .accessibilityValue(selected ? AppL10n.text("Selected") : AppL10n.text("Not selected"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityFocused($accessibilityFocus, equals: item.value)
                .onKeyPress(.leftArrow) { move(from: index, by: direction == .rightToLeft ? 1 : -1) }
                .onKeyPress(.rightArrow) { move(from: index, by: direction == .rightToLeft ? -1 : 1) }
                .onKeyPress(.home) { select(items.startIndex) }
                .onKeyPress(.end) { select(items.count - 1) }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, (DesignTokens.Size.segmentHeight.value - Self.itemHeight) / 2)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Size.segmentRadius.value)
                .fill(Theme.field)
        }
        .background(PerchSegmentFocusAnchor(view: focusAnchor).allowsHitTesting(false))
        .designMotion(.pop, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppL10n.text(title))
        .accessibilityValue(AppL10n.text(items.first(where: { $0.value == selection })?.label ?? ""))
        .onChange(of: focused) { oldValue, value in
            // Publish the keyboard destination on the segment's semantic element,
            // not just its SwiftUI key proxy. Selection alone never claims focus.
            accessibilityFocus = enabled ? value : nil
            if value != nil {
                groupHasFocus = true
            } else if oldValue == selection {
                // The outgoing selection losing focus is temporary; the current one
                // losing focus means the person has moved to a different control.
                _ = leaveGroup()
            }
        }
        .onChange(of: selection) { _, value in restoreFocus(value) }
        .onKeyPress(.tab) { leaveGroup() }
        // AppKit delivers Shift-Tab as back-tab, not as the Tab character.
        .onKeyPress(KeyEquivalent("\u{19}")) { leaveGroup() }
        .onChange(of: enabled) { _, value in
            if !value {
                _ = leaveGroup()
                focused = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === focusAnchor.window else { return }
            _ = leaveGroup()
            focused = nil
        }
        .onDisappear { _ = leaveGroup() }
    }

    private func restoreFocus(_ value: Value) {
        guard groupHasFocus else { return }
        let request = UUID()
        restorationID = request
        // Register the newly focusable button before asking SwiftUI to focus it.
        DispatchQueue.main.async { [self] in
            guard groupHasFocus, enabled, selection == value, restorationID == request,
                focusAnchor.window?.isKeyWindow == true, items.contains(where: { $0.value == value })
            else { return }
            focused = value
        }
    }

    private func leaveGroup() -> KeyPress.Result {
        groupHasFocus = false
        restorationID = UUID()
        accessibilityFocus = nil
        // Tab and Shift-Tab continue through AppKit's native key loop.
        return .ignored
    }

    private func move(from index: Int, by step: Int) -> KeyPress.Result {
        select(min(max(index + step, items.startIndex), items.count - 1))
    }

    private func select(_ index: Int) -> KeyPress.Result {
        guard enabled, items.indices.contains(index) else { return .ignored }
        selection = items[index].value
        return .handled
    }
}

/// A non-accessible anchor scopes deferred focus work to this control's live window.
private struct PerchSegmentFocusAnchor: NSViewRepresentable {
    let view: PerchSegmentFocusAnchorView
    func makeNSView(context: Context) -> PerchSegmentFocusAnchorView { view }
    func updateNSView(_ view: PerchSegmentFocusAnchorView, context: Context) {}
}

private final class PerchSegmentFocusAnchorView: NSView {
    override func isAccessibilityElement() -> Bool { false }
}

private struct PerchSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.perchControlFeedback(pressed: configuration.isPressed)
    }
}
