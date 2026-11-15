import AppKit
import Combine
import PerchUI
import PlannerCore
import SwiftUI

/// The shortcut in Settings: records a replacement and keeps rejected chords out of stored preferences.
struct ShortcutPreferenceRow: View {
    // A standalone recorder remains available to existing keyboard integrations.
    var store: PlannerStore? = nil
    @State private var shortcut: ShortcutKey = .default
    @State private var recording = false
    @State private var problem: String?

    var body: some View {
        SettingsRow("Shortcut to open and start typing") {
            VStack(alignment: .trailing, spacing: SettingsMetrics.titleGap) {
                HStack(spacing: SurfaceMetrics.gap) {
                    if recording {
                        ShortcutRecorder(onRecord: choose, onCancel: { recording = false })
                            .frame(width: Theme.Size.buttonHeight.value * 2, height: Theme.Size.smallButtonHeight.value)
                            .overlay {
                                FocusRing(
                                    shape: RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value),
                                    focused: true, surface: .paper)
                            }
                            .accessibilityLabel("Press the keys you want. Esc cancels.")
                    } else {
                        PerchButton(shortcut.display, kind: .soft, size: .small, action: beginRecording)
                            .help("Click, then press the keys you want to use")
                        PerchButton("Change", kind: .quiet, size: .small, action: beginRecording)
                            .accessibilityLabel("Change shortcut")
                        if shortcut != .default {
                            PerchButton("Use ⌥N", kind: .quiet, size: .small) { choose(.default) }
                        }
                    }
                }
                if recording {
                    Text("Press the keys you want. Esc cancels.")
                        .perchFont(.detail).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem).perchFont(.detail).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { shortcut = store.map { ShortcutPreferenceSync.key($0.prefs.openShortcut) } ?? ShortcutStore.load() }
        .onChange(of: store?.prefs.openShortcut) { _, value in
            if let value { shortcut = ShortcutPreferenceSync.key(value) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didFail)) { note in
            if let store, let rejected = note.userInfo?["key"] as? ShortcutKey,
                let restored = note.userInfo?["restored"] as? ShortcutKey,
                Self.currentKey(in: store) != rejected && Self.currentKey(in: store) != restored
            {
                return
            }
            recording = false
            shortcut = note.userInfo?["restored"] as? ShortcutKey ?? ShortcutStore.load()
            problem = AppL10n.format("macOS wouldn't give up that combination. Kept %@.", shortcut.display)
        }
    }

    private func beginRecording() {
        problem = nil
        recording = true
    }

    private func choose(_ key: ShortcutKey) {
        recording = false
        problem = nil
        if let store {
            guard Self.save(key, in: store) else { return }
            // The application-wide synchronizer updates the live registration after publication.
        } else {
            ShortcutStore.save(key)
        }
        shortcut = key
    }

    private static func currentKey(in store: PlannerStore) -> ShortcutKey {
        ShortcutPreferenceSync.key(store.prefs.openShortcut)
    }

    static func save(_ key: ShortcutKey, in store: PlannerStore) -> Bool {
        guard key.isValid else { return false }
        return store.apply { try $0.updatePreference(.openShortcut(ShortcutPreferenceSync.preference(key))) } != nil
    }
}

/// Retains the legacy hot-key bridge while making the typed device preference authoritative.
/// Lives independently of Settings so a reload or Undo also changes the live shortcut.
@MainActor
final class ShortcutPreferenceSync {
    static let migrationKey = "perch.shortcutPreferenceMigrated"
    private var observations = Set<AnyCancellable>()
    private var pendingRestore: (rejected: ShortcutKey, restored: ShortcutKey)?
    private weak var store: PlannerStore?
    private let defaults: UserDefaults

    static func key(_ value: OpenShortcut) -> ShortcutKey {
        ShortcutKey.validated(ShortcutKey(keyCode: value.keyCode, modifiers: .init(rawValue: value.modifiers)))
    }

    static func preference(_ key: ShortcutKey) -> OpenShortcut {
        OpenShortcut(keyCode: key.keyCode, modifiers: key.modifiers.rawValue)
    }

    static func connect(store: PlannerStore, defaults: UserDefaults = .standard) -> AnyCancellable {
        let sync = ShortcutPreferenceSync(store: store, defaults: defaults)
        return AnyCancellable { withExtendedLifetime(sync) {} }
    }

    init(store: PlannerStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        // Import a customized old shortcut once. A typed nondefault choice wins over old defaults.
        if !defaults.bool(forKey: Self.migrationKey) {
            let legacy = ShortcutStore.load(defaults: defaults)
            if store.prefs.openShortcut == OpenShortcut(), legacy != .default {
                guard
                    store.performMutation(
                        origin: .background,
                        {
                            try $0.updatePreference(.openShortcut(Self.preference(legacy)))
                        }) != nil
                else { return }
            }
            defaults.set(true, forKey: Self.migrationKey)
        }
        // Retain failed storage restorations until the next publication, even if the chord is unchanged.
        store.$planner.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.synchronize() }.store(in: &observations)
        NotificationCenter.default.publisher(for: ShortcutStore.didFail)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let store = self.store,
                    let rejected = note.userInfo?["key"] as? ShortcutKey,
                    let restored = note.userInfo?["restored"] as? ShortcutKey,
                    Self.key(store.prefs.openShortcut) == rejected
                else { return }
                self.pendingRestore = (rejected, restored)
                self.synchronize()
            }.store(in: &observations)
        // Subscribe before the first registration attempt so a launch-time rejection is persisted too.
        ShortcutStore.save(Self.key(store.prefs.openShortcut), defaults: defaults)
    }

    private func synchronize() {
        guard let store else { return }
        let desired = Self.key(store.prefs.openShortcut)
        if let pending = pendingRestore {
            if desired == pending.rejected {
                if store.performMutation(
                    origin: .background,
                    {
                        try $0.updatePreference(.openShortcut(Self.preference(pending.restored)))
                    }) != nil
                {
                    pendingRestore = nil
                }
                return
            }
            pendingRestore = nil
        }
        if ShortcutStore.load(defaults: defaults) != desired { ShortcutStore.save(desired, defaults: defaults) }
    }
}

/// One key press, captured straight from the window so command combinations never reach the menu bar.
private final class ShortcutRecorderView: NSView {
    var onRecord: ((ShortcutKey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) { capture(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        return capture(event) || super.performKeyEquivalent(with: event)
    }

    /// Escape cancels; anything that is not a usable chord beeps and keeps listening.
    @discardableResult
    private func capture(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(ShortcutKey.escapeKeyCode) { onCancel?(); return true }
        guard let key = ShortcutKey(event: event) else { NSSound.beep(); return true }
        onRecord?(key)
        return true
    }
}

extension ShortcutRecorderView: KeysShortcutInputOwner {}

private struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (ShortcutKey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onRecord = onRecord
        view.onCancel = onCancel
        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }
}
