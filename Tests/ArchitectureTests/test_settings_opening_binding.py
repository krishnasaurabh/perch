"""Exercise Settings' actual binding and activation policy with real Core storage.

Only SwiftUI Binding, AppKit events, and the app store's publication wrapper are
adapted. This does not claim native pointer delivery; the app suite covers that.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_closed_click_opening import declaration

ROOT = Path(__file__).resolve().parents[2]


class SettingsOpeningBindingTests(unittest.TestCase):
    def test_settings_choice_survives_migration_reload_and_routes_activation(self):
        source = (ROOT / "Sources/PerchApp/Settings/SettingsNotchPane.swift").read_text()
        selection = re.search(r'Picker\("Open the notch on", selection: (.+)\) \{', source)
        if selection is None:
            self.fail("Exercise the live Settings picker, not a separate policy")
        helper = (declaration(source, "static func openingPreference(")
                  if "static func openingPreference(" in source else "")
        activation = declaration(
            (ROOT / "Sources/PerchApp/Notch/NotchGlanceCapsule.swift").read_text(),
            "func activateClosed(")
        program = r'''
import Foundation
struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
}
@MainActor final class PlannerStore {
    let file: PlannerFile
    let pipeline: PlannerCommandPipeline
    var prefs: Preferences { try! file.load().preferences }
    init(file: PlannerFile) { self.file = file; pipeline = PlannerCommandPipeline(file: file) }
    func updatePrefs(_ body: (inout Preferences) -> Void) {
        _ = try! pipeline.perform(origin: .user) { try $0.updatePrefs(body) }
    }
}
struct NSEvent {
    enum EventType { case leftMouseDown, leftMouseUp, keyDown, keyUp }
    let type: EventType
    let clickCount: Int
}
@MainActor enum NSApp { static var currentEvent: NSEvent? }
struct NotchScreenState { let id: Int; let geometry: Int }
enum NotchPage: Sendable { case home }
extension Notification.Name { static let perchOpenWorkspace = Self("perchOpenWorkspace") }
@MainActor struct SettingsView {
    let store: PlannerStore
''' + helper + r'''
    func selection() -> Binding<NotchOpenTrigger> { SELECTION }
}
@MainActor final class NotchModel {
    var screenID = 0
    var geometry: Int?
''' + activation + r'''
}
func require(_ value: Bool, _ message: String) {
    if !value { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
@MainActor func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let screen = NotchScreenState(id: 73, geometry: 42)
    var checks = 0
    func activation(_ store: PlannerStore, single: Bool, double: Bool, context: String) {
        let cases: [(NSEvent?, Bool)] = [
            (NSEvent(type: .leftMouseDown, clickCount: 1), single),
            (NSEvent(type: .leftMouseUp, clickCount: 1), single),
            (NSEvent(type: .leftMouseDown, clickCount: 2), double),
            (NSEvent(type: .leftMouseUp, clickCount: 2), double),
            (NSEvent(type: .keyDown, clickCount: 0), true),
            (nil, true),
        ]
        for (event, expected) in cases {
            NSApp.currentEvent = event
            let model = NotchModel()
            model.activateClosed(in: store, on: screen)
            require(model.screenID == (expected ? screen.id : 0), "\(context): \(String(describing: event))")
            require(model.geometry == (expected ? screen.geometry : nil), "\(context): geometry")
            checks += 1
        }
    }
    for initial in [NotchOpenTrigger.nothing, .hover] {
        let url = root.appendingPathComponent("\(initial.rawValue).json")
        let legacy = try JSONSerialization.data(withJSONObject: [
            "version": 1, "preferences": ["notchOpenTrigger": initial.rawValue],
        ])
        try legacy.write(to: url)
        var adapter = MemoryPlannerPreferences()
        var store = PlannerStore(file: PlannerFile(url: url, preferences: adapter))
        require(!store.prefs.notchClickToOpen, "Legacy \(initial) migrates click off")
        try store.file.save(store.file.load())
        func reload() throws -> PlannerStore {
            let bytes = try JSONEncoder().encode(adapter.load()!)
            adapter = MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: bytes))
            return PlannerStore(file: PlannerFile(url: url, preferences: adapter))
        }
        store = try reload()
        require(store.prefs.notchOpenTrigger == initial && !store.prefs.notchClickToOpen,
                "Migrated preferences survive reload")
        activation(store, single: false, double: false, context: "migrated \(initial)")
        SettingsView(store: store).selection().wrappedValue = .click
        store = try reload()
        require(store.prefs.notchOpenTrigger == .click && store.prefs.notchClickToOpen,
                "Settings Click persists opt-in after migrated \(initial)")
        activation(store, single: true, double: true, context: "Click after \(initial)")
        SettingsView(store: store).selection().wrappedValue = .hover
        store = try reload()
        require(store.prefs.notchOpenTrigger == .hover && store.prefs.notchClickToOpen,
                "Hover preserves click on")
        activation(store, single: true, double: true, context: "Hover with click on")
        SettingsView(store: store).selection().wrappedValue = .doubleClick
        store = try reload()
        require(store.prefs.notchOpenTrigger == .doubleClick && !store.prefs.notchClickToOpen,
                "Double-click disables single click after reload")
        activation(store, single: false, double: true, context: "Double-click")
        SettingsView(store: store).selection().wrappedValue = .hover
        store = try reload()
        require(store.prefs.notchOpenTrigger == .hover && !store.prefs.notchClickToOpen,
                "Hover preserves click off")
        activation(store, single: false, double: false, context: "Hover with click off")
        SettingsView(store: store).selection().wrappedValue = .click
        store = try reload()
        activation(store, single: true, double: true, context: "Click re-enabled")
    }
    print("Settings migration/binding/reload/activation: \(checks) checks passed")
}
try run()
'''
        program = program.replace("SELECTION", selection.group(1))
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to execute the actual Settings binding")
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            binary = Path(folder) / "settings-opening"
            main.write_text(program)
            core = sorted((ROOT / "Sources/PlannerCore").glob("*.swift"))
            compiled = subprocess.run(
                [swift, "-swift-version", "6", *map(str, core), str(main), "-o", str(binary)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Settings migration/binding/reload/activation: 72 checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
