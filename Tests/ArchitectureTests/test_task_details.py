"""Task details keep edits local until an explicit, typed save."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TaskDetailsBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "Sources/PerchApp/Workspace/TaskDetailsSheet.swift").read_text()

    def test_details_never_autosave_or_mutate_task_fields(self):
        for forbidden in ("store.updateTask", "store.setText", "store.flushPendingText", "WritableKeyPath"):
            self.assertNotIn(forbidden, self.source)

    def test_explicit_save_and_cancel(self):
        self.assertIn('Button("Cancel")', self.source)
        self.assertIn('Button("Save")', self.source)
        self.assertIn(".keyboardShortcut(.cancelAction)", self.source)
        self.assertIn(".keyboardShortcut(.defaultAction)", self.source)

    def test_unavailable_task_keeps_an_explicit_exit(self):
        unavailable = self.source.split('"Task unavailable"', 1)[1].split("private struct TaskDetailsEditor", 1)[0]
        self.assertIn('Button("Close")', unavailable)
        self.assertIn(".keyboardShortcut(.cancelAction)", unavailable)
        self.assertIn('"details-close"', unavailable)

    def test_footer_is_reserved_outside_scrolling_form(self):
        self.assertIn("VStack(spacing: 0)", self.source)
        self.assertIn("private var form: some View", self.source)
        self.assertIn("private var footer: some View", self.source)
        layout = self.source.split("var body: some View", 2)[2].split("private var form:", 1)[0]
        self.assertIn("form", layout)
        self.assertIn("footer", layout)
        form = self.source.split("private var form:", 1)[1].split("private var footer:", 1)[0]
        self.assertIn("ScrollView", form)
        self.assertNotIn('Button("Save")', form)
        self.assertNotIn(".frame(width: 460)", self.source)

    def test_native_lookup_does_not_require_ax_client_permission(self):
        native = (ROOT / "Tests/PerchAppTests/TaskDetailsViewTests.swift").read_text()
        self.assertNotIn("AXUIElementCreateApplication", native)
        self.assertNotIn("wakeAccessibility", native)
        for fallback in ("button.title", "field.placeholderString", "accessibilityLabel"):
            self.assertIn(fallback, native)
        self.assertIn("accessibilityAttributeNames", native)
        self.assertIn("button.performClick(nil)", native)

    def test_direct_host_still_requires_identifier_publication(self):
        native = (ROOT / "Tests/PerchAppTests/TaskDetailsViewTests.swift").read_text()
        test = native.split("func testDirectHostPublishesControlIdentifiers", 1)[1].split("\n    @MainActor", 1)[0]
        for identifier in ("details-title", "details-save", "details-cancel", "details-close"):
            self.assertIn(f'identifierControl("{identifier}"', test)

    def test_native_footer_checks_effective_viewport_before_and_after_scrolling(self):
        native = (ROOT / "Tests/PerchAppTests/TaskDetailsViewTests.swift").read_text()
        test = native.split("func testFooterStaysVisible", 1)[1].split("\n    @MainActor", 1)[0]
        self.assertEqual(test.count("assertFooterOutsideViewport("), 2)
        self.assertIn("scroll.contentInsets", native)
        self.assertIn("scroll.contentView.visibleRect", native)
        self.assertIn("XCTAssertNotEqual(scroll.contentView.bounds.origin", test)
        for guarantee in ("contains(saveFrame)", "contains(cancelFrame)",
                          "Self.frame(liveSave), saveFrame", "Self.frame(liveCancel), cancelFrame"):
            self.assertIn(guarantee, test)

    def test_native_hosts_enable_the_swiftui_accessibility_tree(self):
        native = (ROOT / "Tests/PerchAppTests/TaskDetailsViewTests.swift").read_text()
        # Geometry, identifier publication and presentation each host real SwiftUI
        # content. They use the same public accessibility environment override.
        self.assertEqual(native.count(r".environment(\.accessibilityEnabled, true)"), 3)

    def test_historical_title_is_not_editable(self):
        self.assertIn(".disabled(readOnly)", self.source)
        self.assertIn('Text(draft.title)', self.source)


if __name__ == "__main__":
    unittest.main()
