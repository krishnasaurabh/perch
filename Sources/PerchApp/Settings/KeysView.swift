import AppKit
import PerchUI
import PlannerCore
import SwiftUI

/// The reference and the event matcher read the same portable catalog.
struct KeysView: View {
    var body: some View {
        DotGridSheet(.window) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: KeyMap.Layout.columnGap) {
                    VStack(alignment: .leading, spacing: .zero) {
                        Text(KeyMap.help.label)
                            .perchFont(.windowTitle)
                            .frame(minHeight: KeyMap.Layout.headerLineHeight, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        Text(AppL10n.text("Everything works without the mouse. Press ? in Perch to see this sheet."))
                            .perchFont(.body)
                            .foregroundStyle(Theme.ink2)
                            .frame(minHeight: KeyMap.Layout.bodyLineHeight, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, KeyMap.Layout.headerInset)
                    HStack(alignment: .top, spacing: KeyMap.Layout.columnGap) {
                        ForEach(KeyMap.columns.indices, id: \.self) { column in
                            VStack(spacing: KeyMap.Layout.cardGap) {
                                ForEach(KeyMap.columns[column]) { group in
                                    KeysGroup(group: group)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .accessibilityIdentifier("keys-sheet")
    }
}

private struct KeysGroup: View {
    let group: KeyMap.Group

    var body: some View {
        Card(group.surface) {
            VStack(alignment: .leading, spacing: .zero) {
                Text(group.title)
                    .perchFont(.stripTitle)
                    .frame(minHeight: KeyMap.Layout.groupLineHeight, alignment: .leading)
                    .padding(.bottom, KeyMap.Layout.headingGap)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.entries) { entry in
                    HStack(spacing: KeyMap.Layout.cardGap) {
                        HStack(spacing: KeyMap.Layout.keyGap) {
                            ForEach(Array(entry.keyCaps.enumerated()), id: \.offset) { _, cap in
                                Text(verbatim: cap)
                                    .perchFont(.detailStrong)
                                    .padding(.horizontal, KeyMap.Layout.keyPadding)
                                    .frame(minWidth: KeyMap.Layout.keyHeight, minHeight: KeyMap.Layout.keyHeight)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Size.segmentItemRadius.value)
                                            .fill(Theme.fill(.field))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.Size.segmentItemRadius.value)
                                            .strokeBorder(Theme.edge(.paper), lineWidth: Theme.Size.cardEdge.value)
                                    )
                            }
                        }
                        .frame(width: KeyMap.Layout.keyColumnWidth, alignment: .leading)
                        Text(entry.label)
                            .perchFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: KeyMap.Layout.rowHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(entry.keyCaps.joined(separator: " ") + ", " + entry.label))
                    .accessibilityIdentifier("keys-\(entry.id.rawValue)")
                }
            }
            // Card owns its edge and base inset; the compact reference uses a
            // smaller vertical inset with the border included in the text origin.
            .padding(.horizontal, Theme.Size.cardEdge.value)
            .padding(
                .vertical, KeyMap.Layout.cardVerticalPadding + Theme.Size.cardEdge.value - Theme.Size.cardPadding.value)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keys-group-\(group.rawValue)")
    }
}

@MainActor
enum KeysWindow {
    private static var shortcuts: KeysShortcutRouter?

    static func show(store: PlannerStore) {
        WindowHost.show(
            "keys", title: KeyMap.help.label,
            size: CGSize(width: KeyMap.Layout.width, height: KeyMap.Layout.height),
            onUndo: { redo in if redo { store.redo() } else { store.undo() } }
        ) {
            KeysView()
        }
    }

    /// One app-lifetime local monitor. Carbon's existing configurable global
    /// opening shortcut is intentionally left with its current owner.
    static func install(store: PlannerStore, model: NotchModel) {
        guard shortcuts == nil else { return }
        let router = KeysShortcutRouter(store: store, model: model)
        router.start()
        shortcuts = router
    }
}

/// First responders that record a chord own it before application shortcuts.
protocol KeysShortcutInputOwner: AnyObject {}

@MainActor
final class KeysShortcutRouter {
    private weak var store: PlannerStore?
    private weak var model: NotchModel?
    @MainActor private final class MonitorState { var monitor: Any? }
    private let lifetime = MainActorLifetime(MonitorState()) { state in
        if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
    }
    private var eventWindow: NSWindow?

    init(store: PlannerStore, model: NotchModel) {
        self.store = store
        self.model = model
    }

    /// This is also the registry inspected by native coverage tests. A catalog
    /// handler is not considered bound merely because its name exists.
    lazy var bindings = KeyMap.Bindings(handlers: [
        .showKeys: { [weak self] in
            guard let store = self?.store else { return false }
            KeysWindow.show(store: store)
            return true
        },
        .close: { [weak self] in
            guard let self, let window = eventWindow else { return false }
            if window is NotchPanel {
                model?.close()
            } else {
                guard window.styleMask.contains(.closable) else { return false }
                window.performClose(nil)
            }
            return true
        },
        .undo: { [weak self] in
            guard let store = self?.store, store.canUndo else { return false }
            store.undo()
            return true
        },
        .pauseOrContinue: { [weak self] in
            guard let store = self?.store, let focus = store.planner.focus else { return false }
            switch focus.state {
            case .running: return store.send(.pauseTimer) != nil
            case .paused: return store.send(.resumeTimer) != nil
            case .finished: return false
            }
        },
        .addFiveMinutes: { [weak self] in
            guard let store = self?.store, let focus = store.planner.focus,
                focus.state != .finished, focus.limit != nil
            else { return false }
            return store.send(.extendTimer(5)) != nil
        },
        .openWeek: {
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.week)
            return true
        },
    ])

    func start() {
        guard lifetime.state.monitor == nil else { return }
        lifetime.state.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === NSApp.keyWindow else { return false }
        guard !(window.firstResponder is KeysShortcutInputOwner) else { return false }
        eventWindow = window
        defer { eventWindow = nil }
        let context: KeyMap.Context
        if window.attachedSheet != nil || NSApp.modalWindow != nil || window.isSheet || window.sheetParent != nil {
            context = .modal
        } else if window.firstResponder is NSTextView {
            context = .textEditing
        } else {
            context = .application
        }
        return bindings.handle(
            KeyMap.Input(
                keyCode: UInt32(event.keyCode), characters: event.characters ?? "",
                modifiers: ShortcutModifiers(flagBits: event.modifierFlags.rawValue), isRepeat: event.isARepeat),
            context: context)
    }
}
