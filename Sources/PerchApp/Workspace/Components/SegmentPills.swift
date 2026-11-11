import SwiftUI

/// A single keyboard group: arrows/Home/End select, Tab leaves the group.
struct SegmentPills<T: Hashable>: View {
    let items: [(value: T, label: String)]
    @Binding var selection: T
    @FocusState private var focused: T?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let selected = selection == item.value
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(selected ? Theme.label : Theme.meta)
                        .monospacedDigit()
                        .padding(.horizontal, 9)
                        .frame(minWidth: Theme.minimumTarget, minHeight: Theme.minimumTarget)
                }
                .buttonStyle(SegmentStyle(selected: selected, focused: focused == item.value))
                .focusable(selected)
                .focused($focused, equals: item.value)
                .focusEffectDisabled()
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onKeyPress(.leftArrow) { move(from: i, by: -1) }
                .onKeyPress(.rightArrow) { move(from: i, by: 1) }
                .onKeyPress(.home) { select(0) }
                .onKeyPress(.end) { select(items.count - 1) }
            }
        }
        .padding(4)
        .accessibilityElement(children: .contain)
        .transaction { $0.animation = nil }
    }

    private func move(from index: Int, by step: Int) -> KeyPress.Result {
        select(min(max(index + step, 0), items.count - 1))
    }

    private func select(_ index: Int) -> KeyPress.Result {
        guard enabled, items.indices.contains(index) else { return .ignored }
        selection = items[index].value
        focused = items[index].value
        return .handled
    }

    private struct SegmentStyle: ButtonStyle {
        let selected: Bool
        let focused: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .background(Capsule().fill(fill(pressed: configuration.isPressed)))
                .overlay(ControlFocusRing(shape: Capsule(), focused: focused && enabled))
                .contentShape(Capsule())
                .onHover { hover = $0 }
        }

        private func fill(pressed: Bool) -> Color {
            if !enabled { return selected ? Theme.selectedPill : .clear }
            if pressed { return Theme.fillPressed }
            if selected { return Theme.selectedPill }
            return hover ? Theme.fillStrong : .clear
        }
    }
}
