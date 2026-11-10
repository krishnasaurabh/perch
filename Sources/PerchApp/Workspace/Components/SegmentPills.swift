import SwiftUI

/// Small segmented control for "To do / Completed" pills. Selection snaps.
struct SegmentPills<T: Hashable>: View {
    let items: [(value: T, label: String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                let on = selection == it.value
                Button {
                    selection = it.value
                } label: {
                    Text(it.label)
                        .font(.system(size: 11, weight: on ? .semibold : .medium).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Theme.selectedPill : .clear))
                        .foregroundStyle(on ? Theme.text : Theme.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .transaction { $0.animation = nil }
    }
}
