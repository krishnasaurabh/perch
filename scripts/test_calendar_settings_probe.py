"""Portable checks for the Calendar probe; native rendering still runs on macOS."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts/allpage_matrix_probe.swift"


def function(source, name):
    start = source.index("func " + name + "(")
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return "@MainActor\n" + textwrap.dedent(source[start:end + 1])
    raise AssertionError("Unclosed function " + name)


class CalendarSettingsProbeTests(unittest.TestCase):
    def test_segment_selector_rejects_missing_ambiguous_and_disabled_controls(self):
        selector = function(PROBE.read_text(), "calendarSegment")
        policy = function(PROBE.read_text(), "calendarPermissionMatches")
        program = r'''
import Foundation
struct MatrixElement: Hashable { let id: Int }
struct Node {
    var role: String
    var names: [String]
    var enabled: Bool? = nil
    var children: [MatrixElement] = []
    var identifier: String? = nil
}
struct MatrixFailure: Error { let label: String }
enum AppL10n { static func text(_ value: String) -> String { value } }
enum PermissionState: CaseIterable {
    case checking, allowed, notDetermined, denied, restricted, limited, revoked, unavailable
    var title: String { String(describing: self) }
}
@MainActor enum Fixture { static var nodes: [MatrixElement: Node] = [:] }
@MainActor func mxTree(_ root: MatrixElement) -> [MatrixElement] {
    [root] + (Fixture.nodes[root]?.children ?? []).flatMap { mxTree($0) }
}
@MainActor func mxRole(_ node: MatrixElement) -> String? { Fixture.nodes[node]?.role }
@MainActor func mxNames(_ node: MatrixElement) -> [String] { Fixture.nodes[node]?.names ?? [] }
@MainActor func mxEnabled(_ node: MatrixElement) -> Bool? { Fixture.nodes[node]?.enabled }
@MainActor func mxIdentifier(_ node: MatrixElement) -> String? { Fixture.nodes[node]?.identifier }
@MainActor func mxHas(_ root: MatrixElement, _ text: String) -> Bool {
    mxTree(root).contains { mxNames($0).contains(text) }
}
''' + selector + '\n' + policy + r'''
@MainActor func reset(_ enabled: Bool?) -> MatrixElement {
    let root = MatrixElement(id: 0), group = MatrixElement(id: 1)
    let segment = MatrixElement(id: 2), label = MatrixElement(id: 3)
    Fixture.nodes = [
        root: Node(role: "AXWindow", names: [], children: [group, label]),
        group: Node(role: "AXGroup", names: ["Edits made on your phone"], children: [segment]),
        segment: Node(role: "AXButton", names: ["Ignore"], enabled: enabled),
        label: Node(role: "AXStaticText", names: ["Ignore"], enabled: true),
    ]
    return root
}
@MainActor func rejects(_ root: MatrixElement, _ expected: Bool) {
    do {
        _ = try calendarSegment(root, name: "Ignore", expectedEnabled: expected)
        fatalError("invalid segment accepted")
    } catch is MatrixFailure {} catch { fatalError("unexpected error") }
}
MainActor.assumeIsolated {
    for enabled in [false, true] {
        let root = reset(enabled)
        precondition(try! calendarSegment(root, name: "Ignore", expectedEnabled: enabled) == MatrixElement(id: 2))
        rejects(root, !enabled)
        Fixture.nodes[MatrixElement(id: 1)]?.children = []
        rejects(root, enabled)
        _ = reset(enabled)
        Fixture.nodes[MatrixElement(id: 2)]?.role = "AXStaticText"
        rejects(root, enabled)
        _ = reset(enabled)
        Fixture.nodes[MatrixElement(id: 4)] = Fixture.nodes[MatrixElement(id: 2)]
        Fixture.nodes[MatrixElement(id: 1)]?.children.append(MatrixElement(id: 4))
        rejects(root, enabled)
        _ = reset(enabled)
        Fixture.nodes[MatrixElement(id: 5)] = Fixture.nodes[MatrixElement(id: 1)]
        Fixture.nodes[MatrixElement(id: 0)]?.children.append(MatrixElement(id: 5))
        rejects(root, enabled)
        _ = reset(enabled)
        Fixture.nodes[MatrixElement(id: 1)]?.role = "AXStaticText"
        rejects(root, enabled)
        _ = reset(enabled)
        Fixture.nodes[MatrixElement(id: 0)]?.children = [MatrixElement(id: 3)]
        rejects(root, enabled)
    }
    rejects(reset(nil), true)
    let root = MatrixElement(id: 10), row = MatrixElement(id: 11), duplicate = MatrixElement(id: 12)
    for state in PermissionState.allCases {
        Fixture.nodes = [root: Node(role: "AXWindow", names: [])]
        let hidden = [PermissionState.checking, .allowed, .notDetermined].contains(state)
        precondition(calendarPermissionMatches(root, feature: "calendar", state: state) == hidden)
        Fixture.nodes[row] = Node(role: "AXGroup", names: [state.title], identifier: "permission-row.calendar")
        Fixture.nodes[root]?.children = [row]
        precondition(calendarPermissionMatches(root, feature: "calendar", state: state) == !hidden)
        Fixture.nodes[row]?.names = ["wrong state"]
        precondition(!calendarPermissionMatches(root, feature: "calendar", state: state))
        Fixture.nodes[row]?.names = [state.title]
        Fixture.nodes[duplicate] = Fixture.nodes[row]
        Fixture.nodes[root]?.children.append(duplicate)
        precondition(!calendarPermissionMatches(root, feature: "calendar", state: state))
    }
}
print("calendar segment and permission positive and negative controls passed")
'''
        swift = shutil.which("swiftc")
        self.assertIsNotNone(swift)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calendar-segment.swift"
            path.write_text(program)
            executable = Path(directory) / "calendar-segment"
            built = subprocess.run([swift, "-swift-version", "6", str(path), "-o", str(executable)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn("positive and negative controls passed", ran.stdout)

    def test_native_probe_checks_recovery_and_actual_segment_persistence(self):
        source = PROBE.read_text().split("func settingsFailurePaths()", 1)[1].split("// MARK: Dashboard", 1)[0]
        for requirement in (
            "CalendarProbeAccess", "SettingsCalendarPane.probe(", "model: calendarModel",
            'feature: "calendar"', 'feature: "reminders"', "PermissionState.denied.title",
            "calendarAccess.states[.calendar] = PermissionReading(.allowed)",
            "calendarAccess.states[.reminders] = PermissionReading(.allowed)",
            'name: "Ignore", expectedEnabled: false', 'name: "Ignore", expectedEnabled: true',
            'name: "Bring back", expectedEnabled: false', 'name: "Bring back", expectedEnabled: true',
            "calendarModel.setPhoneEdits(.bringBack)", "preferences.phoneEdits == .ignore",
            "calendarAccess.requests.isEmpty", "EKEventStore.authorizationStatus(for: .event) == calendarBefore",
            "EKEventStore.authorizationStatus(for: .reminder) == reminderBefore",
        ):
            self.assertIn(requirement, source)
        self.assertNotIn('AppL10n.text("Alert on iPhone and Apple Watch too")', source)
        self.assertIn('mxClick(host: calendarHost, window: calendarWindow, screenRect: mxFrame(ignore))', source)
        self.assertIn('mxKey(confirmation, 53, "\\u{1b}")', source)
        self.assertIn('calendarWindow.attachedSheet', source)

    def test_injected_model_uses_the_production_content_and_is_test_only(self):
        source = (ROOT / "Sources/PerchApp/Settings/SettingsCalendarPane.swift").read_text()
        self.assertIn("struct SettingsCalendarContent: View", source)
        seam = source.split("/// Exercise the same content", 1)[1].split("#endif", 1)[0]
        self.assertIn("model: CalendarSettingsModel", seam)
        self.assertIn("StateObject(wrappedValue: model.permissions)", seam)
        self.assertIn("StateObject(wrappedValue: model)", seam)


if __name__ == "__main__":
    unittest.main()