"""Keep the shortcut catalog, native registration and preview wired together."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class KeysContractTests(unittest.TestCase):
    def test_every_declared_catalog_handler_is_in_the_production_registry(self):
        catalog = (ROOT / 'Sources/PerchUI/KeyMap.swift').read_text()
        native = (ROOT / 'Sources/PerchApp/Settings/KeysView.swift').read_text()
        declared = set(re.findall(r'handler: \.(\w+)', catalog))
        registry = native.split('lazy var bindings = KeyMap.Bindings(handlers: [', 1)[1].split('])', 1)[0]
        installed = re.findall(r'^\s*\.(\w+): \{', registry, re.M)
        self.assertTrue(declared)
        self.assertEqual(declared, set(installed))
        self.assertEqual(len(installed), len(set(installed)))
        # The native test inspects this same registry and verifies action effects.
        tests = (ROOT / 'Tests/PerchAppTests/KeysWindowTests.swift').read_text()
        self.assertIn('router.bindings.unboundEntries.isEmpty', tests)
        native_tests = (ROOT / 'Tests/PerchAppTests/KeysWindowNativeTests.swift').read_text()
        self.assertIn('router.handle(escape)', native_tests)
        self.assertIn('fixture.store.planner.focus?.limit, previousLimit + 300', tests)

    def test_application_launch_installs_the_router_once(self):
        app = (ROOT / 'Sources/PerchApp/App/AppDelegate.swift').read_text()
        self.assertEqual(app.count('KeysWindow.install(store: store, model: model)'), 1)
        native = (ROOT / 'Sources/PerchApp/Settings/KeysView.swift').read_text()
        self.assertIn('guard shortcuts == nil else { return }', native)
        self.assertIn('NSEvent.addLocalMonitorForEvents(matching: .keyDown)', native)
        self.assertIn('window === NSApp.keyWindow', native)
        self.assertIn('NSEvent.removeMonitor(monitor)', native)

    def test_shortcut_recorder_keeps_exclusive_input(self):
        source = (ROOT / 'Sources/PerchApp/Settings/KeysView.swift').read_text()
        recorder = (ROOT / 'Sources/PerchApp/Settings/ShortcutPreferenceRow.swift').read_text()
        self.assertIn('window.firstResponder is KeysShortcutInputOwner', source)
        self.assertIn('extension ShortcutRecorderView: KeysShortcutInputOwner {}', recorder)
        tests = (ROOT / 'Tests/PerchAppTests/KeysWindowNativeTests.swift').read_text()
        self.assertIn('testInstalledMonitorLeavesShortcutRecordingInControl', tests)

    def test_document_modal_sheet_keeps_exclusive_input(self):
        source = (ROOT / 'Sources/PerchApp/Settings/KeysView.swift').read_text()
        self.assertIn('window.isSheet', source)
        self.assertIn('window.sheetParent != nil', source)
        tests = (ROOT / 'Tests/PerchAppTests/KeysWindowNativeTests.swift').read_text()
        self.assertIn('testInstalledMonitorLeavesTaskDetailsSheetInControl', tests)

    def test_native_keyboard_checks_run_in_an_application_not_xctest(self):
        native = (ROOT / 'Tests/PerchAppTests/KeysWindowNativeTests.swift').read_text()
        self.assertIn('#if KEYS_WINDOW_NATIVE_PROBE', native)
        self.assertIn('app.setActivationPolicy(.regular)', native)
        self.assertIn('app.run()', native)
        self.assertIn('NSApp.isActive && window === NSApp.keyWindow', native)
        self.assertIn('NSApp.sendEvent(event(', native)
        self.assertIn('timeout=120', native)
        self.assertIn('XCTAssertEqual(process.terminationStatus, 0', native)
        self.assertNotIn('XCTSkip', native)
        self.assertNotIn('XCTAssert', native.split('#else', 1)[0])
        self.assertNotIn('app.run()', (ROOT / 'Tests/PerchAppTests/KeysWindowTests.swift').read_text())

    def test_sheet_reads_only_the_portable_catalog(self):
        source = (ROOT / 'Sources/PerchApp/Settings/KeysView.swift').read_text()
        self.assertIn('ForEach(KeyMap.columns[column])', source)
        self.assertIn('ForEach(group.entries)', source)
        self.assertIn('entry.keyCaps', source)
        self.assertIn('Text(entry.label)', source)
        self.assertNotIn('ViewThatFits', source)
        self.assertNotIn('keyboardShortcut(', source)
        self.assertNotRegex(source, r'Color\((?:hex:|red:)')
        self.assertIn('.perchFont(.detailStrong)', source)
        self.assertIn('DotGridSheet(.window)', source)
        self.assertIn('Card(group.surface)', source)

    def test_keys_preview_and_snapshot_are_registered(self):
        registry = (ROOT / 'Sources/PerchApp/App/AppDelegate+Preview.swift').read_text()
        self.assertIn('"keys": .window("keys") { KeysWindow.show(store: $0.store) }', registry)
        shots = (ROOT / 'scripts/redesign_shots.list').read_text().splitlines()
        self.assertEqual(shots.count('keys --scenario empty --open keys'), 1)

    def test_editors_keep_their_punctuation_and_undo(self):
        source = (ROOT / 'Sources/PerchApp/Settings/KeysView.swift').read_text()
        self.assertIn('window.firstResponder is NSTextView', source)
        self.assertIn('window.attachedSheet != nil || NSApp.modalWindow != nil', source)
        catalog = (ROOT / 'Sources/PerchUI/KeyMap.swift').read_text()
        self.assertIn('[.showKeys, .close, .undo].contains(handler)', catalog)


if __name__ == '__main__':
    unittest.main()
