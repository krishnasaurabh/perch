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
    @StateObject private var focus = PerchSegmentFocus<Value>()
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
            ForEach(items, id: \.value) { item in
                let selected = selection == item.value
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
                            focused: focus.focused == item.value && enabled, surface: surface)
                    )
                    .perchControlFeedback(pressed: focus.pressed == item.value)
                    .accessibilityHidden(true)
                    .overlay {
                        PerchSegmentKeyTarget(
                            value: item.value, label: AppL10n.text(item.label), items: items.map(\.value),
                            selection: $selection, enabled: enabled, rightToLeft: direction == .rightToLeft,
                            focus: focus)
                    }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, (DesignTokens.Size.segmentHeight.value - Self.itemHeight) / 2)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Size.segmentRadius.value)
                .fill(Theme.field)
        }
        .designMotion(.pop, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppL10n.text(title))
        .accessibilityValue(AppL10n.text(items.first(where: { $0.value == selection })?.label ?? ""))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            focus.resign(in: window)
        }
        .onDisappear { focus.resign() }
    }
}

/// Paint stays in SwiftUI; the transparent AppKit overlay owns both keys and its AXButton.
private struct PerchSegmentKeyTarget<Value: Hashable>: NSViewRepresentable {
    let value: Value
    let label: String
    let items: [Value]
    @Binding var selection: Value
    let enabled: Bool
    let rightToLeft: Bool
    let focus: PerchSegmentFocus<Value>

    func makeNSView(context: Context) -> PerchSegmentKeyView {
        let view = PerchSegmentKeyView()
        focus.register(view, value: value)
        return view
    }

    func updateNSView(_ view: PerchSegmentKeyView, context: Context) {
        view.setAccessibilityLabel(label)
        focus.update(items: items, selection: selection, enabled: enabled, rightToLeft: rightToLeft) {
            selection = $0
        }
    }

    static func dismantleNSView(_ view: PerchSegmentKeyView, coordinator: ()) {
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        view.focusChanged(false)
        view.active = false
    }
}

@MainActor private final class PerchSegmentFocus<Value: Hashable>: ObservableObject {
    @Published private(set) var focused: Value?
    @Published var pressed: Value?
    private var items: [Value] = []
    private var selection: Value?
    private var enabled = true
    private var rightToLeft = false
    private var change: (Value) -> Void = { _ in }
    private var views: [Value: WeakSegmentView] = [:]

    func register(_ view: PerchSegmentKeyView, value: Value) {
        views[value] = WeakSegmentView(view)
        view.selected = { [weak self] in self?.selection == value }
        view.selectionEnabled = { [weak self] in self?.enabled == true }
        view.press = { [weak self] in self?.select(value, acquireFocus: true) }
        view.key = { [weak self] code in self?.key(code, from: value) == true }
        view.focusChanged = { [weak self] _ in
            // Only the decoration is deferred. Native first responder and AX focus change synchronously.
            Task { @MainActor [weak self] in self?.refreshFocusPaint() }
        }
        view.pressChanged = { [weak self] down in self?.pressed = down ? value : nil }
    }

    func update(items: [Value], selection: Value, enabled: Bool, rightToLeft: Bool, change: @escaping (Value) -> Void) {
        let ownsFocus = views.values.contains { $0.view?.ownsKeyboardFocus == true }
        self.items = items
        self.enabled = enabled
        self.rightToLeft = rightToLeft
        self.change = change
        let changed = self.selection != selection
        self.selection = selection
        if !enabled {
            resign()
        } else if changed && ownsFocus {
            // All segment key views persist across selection changes: no queued restoration.
            focus(selection)
        }
    }

    func resign(in window: NSWindow? = nil) {
        for entry in views.values {
            guard let view = entry.view, window == nil || view.window === window else { continue }
            if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
            view.focusChanged(false)
        }
        if pressed != nil { pressed = nil }
    }

    private func refreshFocusPaint() {
        let current = views.first { $0.value.view?.isAccessibilityFocused() == true }?.key
        if focused != current { focused = current }
    }

    private func select(_ value: Value, acquireFocus: Bool) {
        guard enabled, items.contains(value) else { return }
        selection = value
        change(value)
        if acquireFocus { focus(value) }
    }

    private func focus(_ value: Value) {
        guard enabled, let view = views[value]?.view, view.active,
            let window = view.window, window.isKeyWindow
        else { return }
        window.makeFirstResponder(view)
    }

    private func key(_ code: UInt16, from value: Value) -> Bool {
        guard enabled, let index = items.firstIndex(of: value), !items.isEmpty else { return false }
        let target: Int
        switch code {
        case 123: target = min(max(index + (rightToLeft ? 1 : -1), 0), items.count - 1)
        case 124: target = min(max(index + (rightToLeft ? -1 : 1), 0), items.count - 1)
        case 115: target = items.startIndex
        case 119: target = items.count - 1
        case 49, 36: target = index
        default: return false
        }
        select(items[target], acquireFocus: true)
        return true
    }
}

@MainActor private final class WeakSegmentView {
    weak var view: PerchSegmentKeyView?
    init(_ view: PerchSegmentKeyView) { self.view = view }
}

/// The first responder and accessible segment are the same object, not a focus proxy.
@MainActor final class PerchSegmentKeyView: NSControl {
    var active = true
    var selected: () -> Bool = { false }
    var selectionEnabled: () -> Bool = { false }
    var press: () -> Void = {}
    var key: (UInt16) -> Bool = { _ in false }
    var focusChanged: (Bool) -> Void = { _ in }
    var pressChanged: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { active && selectionEnabled() && selected() }
    var ownsKeyboardFocus: Bool { window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }
        focusChanged(true)
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focusChanged(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        } else if !key(event.keyCode) {
            // Escape and unhandled commands continue to the surrounding SwiftUI responder.
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard active, selectionEnabled() else { return }
        pressChanged(true)
        defer { pressChanged(false) }
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { press() }
                break
            }
        }
    }

    override func isAccessibilityEnabled() -> Bool { active && selectionEnabled() }
    override func accessibilityValue() -> Any? { AppL10n.text(selected() ? "Selected" : "Not selected") }
    override func isAccessibilitySelected() -> Bool { selected() }
    override func isAccessibilityFocused() -> Bool {
        active && selectionEnabled() && selected() && !isHiddenOrHasHiddenAncestor
            && window?.isKeyWindow == true && ownsKeyboardFocus
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused && acceptsFirstResponder {
            window?.makeFirstResponder(self)
        } else if !focused && ownsKeyboardFocus {
            window?.makeFirstResponder(nil)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        guard active, selectionEnabled() else { return false }
        press()
        return true
    }
}
