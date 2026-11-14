"""Production workspace navigation contracts; native behavior lives in PerchAppTests."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WorkspacePickerContractTests(unittest.TestCase):
    def test_production_picker_uses_shared_type_target_and_focus(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        self.assertNotIn(".system(size:", source)
        self.assertIn("Theme.minimumTarget", source)
        self.assertIn("WorkspacePageStyle(selected: false, focused: moreFocused, height: bandPillHeight)", source)
        self.assertIn("FocusRing(", source)
        self.assertIn(".focused($focusedPage, equals:", source)
        self.assertIn(".focusable(on)", source)
        for key in ("leftArrow", "rightArrow", "home", "end"):
            self.assertIn(f".onKeyPress(.{key})", source)
        self.assertIn('accessibilityIdentifier("workspace-more")', source)
        self.assertIn('accessibilityIdentifier("workspace-pages")', source)

    def test_roving_focus_is_restored_only_after_the_selection_render(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        selection = source.split("private func selectPage(", 1)[1].split("private func", 1)[0]
        keyboard = source.split("private func focusPage(", 1)[1].split("private func", 1)[0]
        self.assertNotIn("focusedPage =", selection)
        self.assertNotIn("focusedPage =", keyboard)
        self.assertIn(".onChange(of: model.page)", source)
        self.assertIn(".onChange(of: focusedPage)", source)
        self.assertIn(".onKeyPress(.tab)", source)
        self.assertIn("@State private var pageGroupHasFocus = false", source)
        self.assertIn("NSWindow.didResignKeyNotification", source)
        restore = source.split("private func restorePageFocus(", 1)[1].split("private func", 1)[0]
        self.assertIn("DispatchQueue.main.async", restore)
        self.assertIn("guard pageGroupHasFocus", restore)
        self.assertIn("model.page == page", restore)
        self.assertIn("isKeyWindow == true", restore)
        self.assertIn("focusedPage = page", restore)

    def test_more_launcher_uses_the_shared_button_and_native_menu(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        launcher = source.split("private var moreMenu: some View {", 1)[1].split("private struct WorkspaceMenuAnchor", 1)[0]
        self.assertIn("Button {", launcher)
        self.assertIn(".buttonStyle(WorkspacePageStyle(selected: false, focused: moreFocused, height: bandPillHeight))", launcher)
        self.assertNotIn("Menu {", launcher, "A native Menu launcher does not consume the primitive pill style")
        self.assertNotIn(".menuStyle(", launcher)
        self.assertIn(".allowsHitTesting(false)", launcher)
        self.assertIn("override func isAccessibilityElement() -> Bool { false }", source)
        self.assertIn("menu.popUp(positioning:", source)
        self.assertIn("item.isEnabled = index != 4 || keysAvailable", source)

    def test_more_has_an_explicit_keyboard_focus_owner(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        launcher = source.split("private var moreMenu: some View {", 1)[1].split("private func showMoreMenu", 1)[0]
        self.assertIn("@FocusState private var moreFocused: Bool", source)
        self.assertIn(".buttonStyle(WorkspacePageStyle(selected: false, focused: moreFocused, height: bandPillHeight))", launcher)
        self.assertIn(".focusable(enabled)", launcher)
        self.assertIn(".focused($moreFocused)", launcher)
        self.assertNotIn(".overlay(ControlFocusRing", launcher, "The shared style draws exactly one focus ring")
        self.assertIn(".onKeyPress(.space, phases: .down) { _ in", launcher)
        self.assertIn("guard moreFocused, enabled else { return .ignored }", launcher)
        self.assertIn("showMoreMenu()", launcher)

    def test_shared_pill_registers_external_focus_on_its_native_button(self):
        source = (ROOT / "Sources/PerchApp/Workspace/Components/ControlStyle.swift").read_text()
        self.assertIn("var focus: FocusState<Bool>.Binding? = nil", source)
        self.assertIn("externalFocus: focus", source)
        external, fallback = source.split("if let externalFocus {", 1)[1].split("} else {", 1)
        self.assertIn("Button(configuration)", external)
        self.assertIn("focused: externalFocus.wrappedValue", external)
        self.assertLess(external.index(".focusable(enabled)"), external.index(".focused(externalFocus)"))
        self.assertIn(".focusEffectDisabled()", external)
        # Existing callers retain their original focus behavior unless they opt in.
        fallback = fallback.split("private struct VisualStyle", 1)[0]
        self.assertIn("Button(configuration)", fallback)
        self.assertIn(".focused($focused)", fallback)
        self.assertNotIn(".focusable(", fallback)
        self.assertIn("ControlFocusRing(shape: Capsule(), focused: enabled && focused)", source)

    def test_page_crossfade_is_retained(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        self.assertIn("page.id(model.page).transition(.opacity)", source)
        self.assertIn("Motion.animate(Motion.token(.pop), policy: motionPolicy)", source)
        self.assertIn(".transaction { $0.animation = nil }", source)
        self.assertNotIn(".onAppear", source, "Passive presentation must not request focus")

    def test_native_regression_hosts_the_production_workspace(self):
        launcher = (ROOT / "Tests/PerchAppTests/WorkspaceNavigationTests.swift").read_text()
        self.assertIn("check_workspace_navigation.sh", launcher)
        self.assertIn("process.terminationStatus, 0", launcher)
        self.assertNotIn("Services(store:", launcher)
        source = (ROOT / "Tests/PerchAppTests/WorkspaceBandProbe.swift").read_text()
        self.assertIn("WorkspaceView(notchHeight:", source)
        self.assertNotIn("SegmentPills(", source)
        for expected in ("testKeyboardGroup", "testPassive", "assertFocusRing", "isAccessibilityFocused"):
            self.assertIn(expected, source)

    def test_shell_band_and_column_integration(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        picker = source.split("private var pagePicker:", 1)[1].split("private func selectPage", 1)[0]
        self.assertIn("ForEach(NotchPage.workspacePages)", picker)
        self.assertIn("static var workspacePages: [NotchPage] { [.home, .week] }", source)
        self.assertIn('keyboardShortcut(p == .home ? "1" : "2", modifiers: .command)', picker)
        self.assertIn(".onExitCommand { model.close() }", source)
        self.assertIn("WorkspaceWindowRegistry.openKeys(store: store)", source)
        self.assertIn("model.geometry?.workspacePresentation?.menuBarHeight", source)
        self.assertIn(".background(Theme.band)", source)
        for title in ["Your week", "History", "Projects", "Settings", "Keys"]:
            self.assertIn(f'AppL10n.text("{title}")', source)
        home = (ROOT / "Sources/PerchApp/Workspace/HomePage.swift").read_text()
        self.assertIn("HomeLayout.columns(sheetWidth:", home)
        self.assertIn("DotGridSheet", home)
        for slot in ["CHECKLIST CARD SLOT", "TIME CARD SLOT", "PARKING LOT SLOT", "YOUR DAY SLOT"]:
            self.assertEqual(home.count(slot), 1)
        self.assertNotIn("HomeLayout.sideCards", home)
        self.assertNotIn("ViewThatFits", home)
        registry = source.split("enum WorkspaceWindowRegistry {", 1)[1].split("extension NotchGeometry", 1)[0]
        self.assertIn("window.contentView = NSHostingView", registry)
        self.assertIn("DashboardView(tab: tab)", registry)
        self.assertNotIn(".close()", registry)


if __name__ == "__main__":
    unittest.main()
