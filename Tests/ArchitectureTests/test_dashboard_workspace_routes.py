"""Compile the More menu's dashboard routes without substituting their bodies.

These portable adapters verify callback dispatch, not native menu presentation.
"""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class DashboardWorkspaceRouteTests(unittest.TestCase):
    def test_more_routes_use_current_tabs_and_the_shared_window_owner(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        method = source.split("    private func showMoreMenu() {", 1)[1].split("\n    }", 1)[0]
        tabs = (ROOT / "Sources/PerchApp/Settings/DashboardView.swift").read_text()
        cases = tabs.split("    enum Tab: String, CaseIterable {", 1)[1].split("\n\n", 1)[0]
        program = """import Foundation
@MainActor private final class PlannerStore {}
@MainActor private final class Services {}
private enum DashboardView {
    enum Tab: String, CaseIterable {""" + cases + """
    }
}
@MainActor private enum DashboardWindow {
    static var calls: [DashboardView.Tab] = []
    static func show(store: PlannerStore, tab: DashboardView.Tab) { calls.append(tab) }
}
@MainActor private enum SettingsWindow {
    static var calls = 0
    static func show(store: PlannerStore, services: Services) { calls += 1 }
}
@MainActor private enum WorkspaceWindowRegistry {
    static var keys: ((PlannerStore) -> Void)?
    static func openKeys(store: PlannerStore) -> Bool {
        guard let keys else { return false }
        keys(store)
        return true
    }
}
@MainActor private final class MenuAnchor {
    var callbacks: [() -> Void] = []
    var keysAvailable = false
    func show(keysAvailable: Bool, yourWeek: @escaping () -> Void,
              history: @escaping () -> Void, projects: @escaping () -> Void,
              settings: @escaping () -> Void, keys: @escaping () -> Void) {
        self.keysAvailable = keysAvailable
        callbacks = [yourWeek, history, projects, settings, keys]
    }
}
@MainActor private struct Harness {
    var enabled = true
    let store = PlannerStore()
    let services = Services()
    let moreAnchor = MenuAnchor()
    func showMoreMenu() {""" + method + """
    }
}
private var harness = Harness()
var keyCalls = 0
WorkspaceWindowRegistry.keys = { _ in keyCalls += 1 }
harness.showMoreMenu()
precondition(harness.moreAnchor.keysAvailable)
precondition(harness.moreAnchor.callbacks.count == 5)
for callback in harness.moreAnchor.callbacks { callback() }
precondition(DashboardWindow.calls == [.yourWeek, .history, .projects])
precondition(SettingsWindow.calls == 1 && keyCalls == 1)
// Reopening any section uses the same owner, rather than replacing its host.
harness.moreAnchor.callbacks[1]()
precondition(DashboardWindow.calls == [.yourWeek, .history, .projects, .history])
harness.enabled = false
harness.moreAnchor.callbacks = []
harness.showMoreMenu()
precondition(harness.moreAnchor.callbacks.isEmpty)
print("Dashboard menu route controls passed")
"""
        swift = shutil.which("swiftc")
        self.assertIsNotNone(swift, "Swift must be available for the route regression")
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            binary = pathlib.Path(directory) / "dashboard-routes"
            compiled = subprocess.run(
                [swift, "-swift-version", "6", str(main), "-o", str(binary)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Dashboard menu route controls passed", result.stdout)

    def test_native_more_menu_has_no_removed_dashboard_callback(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        anchor = source.split("private final class WorkspaceMenuAnchorView", 1)[1].split("struct IDBox:", 1)[0]
        self.assertNotIn("DashboardWindow.installMenuItems", anchor)
        self.assertIn("actions = [yourWeek, history, projects, settings, keys]", anchor)
        self.assertIn("defer { actions.removeAll() }", anchor)


if __name__ == "__main__":
    unittest.main()
