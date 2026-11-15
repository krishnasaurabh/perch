import Combine
import PlannerCore
import PerchUI
import SwiftUI

/// Capture is separate from task entry: only an explicit promotion creates a task.
@MainActor final class ParkingLotEntry: ObservableObject {
    @Published var draft = ""

    @discardableResult
    func save(in store: PlannerStore) -> Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            store.apply({ try $0.parkThought(draft) }) != nil
        else { return false }
        draft = ""
        return true
    }

    @discardableResult
    func promote(_ id: UUID, in store: PlannerStore) -> Bool {
        store.apply { try $0.promoteThought(id, on: $0.today) } != nil
    }

    static func summary(count: Int, hasTasks: Bool, blockActive: Bool) -> String {
        if count > 0 {
            return blockActive
                ? AppL10n.format("%lld parked for after this block", count)
                : AppL10n.format("%lld parked", count)
        }
        return hasTasks
            ? AppL10n.text("Nothing parked yet")
            : AppL10n.text("For anything that isn't a task yet")
    }
}

/// The compact card never expands into the checklist or makes captured text a task.
struct ParkingLotCard: View {
    @EnvironmentObject private var store: PlannerStore
    @StateObject private var entry = ParkingLotEntry()
    @State private var showingThoughts = false
    @FocusState private var reviewing: Bool

    var body: some View {
        Card(.apricot) {
            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                Text(AppL10n.text("Parking lot"))
                    .perchFont(.button)
                    .accessibilityAddTraits(.isHeader)
                PerchField("Jot a stray thought", text: $entry.draft, onSubmit: { entry.save(in: store) })
                summary
            }
        }
    }

    private var summaryText: String {
        ParkingLotEntry.summary(
            count: store.planner.parkedThoughts.count,
            hasTasks: store.planner.tasks.contains { $0.day == store.today },
            blockActive: store.planner.focus.map { $0.state != .finished } ?? false)
    }

    @ViewBuilder private var summary: some View {
        if store.planner.parkedThoughts.isEmpty {
            Text(summaryText)
                .perchFont(.detail)
                .foregroundStyle(Theme.foreground(.ink2, on: .apricot))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button {
                showingThoughts = true
            } label: {
                Text(summaryText)
                    .perchFont(.detail)
                    .foregroundStyle(Theme.foreground(.ink2, on: .apricot))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTarget.value, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($reviewing)
            .focusEffectDisabled()
            .overlay(
                FocusRing(
                    shape: RoundedRectangle(cornerRadius: SurfaceMetrics.gap), focused: reviewing, surface: .apricot)
            )
            .accessibilityLabel(AppL10n.text("Show parked thoughts"))
            .accessibilityValue(summaryText)
            .accessibilityIdentifier("parking-lot-review")
            .popover(isPresented: $showingThoughts, arrowEdge: .bottom) {
                ParkedThoughtsView().environmentObject(store)
            }
            // The target extends into unused padding; its 28 pt hit area does not
            // make a populated card taller than an empty one.
            .padding(.vertical, -SurfaceMetrics.compactGap)
        }
    }
}

/// Shared by the review popover and its deterministic snapshot target.
struct ParkedThoughtsView: View {
    @EnvironmentObject private var store: PlannerStore
    @StateObject private var entry = ParkingLotEntry()
    @FocusState private var selected: UUID?

    var body: some View {
        Card(.apricot) {
            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                CardHeading(AppL10n.text("Parking lot"))
                Text(AppL10n.text("⌘↩ makes a task for today"))
                    .perchFont(.detail)
                    .foregroundStyle(Theme.foreground(.ink2, on: .apricot))
                ScrollView {
                    VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                        if store.planner.parkedThoughts.isEmpty {
                            Text(AppL10n.text("Nothing parked yet"))
                                .perchFont(.body)
                        }
                        ForEach(store.planner.parkedThoughts) { thought in
                            thoughtRow(thought)
                        }
                    }
                    .padding(Theme.Size.focusGap.value + Theme.Size.focusWidth.value)
                }
            }
        }
        .frame(width: Theme.Size.peekWidth.value, height: Theme.Size.peekWidth.value)
    }

    private func thoughtRow(_ thought: ParkedThought) -> some View {
        Card(.paper) {
            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                Text(thought.text)
                    .perchFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                PerchButton("Make it a task", kind: .soft, size: .small, surface: .paper) {
                    promote(thought.id)
                }
                .accessibilityLabel(AppL10n.format("Make “%@” a task for today", thought.text))
                .accessibilityIdentifier("parking-promote-\(thought.id.uuidString)")
            }
        }
        .focusable()
        .focused($selected, equals: thought.id)
        .focusEffectDisabled()
        .overlay(
            FocusRing(
                shape: RoundedRectangle(cornerRadius: Theme.Size.cardRadius.value), focused: selected == thought.id,
                surface: .apricot)
        )
        .onKeyPress(.return) { key in
            guard key.modifiers == .command else { return .ignored }
            promote(thought.id)
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    private func promote(_ id: UUID) {
        let thoughts = store.planner.parkedThoughts
        guard let index = thoughts.firstIndex(where: { $0.id == id }), entry.promote(id, in: store) else { return }
        let remaining = store.planner.parkedThoughts
        selected = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor enum ParkingLotPreview {
        static func show(app: AppDelegate) {
            WindowHost.show(
                "parking-thoughts", title: "Parking lot",
                size: CGSize(width: Theme.Size.peekWidth.value, height: Theme.Size.peekWidth.value),
                onUndo: { app.store.undo(redo: $0) }
            ) {
                ParkedThoughtsView().environmentObject(app.store)
            }
        }
    }
#endif
