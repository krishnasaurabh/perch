"""Structural guard for the single native project action; native runs stay on macOS.

The delete control on a project card's options popover is one AppKit button that
owns focus, accessibility and activation. These checks keep that shape: a paint
only SwiftUI label, one transparent native target, and no second focus proxy.
What the button does with a real Space key is observed by the macOS probes.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"
PROJECTS = ROOT / "Sources/PerchApp/Settings/ProjectsList.swift"


def delete_control(source):
    return source.split("private struct ProjectDeleteButton: View", 1)[1].split(
        "private struct ProjectDeleteTarget", 1)[0]


def action_class(source):
    return source.split("final class DashboardProjectActionView: NSButton", 1)[1]


def update_view(source):
    body = source.split("private struct ProjectDeleteTarget", 1)[1]
    return body.split("#if DEBUG", 1)[0]


class DashboardProjectActionArchitectureTests(unittest.TestCase):
    def test_project_action_has_one_native_target_and_no_swiftui_focus_proxy(self):
        shell = SHELL.read_text()
        control = delete_control(PROJECTS.read_text())
        # The paint carries no focus and no second copy of the action; both belong
        # to the single transparent NSButton the representable mounts.
        self.assertIn("Text(AppL10n.text(\"Delete project\"))", control)
        self.assertIn("ProjectDeleteTarget(", control)
        self.assertNotIn(".focusable(", control)
        self.assertNotIn("@FocusState", control)
        self.assertNotIn("Button(", control)
        self.assertNotIn("onKeyPress", control)
        body = action_class(shell)
        self.assertIn("final class DashboardProjectActionView: NSButton", shell)
        self.assertEqual(shell.count("final class DashboardProjectActionView: NSButton"), 1)
        self.assertIn("isTransparent = true", body)
        self.assertIn("focusRingType = .none", body)
        self.assertIn("setButtonType(.momentaryPushIn)", body)
        self.assertIn("action = #selector(activateProjectAction(_:))", body)
        self.assertIn("setAccessibilityIdentifier(\"dashboard-project-delete\")", body)
        self.assertIn("setAccessibilityLabel(title)", body)

    def test_only_the_paint_is_accessibility_hidden(self):
        shell = SHELL.read_text()
        # One hidden paint keeps the native button as the sole accessible element.
        self.assertEqual(PROJECTS.read_text().count(".accessibilityHidden(true)"), 1)
        control = delete_control(PROJECTS.read_text())
        self.assertIn(".accessibilityHidden(true)", control)
        self.assertLess(control.index(".accessibilityHidden(true)"),
                        control.index("ProjectDeleteTarget("))
        self.assertIn("setAccessibilityIdentifier(\"dashboard-project-delete\")", action_class(shell))

    def test_disabled_or_hidden_actions_never_become_first_responder(self):
        shell = SHELL.read_text()
        body = action_class(shell)
        self.assertIn("override var acceptsFirstResponder: Bool "
                      "{ isEnabled && !isHiddenOrHasHiddenAncestor }", body)
        self.assertIn("guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }", body)
        target = update_view(PROJECTS.read_text())
        self.assertIn("view.isEnabled = enabled", target)
        # Losing enablement while focused must drop the responder, not keep a
        # key-convertible button that can no longer act.
        self.assertIn("if !enabled, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }",
                      target)

    def test_space_is_one_path_with_exact_window_and_focus_checks(self):
        shell = SHELL.read_text()
        body = action_class(shell)
        key_down = body.split("override func keyDown(with event: NSEvent) {", 1)[1].split(
            "override func keyUp(with event: NSEvent) {", 1)[0]
        self.assertIn("if event.keyCode == 49 {", key_down)
        # Exactly one deliberate activation path: the modifiers, repeat, window,
        # key-window and first-responder checks all have to hold first.
        self.assertIn("guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,",
                      key_down)
        self.assertIn("!event.isARepeat, event.window === window,", key_down)
        self.assertIn("window?.isKeyWindow == true, window?.firstResponder === self, acceptsFirstResponder",
                      key_down)
        self.assertIn("withActivationEvent(event) { performClick(nil) }", key_down)
        self.assertIn("return", key_down.split("withActivationEvent(event) { performClick(nil) }", 1)[1])
        space_branch = key_down.split("if event.keyCode == 49 {", 1)[1].split("if event.keyCode == 48", 1)[0]
        self.assertNotIn("super.keyDown(with: event)", space_branch)
        key_up = body.split("override func keyUp(with event: NSEvent) {", 1)[1].split(
            "override func performClick", 1)[0]
        self.assertIn("if event.keyCode == 49 { return }", key_up)
        self.assertIn("override func performKeyEquivalent(with event: NSEvent) -> Bool {", body)
        self.assertIn("withActivationEvent(event) { super.performKeyEquivalent(with: event) }", body)

    def test_activation_rejects_modified_repeated_and_foreign_space(self):
        body = action_class(SHELL.read_text())
        press = body.split("override func performClick(_ sender: Any?) {", 1)[1].split(
            "override func performKeyEquivalent", 1)[0]
        self.assertIn("if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 49,", press)
        self.assertIn("!event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty "
                      "|| event.isARepeat", press)
        self.assertIn("return", press)
        self.assertIn("super.performClick(sender)", press)
        action = body.split("@objc private func activateProjectAction(_ sender: Any?) {", 1)[1]
        self.assertIn("guard window != nil, acceptsFirstResponder else { return }", action)
        self.assertIn("if let event = activationEvent, event.type == .keyDown || event.type == .keyUp {", action)
        self.assertIn("guard event.type == .keyDown, event.keyCode == 49,", action)
        self.assertIn("!event.isARepeat, event.window === window,", action)
        self.assertIn("window?.isKeyWindow == true, window?.firstResponder === self", action)
        self.assertLess(action.index("guard event.type == .keyDown"), action.index("onAction()"))
        self.assertIn("onAction()", action)

    def test_project_deletion_reaches_the_store_transaction(self):
        shell = SHELL.read_text()
        projects = PROJECTS.read_text()
        # The card's visible options control opens the popover; the popover carries
        # the native action; the action runs the store's own delete transaction.
        self.assertIn(".popover(isPresented: $options)", projects)
        self.assertIn("ProjectDeleteButton { delete() }", projects)
        self.assertIn("options = false\n        store.apply { try $0.deleteProject(project.id) }", projects)
        # Only the projects tab links the native actions into the key loop.
        self.assertIn("host.selectionState?.tab == .projects", shell)
        self.assertIn("descendants(root).compactMap({ $0 as? DashboardProjectActionView })", shell)
        self.assertIn(".filter { action in action.canBecomeKeyView }", shell)
        self.assertIn("tabs.nextKeyView = first", shell)
        self.assertIn("action.nextKeyView =", shell)


if __name__ == "__main__":
    unittest.main()
