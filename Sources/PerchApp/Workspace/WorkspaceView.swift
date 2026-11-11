import PlannerCore
import PerchUI
import SwiftUI

/// The expanded workspace: header with page picker, then the page.
struct WorkspaceView: View {
    let notchHeight: CGFloat
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services

    var body: some View {
        VStack(spacing: WorkspaceLayout.headerGap) {
            header.frame(height: WorkspaceLayout.headerHeight(notchHeight: notchHeight))
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
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1)
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
                    Motion.animate(Motion.page) { model.page = p }
                } label: {
                    Text(p.title)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(on ? Theme.fillStrong : .clear))
                        .foregroundStyle(on ? Theme.text : Theme.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .transaction { $0.animation = nil }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
    }

    /// Undo, Dashboard and Settings behind one button. ⌘Z still undoes directly.
    private var moreMenu: some View {
        Menu {
            Button("Undo") { store.undo() }.disabled(!store.canUndo)
            Divider()
            Button("Open Dashboard") { DashboardWindow.show(store: store, model: model, services: services) }
            Button("Settings…") { SettingsWindow.show(store: store, services: services) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.fill))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

struct IDBox: Identifiable { let id: UUID }
