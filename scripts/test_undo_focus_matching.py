"""Portable controls for native selector bodies, not macOS accessibility evidence."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class UndoFocusMatchingTests(unittest.TestCase):
    def run_swift(self, source, succeeds=True):
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to exercise selector bodies")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "main.swift"
            binary = pathlib.Path(directory) / "selectors"
            path.write_text(source)
            built = subprocess.run([swift, "-swift-version", "6", "-parse-as-library", str(path), "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True)
            if succeeds:
                self.assertEqual(ran.returncode, 0, ran.stderr)
            else:
                self.assertNotEqual(ran.returncode, 0, "negative selector control unexpectedly passed")

    def test_undo_identifier_lookup_and_exact_label_fallback(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        body = "@MainActor\nfunc control(" + source.split("func control(", 1)[1].split("// Unlabelled Text", 1)[0]
        support = '''import Foundation
final class Element: NSObject {
    let attributes: [String: String]
    init(_ attributes: [String: String]) { self.attributes = attributes }
}
class NSView: NSObject {
    let elements: [NSObject]
    init(_ elements: [NSObject] = []) { self.elements = elements }
    func layoutSubtreeIfNeeded() {}
}
final class NSTextField: NSView {
    let isEditable: Bool
    let placeholderString: String?
    let label: String?
    init(editable: Bool, label: String? = nil, placeholder: String? = nil) {
        isEditable = editable; self.label = label; placeholderString = placeholder
        super.init()
    }
    func accessibilityLabel() -> String? { label }
}
final class NSButton: NSView {
    let title: String
    let label: String?
    init(title: String, label: String? = nil) {
        self.title = title; self.label = label; super.init()
    }
    func accessibilityLabel() -> String? { label }
}
@MainActor func nodes(_ root: NSView) -> [NSObject] { root.elements }
@MainActor func attr(_ node: NSObject, _ key: String) -> Any? { (node as? Element)?.attributes[key] }
'''
        checks = '''
@main struct Run {
    @MainActor static func main() {
        for identifier in ["today-undo", "notch.undo"] {
            let exact = Element(["accessibilityIdentifier": identifier])
            let unrelated = Element(["accessibilityLabel": "Delete"])
            let root = NSView([unrelated, exact])
            precondition(control("Undo", in: root) === exact)
            precondition(control("Delete", in: root) === unrelated)
            precondition(control(identifier, attribute: "accessibilityIdentifier", in: root) === exact)
            precondition(control("Missing", in: root) == nil)
        }
        let labelled = Element(["accessibilityLabel": "Undo"])
        precondition(control("Undo", in: NSView([labelled])) === labelled)
        precondition(control("Undo", in: NSView([])) == nil)
        let field = NSTextField(editable: true, placeholder: "Add a task")
        let labelField = NSTextField(editable: true, label: "Entry")
        let readonly = NSTextField(editable: false, placeholder: "Read only")
        let button = NSButton(title: "Bring over")
        let labelButton = NSButton(title: "", label: "Review")
        let controls = NSView([field, labelField, readonly, button, labelButton])
        precondition(control("Add a task", in: controls) === field)
        precondition(control("Entry", in: controls) === labelField)
        precondition(control("Bring over", in: controls) === button)
        precondition(control("Review", in: controls) === labelButton)
        precondition(control("Read only", in: controls) == nil)
    }
}
'''
        self.run_swift(support + body + checks)
        old = '''@MainActor
func control(_ value: String, attribute: String = "accessibilityLabel", in root: NSView) -> NSObject? {
    nodes(root).first { attr($0, attribute) as? String == value }
}
'''
        self.run_swift(support + old + checks, succeeds=False)

    def test_clips_focused_identifier_or_exact_name_and_wrong_clip_rejection(self):
        source = (ROOT / "scripts/allpage_matrix_probe.swift").read_text()
        marker = 'tag: "clipsCopyTraversal") { identity, _ in'
        predicate = source.split(marker, 1)[1].split('\n        }', 1)[0]
        support = '''import Foundation
struct Clip { let id: String }
struct MatrixElement { let names: [String] }
@MainActor enum State { static var focused: MatrixElement? }
@MainActor func mxFocusedElement() -> MatrixElement? { State.focused }
@MainActor func mxNames(_ element: MatrixElement) -> [String] { element.names }
@main struct Run {
    @MainActor static func main() {
        let first = Clip(id: "first")
        let copyLabel = "Copy Matrix clip one"
        func matches(_ identity: String) -> Bool {
'''
        checks = '''
        }
        State.focused = MatrixElement(names: [copyLabel])
        precondition(matches("shelf.item.first"))
        precondition(matches("another.identifier"))
        precondition(matches(copyLabel))
        State.focused = MatrixElement(names: ["Copy Matrix clip two"])
        precondition(!matches("shelf.item.second"))
        State.focused = MatrixElement(names: [])
        precondition(matches("shelf.item.first"))
        precondition(!matches("shelf.item.second"))
        State.focused = nil
        precondition(!matches("none"))
    }
}
'''
        self.run_swift(support + predicate + checks)
        self.run_swift(support + '\n            identity == copyLabel\n' + checks, succeeds=False)

    def test_edits_share_one_viewport_undo_without_moving_capture(self):
        tasks = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        viewport = tasks.split('GeometryReader { viewport in', 1)[1].split('TaskComposer(', 1)[0]
        self.assertIn('.safeAreaInset(edge: .bottom, spacing: 8)', viewport)
        self.assertIn('footer.modifier(NotchUndoFooter())', viewport)
        self.assertNotIn('hasCompletionUndo', viewport)
        self.assertEqual(tasks.count('footer.modifier('), 1)
        footer = tasks.split('private var footer: some View {', 1)[1].split('@ViewBuilder private var overdueFooter:', 1)[0]
        for unchanged in ('Label("Undo", systemImage: "arrow.uturn.backward")',
                          '.accessibilityIdentifier("today-undo")', '.focused($focus, equals: .undo)',
                          'if press.phase == .down { store.undo() }'):
            self.assertIn(unchanged, footer)
        strips = (ROOT / "Sources/PerchApp/Notch/NotchStrips.swift").read_text()
        self.assertIn('guard model.geometry == nil, let activity = model.strips?.currentActivity, activity.stripKind == .undo', strips)
        decoration = strips.split('struct NotchUndoFooter: ViewModifier {', 1)[1].split('private var inlineActivity', 1)[0]
        self.assertEqual(decoration.splitlines().count('            content'), 1)
        overdue = tasks.split('@ViewBuilder private var overdueFooter: some View {', 1)[1].split('private func select(', 1)[0]
        self.assertIn('if !store.engine.bringOverCandidates().isEmpty', overdue)
        self.assertIn('Button("Bring over")', overdue)
        self.assertIn('.accessibilityIdentifier("today-review-overdue")', overdue)
        self.assertIn('.disabled(!showsFooterUndo).focusable(store.canUndo)', footer)
        self.assertLess(tasks.index('footer.modifier(NotchUndoFooter('), tasks.index('TaskComposer('))
        self.assertLess(tasks.index('TaskComposer('), tasks.index('overdueFooter.fixedSize'))

    def test_shared_footer_has_one_undo_for_each_history_presentation(self):
        tasks = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        body = tasks.split('private var showsFooterUndo: Bool {', 1)[1].split('\n    }', 1)[0]
        support = '''
enum Kind { case undo }
struct Activity { let stripKind: Kind }
struct Strips { let hasCompletionUndo: Bool; let currentActivity: Activity? }
struct Model { let strips: Strips?; let geometry: Int? }
struct Store { let canUndo: Bool }
func showsFooterUndo(store: Store, model: Model) -> Bool {
'''
        checks = '''
}
@main struct Run {
    static func main() {
        for physicalNotch in [false, true] {
            for canUndo in [false, true] {
                for kind in ["generic", "completion", "deletion", "uninstalled"] {
                    let completion = kind == "completion"
                    let deletion = kind == "deletion"
                    let strips: Strips? = kind == "uninstalled" ? nil : Strips(
                        hasCompletionUndo: completion,
                        currentActivity: deletion ? Activity(stripKind: .undo) : nil)
                    let model = Model(strips: strips, geometry: physicalNotch ? 1 : nil)
                    let footer = showsFooterUndo(store: Store(canUndo: canUndo), model: model)
                    let viewport = footer
                    // The separately identified notch.undo never borrows Today's focus binding.
                    let stripOwnsTodayFocus = false
                    let visible = [viewport, stripOwnsTodayFocus].filter { $0 }.count
                    precondition(visible == (canUndo ? 1 : 0), "Undo must have exactly one reachable owner")
                    precondition(footer == canUndo, "The viewport destination must survive every strip state")
                }
            }
        }
    }
}
'''
        self.run_swift(support + body + checks)
        self.run_swift(support + '\ntrue\n' + checks, succeeds=False)
        self.run_swift(support + '\nfalse\n' + checks, succeeds=False)
        former = '''
        store.canUndo && model.strips?.hasCompletionUndo != true
            && (model.geometry == nil || model.strips?.currentActivity?.stripKind != .undo)
'''
        self.run_swift(support + former + checks, succeeds=False)


if __name__ == "__main__":
    unittest.main()
