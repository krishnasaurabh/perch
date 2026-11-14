import AppKit
import PlannerCore
import PerchUI
import SwiftUI

/// The expanded workspace: header with page picker, then the page.
struct WorkspaceView: View {
    let notchHeight: CGFloat
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focusedPage: NotchPage?
    @FocusState private var moreFocused: Bool
    @FocusState private var focusedWeekStep: Int?
    @State private var pageGroupHasFocus = false
    @State private var moreAnchor = WorkspaceMenuAnchorView()

    @Environment(\.motionPolicy) private var motionPolicy
    @State private var homeState = TodayHomeState()
    @State private var weekOffset = 0
    @State private var sheetScheme: ColorScheme = .light

    private var bandHeight: CGFloat {
        let measured = model.geometry?.workspacePresentation?.menuBarHeight ?? notchHeight
        return WorkspaceLayout.bandHeight(menuBarHeight: measured > 0 ? measured : NSStatusBar.system.thickness)
    }
    private var bandPillHeight: CGFloat {
        min(Theme.Size.pillMinHeight.value, bandHeight - 2 * (Theme.Size.focusGap.value + Theme.Size.focusWidth.value))
    }

    var body: some View {
        VStack(spacing: .zero) {
            header.frame(height: bandHeight).background(Theme.band)
            ErrorBanner()
            ZStack(alignment: .top) {
                page.id(model.page).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environment(homeState)
        .environment(\.colorScheme, PreviewAppearance.scheme ?? sheetScheme)
        .background(WorkspaceAppearanceBridge { sheetScheme = $0 }.allowsHitTesting(false))
        .onExitCommand { model.close() }
        .onKeyPress(characters: CharacterSet(charactersIn: "?")) { _ in
            WorkspaceWindowRegistry.openKeys(store: store) ? .handled : .ignored
        }
        .onReceive(NotificationCenter.default.publisher(for: .perchWorkspaceWeekChanged)) { note in
            if let offset = note.object as? Int { weekOffset = offset }
        }
        .sheet(item: Binding(get: { model.detailsTaskID.map(IDBox.init) }, set: { model.detailsTaskID = $0?.id })) {
            box in
            TaskDetailsSheet(taskID: box.id).environmentObject(store).environmentObject(model)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .home: HomePage()
        case .week:
            DotGridSheet {
                WeekPage(workspaceShell: true).environment(\.colorScheme, .dark).task {
                    NotificationCenter.default.post(name: .perchWorkspaceWeekChanged, object: weekOffset)
                }
            }
        // Compatibility for the existing drop and deep-link callers, not navigation tabs.
        case .clips: ClipsPage()
        case .insights: InsightsPage()
        }
    }

    /// Runtime menu-bar height; no guessed housing height and no extra header gap.
    private var header: some View {
        HStack(spacing: WorkspaceLayout.bandGap) {
            if model.page == .week {
                weekHeading
            } else {
                TimelineView(.periodic(from: .distantPast, by: 60)) { _ in
                    HStack(spacing: WorkspaceLayout.bandGap) {
                        Text(store.engine.now(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .accessibilityIdentifier("workspace-date")
                        Text(store.engine.now(), format: .dateTime.hour().minute())
                            .accessibilityIdentifier("workspace-time")
                    }
                    .perchFont(.detailStrong)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: .zero)
            pagePicker
            moreMenu
        }
        .padding(.horizontal, WorkspaceLayout.bandInset)
        .foregroundStyle(Theme.ink)
        .background(Theme.band)
        .environment(\.colorScheme, .dark)
        .environment(\.controlSurface, Theme.band)
        .environment(\.calendar, store.engine.calendar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppL10n.text("Workspace"))
    }

    private var weekHeading: some View {
        HStack(spacing: WorkspaceLayout.bandGap) {
            weekArrow("chevron.left", label: "Previous week", step: -1)
            Text(weekRange).perchFont(.detailStrong).lineLimit(1)
                .accessibilityIdentifier("workspace-week-range")
            weekArrow("chevron.right", label: "Next week", step: 1)
        }
    }

    private var weekRange: String {
        let days = WeekColumnLayout.days(today: store.today, weekOffset: weekOffset, calendar: store.engine.calendar)
        return AppL10n.format(
            "%@ – %@",
            WeekColumnLayout.dateLabel(days[0], template: "MMMd", calendar: store.engine.calendar),
            WeekColumnLayout.dateLabel(days[6], template: "MMMd", calendar: store.engine.calendar))
    }

    private func weekArrow(_ symbol: String, label: String, step: Int) -> some View {
        Button {
            changeWeek(by: step)
        } label: {
            Image(systemName: symbol).perchFont(.detailStrong)
                .frame(minWidth: Theme.minimumTarget)
        }
        .buttonStyle(WorkspacePageStyle(selected: false, focused: focusedWeekStep == step, height: bandPillHeight))
        .focusable(enabled)
        .focused($focusedWeekStep, equals: step)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            changeWeek(by: step); return .handled
        }
        .accessibilityLabel(AppL10n.text(label))
        .accessibilityIdentifier(step < 0 ? "workspace-previous-week" : "workspace-next-week")
    }

    private func changeWeek(by step: Int) {
        weekOffset += step
        NotificationCenter.default.post(name: .perchWorkspaceWeekChanged, object: weekOffset)
    }

    /// One Tab stop. Arrow/Home/End navigation retains focus without changing target widths.
    private var pagePicker: some View {
        HStack(spacing: .zero) {
            ForEach(NotchPage.workspacePages) { p in
                let on = model.page == p
                Button {
                    selectPage(p)
                } label: {
                    Text(p.title).perchFont(.detailStrong)
                        .padding(.horizontal, WorkspaceLayout.bandGap)
                        .frame(minWidth: Theme.minimumTarget)
                }
                .buttonStyle(WorkspacePageStyle(selected: on, focused: focusedPage == p, height: bandPillHeight))
                .focusable(on)
                .focused($focusedPage, equals: p)
                .focusEffectDisabled()
                .keyboardShortcut(p == .home ? "1" : "2", modifiers: .command)
                .accessibilityIdentifier("workspace-page-\(p.rawValue)")
                .accessibilityLabel(p.title)
                .accessibilityValue(on ? "Selected" : "Not selected")
                .accessibilityAddTraits(on ? .isSelected : [])
                .onKeyPress(.space) { focusPage(p) }
                .onKeyPress(.leftArrow) { movePage(from: p, by: -1) }
                .onKeyPress(.rightArrow) { movePage(from: p, by: 1) }
                .onKeyPress(.home) { focusPage(.home) }
                .onKeyPress(.end) { focusPage(.week) }
                .transaction { $0.animation = nil }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-pages")
        .onChange(of: focusedPage) { oldPage, page in
            pageFocusChanged(from: oldPage, to: page)
        }
        .onChange(of: model.page) { _, page in restorePageFocus(page) }
        .onKeyPress(.tab) { leavePageGroup() }
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{19}")) { _ in leavePageGroup() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === moreAnchor.window else { return }
            pageGroupHasFocus = false
            focusedPage = nil
        }
    }

    private func selectPage(_ page: NotchPage) {
        Motion.animate(Motion.token(.pop), policy: motionPolicy) { model.page = page }
    }

    private func pageFocusChanged(from oldPage: NotchPage?, to page: NotchPage?) {
        if page != nil {
            pageGroupHasFocus = true
        } else if oldPage == model.page {
            // A nil focus during selection replacement is temporary, not a group exit.
            pageGroupHasFocus = false
        }
    }

    private func restorePageFocus(_ page: NotchPage) {
        guard pageGroupHasFocus else { return }
        // The selection render must register the newly focusable pill before the
        // FocusState request. Writing it in the key handler can discard the request.
        DispatchQueue.main.async { [self] in
            guard pageGroupHasFocus, enabled, model.page == page, moreAnchor.window?.isKeyWindow == true else { return }
            focusedPage = page
        }
    }

    private func leavePageGroup() -> KeyPress.Result {
        pageGroupHasFocus = false
        // Let AppKit move to the next/previous control; never consume Tab.
        return .ignored
    }

    private func focusPage(_ page: NotchPage) -> KeyPress.Result {
        guard enabled else { return .ignored }
        selectPage(page)
        return .handled
    }

    private func movePage(from page: NotchPage, by step: Int) -> KeyPress.Result {
        let pages = NotchPage.workspacePages
        guard let index = pages.firstIndex(of: page) else { return .ignored }
        return focusPage(pages[min(max(index + step, 0), pages.count - 1)])
    }

    private struct WorkspacePageStyle: ButtonStyle {
        let selected: Bool
        let focused: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(height: height)
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .background(Capsule().fill(selected || hover || configuration.isPressed ? Theme.field : .clear))
                .overlay(FocusRing(shape: Capsule(), focused: focused && enabled, surface: .band))
                .frame(minHeight: WorkspaceLayout.bandControlHeight)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }

    private var moreMenu: some View {
        Button {
            showMoreMenu()
        } label: {
            Text("More").perchFont(.detailStrong)
                .padding(.horizontal, WorkspaceLayout.bandGap)
                .frame(minWidth: Theme.minimumTarget)
        }
        .buttonStyle(WorkspacePageStyle(selected: false, focused: moreFocused, height: bandPillHeight))
        .focusable(enabled)
        .focused($moreFocused)
        .focusEffectDisabled()
        .onKeyPress(.space, phases: .down) { _ in
            guard moreFocused, enabled else { return .ignored }
            showMoreMenu()
            return .handled
        }
        .fixedSize()
        .background(WorkspaceMenuAnchor(view: moreAnchor).allowsHitTesting(false))
        .help("More")
        .accessibilityLabel("More")
        .accessibilityIdentifier("workspace-more")
    }

    private func showMoreMenu() {
        guard enabled else { return }
        moreAnchor.show(
            keysAvailable: WorkspaceWindowRegistry.keys != nil,
            yourWeek: { WorkspaceWindowRegistry.showDashboard(store: store, tab: .insights) },
            history: { WorkspaceWindowRegistry.showDashboard(store: store, tab: .history) },
            projects: { WorkspaceWindowRegistry.showDashboard(store: store, tab: .projects) },
            settings: { SettingsWindow.show(store: store, services: services) },
            keys: { _ = WorkspaceWindowRegistry.openKeys(store: store) })
    }

}

/// Geometry only: the shared SwiftUI button remains the sole accessible control.
private struct WorkspaceMenuAnchor: NSViewRepresentable {
    let view: WorkspaceMenuAnchorView
    func makeNSView(context: Context) -> WorkspaceMenuAnchorView { view }
    func updateNSView(_ nsView: WorkspaceMenuAnchorView, context: Context) {}
}

@MainActor
private final class WorkspaceMenuAnchorView: NSView {
    private var actions: [() -> Void] = []
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    func show(
        keysAvailable: Bool, yourWeek: @escaping () -> Void,
        history: @escaping () -> Void, projects: @escaping () -> Void,
        settings: @escaping () -> Void, keys: @escaping () -> Void
    ) {
        guard window != nil else { return }
        actions = [yourWeek, history, projects, settings, keys]
        defer { actions.removeAll() }
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = false
        for (index, title) in [
            AppL10n.text("Your week"), AppL10n.text("History"), AppL10n.text("Projects"),
            AppL10n.text("Settings"), AppL10n.text("Keys"),
        ].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = index != 4 || keysAvailable
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

struct IDBox: Identifiable { let id: UUID }

extension NotchPage {
    static var workspacePages: [NotchPage] { [.home, .week] }
    var workspacePage: WorkspacePage { self == .week ? .week : .today }
}

extension Notification.Name {
    static let perchWorkspaceWeekChanged = Notification.Name("perchWorkspaceWeekChanged")
}

/// The Keys window registers its opener when that feature is installed.
@MainActor
enum WorkspaceWindowRegistry {
    // Preserve the localized title while legacy dashboard entry points migrate.
    static var legacyDashboardTitle: String { AppL10n.text("Open Dashboard") }
    static var keys: ((PlannerStore) -> Void)?

    static func showDashboard(store: PlannerStore, tab: DashboardView.Tab) {
        // Replace the cached content, not the window: the close observer must not
        // remove a newly registered window with the same identifier.
        if let window = WindowHost.windows["dashboard"] {
            window.contentView = NSHostingView(
                rootView: DashboardView(tab: tab).environmentObject(store)
                    .environment(\.accessibilityEnabled, true).previewEnvironment())
        }
        DashboardWindow.show(store: store, tab: tab)
    }

    @discardableResult static func openKeys(store: PlannerStore) -> Bool {
        guard let keys else { return false }
        keys(store)
        return true
    }
}

/// The legacy Week window retains its toolbar; the workspace uses the shared band.
struct WorkspaceHeaderVisibility: ViewModifier {
    let hidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if !hidden { content }
    }
}

struct WorkspacePresentation: Equatable {
    let page: WorkspacePage
    let menuBarHeight: CGFloat
}

extension NotchGeometry {
    @MainActor func forWorkspace(_ page: NotchPage) -> Self {
        var value = self
        value.workspacePresentation = WorkspacePresentation(
            page: page.workspacePage,
            menuBarHeight: screen.menuBarHeight > 0 ? screen.menuBarHeight : NSStatusBar.system.thickness)
        return value
    }

    var resolvedWorkspace: CGRect {
        workspacePresentation.map {
            WorkspaceLayout.frame(screen: screen, page: $0.page, menuBarHeight: $0.menuBarHeight)
        }
            ?? WorkspaceLayout.frame(screen: screen)
    }

    var maximumWorkspace: CGRect {
        workspacePresentation.map {
            WorkspaceLayout.frame(screen: screen, page: .week, menuBarHeight: $0.menuBarHeight)
        }
            ?? workspace
    }
}

/// Keep the adaptive sheet independent of the legacy black notch environment.
private struct WorkspaceAppearanceBridge: NSViewRepresentable {
    let changed: (ColorScheme) -> Void
    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.changed = changed
        return view
    }
    func updateNSView(_ view: AppearanceView, context: Context) {
        view.changed = changed
        view.refresh()
    }

    final class AppearanceView: NSView {
        var changed: ((ColorScheme) -> Void)?
        private var last: ColorScheme?
        private var observation: NSKeyValueObservation?
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observation == nil {
                observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
            refresh()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
        func refresh() {
            let appearance = NSApp.effectiveAppearance
            let scheme: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            guard scheme != last else { return }
            last = scheme
            DispatchQueue.main.async { [weak self] in self?.changed?(scheme) }
        }
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor enum WorkspaceShellPreview {
        static func show(page: NotchPage, narrow: Bool = false, app: AppDelegate) {
            let model = NotchModel()
            model.page = page
            let measured = NSScreen.main.map { NotchLayout.Screen($0).menuBarHeight } ?? .zero
            let bar = measured > 0 ? measured : NSStatusBar.system.thickness
            var size = WorkspaceLayout.preferredSize(page: page.workspacePage, menuBarHeight: bar)
            if narrow { size.width = DesignTokens.Size.todayWidth.value }
            let id = narrow ? "workspace-narrow" : "workspace-\(page.rawValue)"
            let content = WorkspaceView(notchHeight: bar)
                .environmentObject(app.store).environmentObject(model).environmentObject(app.services)
            if let window = WindowHost.windows[id] {
                window.contentView = NSHostingView(rootView: content.previewEnvironment())
                window.setContentSize(size)
            }
            WindowHost.show(id, title: "Perch", size: size) { content }
        }
    }
#endif
