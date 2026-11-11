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
    @State private var moreAnchor = WorkspaceMenuAnchorView()

    var body: some View {
        VStack(spacing: WorkspaceLayout.headerGap) {
            // Reserve room for the shared target and its out-of-layout focus ring.
            header.frame(
                height: max(
                    WorkspaceLayout.headerHeight(notchHeight: notchHeight),
                    Theme.primaryHeight + 2 * (Theme.focusGap + Theme.focusWidth)))
            ErrorBanner()
            // In-place crossfade between pages: nothing slides or scales.
            ZStack(alignment: .top) {
                page.id(model.page).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, WorkspaceLayout.bottomInset)
        .foregroundStyle(Theme.text)
        .sheet(item: Binding(get: { model.detailsTaskID.map(IDBox.init) }, set: { model.detailsTaskID = $0?.id })) {
            box in
            TaskDetailsSheet(taskID: box.id).environmentObject(store).environmentObject(model)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .home: HomePage()
        case .week: WeekPage()
        case .clips: ClipsPage()
        case .insights: InsightsPage()
        }
    }

    /// Identity on the left, pages and one menu on the right, so nothing sits under the camera housing.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                OwlMark(size: 18)
                Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(Theme.label).foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .accessibilityIdentifier("workspace-date")
            }
            Spacer(minLength: 0)
            pagePicker
            moreMenu
        }
        .padding(.horizontal, 6)
    }

    /// Text-only tabs in one dark pill. The selected pill snaps; only the page below crossfades.
    private var pagePicker: some View {
        HStack(spacing: 0) {
            ForEach(NotchPage.allCases) { p in
                let on = model.page == p
                Button {
                    selectPage(p)
                } label: {
                    Text(p.title)
                        .font(Theme.label)
                        .padding(.horizontal, 9)
                        .frame(minWidth: Theme.minimumTarget, minHeight: Theme.minimumTarget)
                }
                .buttonStyle(WorkspacePageStyle(selected: on, focused: focusedPage == p))
                // Only the selected tab participates in Tab navigation. The other
                // tabs remain clickable; arrows move selection and native focus together.
                .focusable(on)
                .focused($focusedPage, equals: p)
                .focusEffectDisabled()
                .accessibilityIdentifier("workspace-page-\(p.rawValue)")
                .accessibilityLabel(p.title)
                .accessibilityValue(on ? "Selected" : "Not selected")
                .accessibilityAddTraits(on ? .isSelected : [])
                .onKeyPress(.leftArrow) { movePage(from: p, by: -1) }
                .onKeyPress(.rightArrow) { movePage(from: p, by: 1) }
                .onKeyPress(.home) { focusPage(.home) }
                .onKeyPress(.end) { focusPage(.insights) }
                .transaction { $0.animation = nil }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-pages")
    }

    private func selectPage(_ page: NotchPage) {
        Motion.animate(Motion.page) { model.page = page }
        // A click within an already-focused group keeps its roving stop in sync.
        // Passive activation must never acquire focus from another window.
        if focusedPage != nil { focusedPage = page }
    }

    private func focusPage(_ page: NotchPage) -> KeyPress.Result {
        guard enabled else { return .ignored }
        selectPage(page)
        focusedPage = page
        return .handled
    }

    private func movePage(from page: NotchPage, by step: Int) -> KeyPress.Result {
        let pages = NotchPage.allCases
        guard let index = pages.firstIndex(of: page) else { return .ignored }
        return focusPage(pages[min(max(index + step, 0), pages.count - 1)])
    }

    private struct WorkspacePageStyle: ButtonStyle {
        let selected: Bool
        let focused: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .background(Capsule().fill(fill(pressed: configuration.isPressed)))
                .overlay(ControlFocusRing(shape: Capsule(), focused: focused && enabled))
                .contentShape(Capsule())
                .onHover { hover = $0 }
        }

        private func fill(pressed: Bool) -> Color {
            if !enabled { return selected ? Theme.selectedPill : .clear }
            if pressed { return Theme.fillPressed }
            if selected { return Theme.selectedPill }
            return hover ? Theme.fillStrong : .clear
        }
    }

    /// Undo, Dashboard and Settings behind one button. ⌘Z still undoes directly.
    private var moreMenu: some View {
        // A native SwiftUI Menu does not apply our primitive button style to its
        // AppKit launcher. Use a real shared-style button and anchor a native menu
        // to it so its target, keyboard focus and accessibility identity agree.
        Button {
            moreAnchor.show(
                canUndo: store.canUndo,
                undo: { store.undo() },
                dashboard: { DashboardWindow.show(store: store, model: model, services: services) },
                settings: { SettingsWindow.show(store: store, services: services) })
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(PillStyle())
        .fixedSize()
        .background(WorkspaceMenuAnchor(view: moreAnchor).allowsHitTesting(false))
        .help("More")
        .accessibilityLabel("More")
        .accessibilityIdentifier("workspace-more")
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
        canUndo: Bool, undo: @escaping () -> Void,
        dashboard: @escaping () -> Void, settings: @escaping () -> Void
    ) {
        guard window != nil else { return }
        actions = [undo, dashboard, settings]
        defer { actions.removeAll() }
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = false
        for (index, title) in ["Undo", "Open Dashboard", "Settings…"].enumerated() {
            if index == 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = index != 0 || canUndo
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
