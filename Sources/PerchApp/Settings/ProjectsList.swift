import AppKit
import PerchUI
import PlannerCore
import SwiftUI

/// A projection of the saved order. Project identity, not a mutable name or randomized hash, picks its surface.
struct ProjectCardModel {
    let open: Int
    let done: Int
    let next: PlanTask?
    let surface: DesignTokens.Surface
    var progress: Double { open + done == 0 ? 0 : Double(done) / Double(open + done) }

    init(project: TaskProject, tasks: [PlanTask], today: DayKey) {
        let openTasks = Self.openTasks(tasks, projectID: project.id, today: today)
        open = openTasks.count
        done = tasks.filter { $0.projectID == project.id && $0.done }.count
        next = openTasks.first
        surface = [DesignTokens.Surface.butter, .blush, .mint, .apricot][Int(project.id.uuid.15) % 4]
    }

    /// Past days keep their records; only inbox, today and future instances are open here.
    static func openTasks(_ tasks: [PlanTask], projectID: UUID?, today: DayKey) -> [PlanTask] {
        tasks.filter { !$0.done && $0.projectID == projectID && ($0.day == nil || $0.day! >= today) }
    }
}

struct ProjectsList: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var creating = false
    @State private var newName = ""
    @State private var error: String?
    @FocusState private var newNameFocused: Bool
    #if DEBUG || PERCH_TESTING
        @ObservedObject private var preview = ProjectsPreviewState.shared
    #endif

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: SurfaceMetrics.fieldRadius), count: 2)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: SurfaceMetrics.fieldRadius) {
            ForEach(store.planner.projects) { project in
                ProjectReviewCard(project: project)
            }
            noProject
            newProject
        }
        .accessibilityElement(children: .contain)
        .perchFont(.body)
        #if DEBUG || PERCH_TESTING
            .onReceive(preview.$mode) {
                creating = $0 == .new; newName = ""; error = nil
            }
        #endif
    }

    private var noProject: some View {
        Card(.paper) {
            VStack(alignment: .leading, spacing: SurfaceMetrics.compactGap) {
                Text("No project").perchFont(.stripTitle)
                Text(
                    AppL10n.format(
                        "%lld open tasks",
                        ProjectCardModel.openTasks(store.planner.tasks, projectID: nil, today: store.today).count)
                )
                .perchFont(.detail).foregroundStyle(Theme.ink2)
                Spacer(minLength: Theme.Size.buttonHeight.value)
                Text("Drag a task onto a project card to file it.")
                    .foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: ProjectReviewCard.contentHeight, alignment: .topLeading)
        }
        .dropDestination(for: TaskDragItem.self) { items, _ in Self.file(items, in: nil, store: store) }
        .accessibilityIdentifier("project-unfiled")
    }

    @ViewBuilder private var newProject: some View {
        if creating {
            Card(.paper) {
                VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                    Text("New project").perchFont(.stripTitle)
                    PerchField("Project name", text: $newName, focus: $newNameFocused, onSubmit: create)
                    if let error { Text(error).perchFont(.detail).foregroundStyle(Theme.ink2) }
                    Spacer(minLength: .zero)
                    DashboardPaneButton(
                        "Add project", identifier: "project-create", kind: .main, size: .regular, action: create)
                    DashboardPaneButton("Not now", identifier: "project-cancel-create", size: .regular) {
                        creating = false; error = nil
                    }
                }
                .frame(minHeight: ProjectReviewCard.contentHeight, alignment: .topLeading)
                .onAppear { newNameFocused = true }
                .onExitCommand {
                    creating = false; error = nil
                }
            }
        } else {
            ProjectNewButton { creating = true }
        }
    }

    private func create() {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = AppL10n.text("Enter a project name.")
            return
        }
        if store.send(.createProject(newName)) != nil {
            creating = false; newName = ""; error = nil
        } else {
            error = store.lastError?.localizedDescription
        }
    }

    /// Resolve all identities in one locked command transaction. A failed member rolls back the whole drop.
    @discardableResult
    static func file(_ items: [TaskDragItem], in projectID: UUID?, store: PlannerStore) -> Bool {
        guard !items.isEmpty else { return false }
        return store.apply { commands in
            if let projectID, !commands.planner.projects.contains(where: { $0.id == projectID }) {
                throw PlannerError("That project is no longer available.")
            }
            for item in items { try commands.updateTask(item.taskID) { $0.projectID = projectID } }
            return true
        } ?? false
    }
}

private struct ProjectNewButton: View {
    let action: () -> Void

    var body: some View {
        Text("New project").perchFont(.button).foregroundStyle(Theme.brandText)
            .frame(maxWidth: .infinity, minHeight: ProjectReviewCard.cardHeight)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Size.cardRadius.value)
                    .strokeBorder(
                        Theme.ink2,
                        style: StrokeStyle(
                            lineWidth: Theme.Size.cardEdge.value,
                            dash: [SurfaceMetrics.gap / 2])
                    )
                    .allowsHitTesting(false)
            }
            .dashboardPaneAction(
                AppL10n.text("New project"), identifier: "project-new",
                radius: Theme.Size.cardRadius.value, surface: .sheet, action: action)
    }
}

private struct ProjectReviewCard: View {
    let project: TaskProject
    @EnvironmentObject private var store: PlannerStore
    @State private var targeted = false
    @State private var options = false
    @State private var renaming = false
    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    #if DEBUG || PERCH_TESTING
        @ObservedObject private var preview = ProjectsPreviewState.shared
    #endif

    static var cardHeight: CGFloat { Theme.Size.taskRowHeight.value * 6 }
    static var contentHeight: CGFloat { cardHeight - Theme.Size.cardPadding.value * 2 }

    var body: some View {
        let value = ProjectCardModel(project: project, tasks: store.planner.tasks, today: store.today)
        Card(value.surface) {
            VStack(alignment: .leading, spacing: SurfaceMetrics.compactGap) {
                HStack(alignment: .top, spacing: SurfaceMetrics.gap) {
                    if renaming {
                        PerchField("Project name", text: $name, focus: $nameFocused, onSubmit: rename)
                    } else {
                        Text(project.name).perchFont(.stripTitle).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: .zero)
                    Image(systemName: "ellipsis").perchFont(.body)
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, Theme.Size.buttonSidePadding.value)
                        .padding(.vertical, Theme.Size.stepCheckboxRadius.value)
                        .frame(minWidth: Theme.Size.minimumTarget.value, minHeight: Theme.Size.smallButtonHeight.value)
                        .dashboardPaneAction(
                            AppL10n.text("Project options"), identifier: "project-options-\(project.id.uuidString)",
                            radius: Theme.Size.smallButtonHeight.value / 2, surface: value.surface,
                            action: { options.toggle() }
                        )
                        .popover(isPresented: $options) {
                            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                                PerchButton("Rename project", kind: .quiet) {
                                    beginRename(); options = false
                                }
                                ProjectDeleteButton { delete() }
                            }
                            .padding(Theme.Size.cardPadding.value)
                            .background(Theme.paper)
                        }
                }
                Text(AppL10n.format("%lld open, %lld done", value.open, value.done))
                    .perchFont(.detail).foregroundStyle(Theme.ink2)
                GeometryReader { geometry in
                    Capsule().fill(Theme.edge(value.surface))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.ink).frame(width: geometry.size.width * value.progress)
                        }
                }
                .frame(height: SurfaceMetrics.compactGap)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AppL10n.format("%lld percent done", Int((value.progress * 100).rounded())))
                Spacer(minLength: Theme.Size.minimumTarget.value)
                if renaming {
                    if let error { Text(error).perchFont(.detail).foregroundStyle(Theme.ink2) }
                    DashboardPaneButton(
                        "Save name", identifier: "project-save-name", kind: .main, surface: value.surface,
                        action: rename)
                    DashboardPaneButton("Not now", identifier: "project-cancel-name", surface: value.surface) {
                        renaming = false
                    }
                } else {
                    Text("Next").perchFont(.detailStrong).foregroundStyle(Theme.ink2)
                    Text(value.next?.title ?? AppL10n.text("Nothing waiting in this project."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: Self.contentHeight, alignment: .topLeading)
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Theme.Size.cardRadius.value)
                    .strokeBorder(Theme.focusRing, lineWidth: Theme.Size.focusWidth.value)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: TaskDragItem.self) { items, _ in
            ProjectsList.file(items, in: project.id, store: store)
        } isTargeted: {
            targeted = $0
        }
        .contextMenu {
            Button("Rename project", action: beginRename)
            Button("Delete project", action: delete)
        }
        .accessibilityElement(children: .contain)
        .onExitCommand {
            renaming = false; options = false; error = nil
        }
        #if DEBUG || PERCH_TESTING
            .onReceive(preview.$mode) { mode in
                guard project.id == store.planner.projects.first?.id else { return }
                if mode == .rename { beginRename() } else { renaming = false }
                options = mode == .options
            }
        #endif
    }

    private func beginRename() {
        name = project.name
        renaming = true
        nameFocused = true
        error = nil
    }

    private func rename() {
        if store.send(.renameProject(project.id, name)) != nil {
            renaming = false; error = nil
        } else {
            error = store.lastError?.localizedDescription
        }
    }

    private func delete() {
        options = false
        store.apply { try $0.deleteProject(project.id) }
    }
}

/// New surface paint around the existing native action target. The legacy shell's
/// delete paint is 11 pt; only its event/focus implementation is reused here.
private struct ProjectDeleteButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var focused = false
    @State private var pressed = false

    var body: some View {
        Text(AppL10n.text("Delete project"))
            .perchFont(.button)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Size.buttonSidePadding.value)
            .frame(minWidth: Theme.Size.minimumTarget.value, minHeight: Theme.Size.smallButtonHeight.value)
            .background(Capsule().fill(Theme.field))
            .overlay(FocusRing(shape: Capsule(), focused: focused && enabled, surface: .paper))
            .perchControlFeedback(pressed: pressed)
            .accessibilityHidden(true)
            .overlay {
                ProjectDeleteTarget(
                    enabled: enabled, action: action,
                    focusChanged: { focused = $0 }, pressChanged: { pressed = $0 })
            }
    }
}

private struct ProjectDeleteTarget: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void
    let focusChanged: (Bool) -> Void
    let pressChanged: (Bool) -> Void

    func makeNSView(context: Context) -> DashboardProjectActionView { DashboardProjectActionView() }
    func updateNSView(_ view: DashboardProjectActionView, context: Context) {
        view.onAction = action
        view.focusChanged = focusChanged
        view.pressChanged = pressChanged
        view.isEnabled = enabled
        if !enabled, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor
    final class ProjectsPreviewState: ObservableObject {
        static let shared = ProjectsPreviewState()
        enum Mode { case normal, new, rename, options }
        @Published var mode: Mode = .normal
    }
#endif
