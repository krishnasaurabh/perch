// Compiled with the all-page matrix entry point, outside the XCTest process.
// The standalone Week probe still covers its Inbox toolbar unchanged.
private struct WorkspaceLegacyWeekProbe: View {
    let fixture: MatrixFixture
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        WeekPage()
            .sheet(
                item: Binding(
                    get: { model.detailsTaskID.map(IDBox.init) },
                    set: { model.detailsTaskID = $0?.id }
                )
            ) { box in
                TaskDetailsSheet(taskID: box.id)
                    .environmentObject(fixture.store).environmentObject(fixture.model)
            }
    }
}

extension AllPageMatrix {
    func workspaceWeekKeyboard() async throws {
        try await weekKeyboard()
        MatrixAX.useViewTree = true
        defer { MatrixAX.useViewTree = false }
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        guard let task = try fixture.seed(["Workspace week task"], day: .day(fixture.store.today)).first else {
            throw MatrixFailure(label: "could not seed workspace week task")
        }
        fixture.model.page = .week
        let destinations = MatrixFocusDestinations()
        let view = MatrixHarness(destinations: destinations) {
            WorkspaceView(notchHeight: 32)
                .environmentObject(fixture.store)
                .environmentObject(fixture.services)
                .environmentObject(fixture.model)
                .environment(\.colorScheme, .dark)
                .frame(width: 960, height: 540)
        }
        let (window, host) = try matrixWindow("Workspace Week", view, size: NSSize(width: 1000, height: 600))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Workspace Week")
        let days = WeekColumnLayout.days(today: fixture.store.today, calendar: fixture.store.engine.calendar)
        @MainActor func range(_ offset: Int) -> String {
            let dates = WeekColumnLayout.days(
                today: fixture.store.today, weekOffset: offset, calendar: fixture.store.engine.calendar)
            return AppL10n.format(
                "%@ – %@",
                WeekColumnLayout.dateLabel(dates[0], template: "MMMd", calendar: fixture.store.engine.calendar),
                WeekColumnLayout.dateLabel(dates[6], template: "MMMd", calendar: fixture.store.engine.calendar))
        }
        try report.require(mxHas(root, range(0)), "workspace shows the current week range")
        try report.require(window.makeFirstResponder(destinations.before), "workspace week starts from a field")
        _ = try await tabUntil(window, limit: 28, tag: "workspaceWeekBack") { identity, _ in
            identity == "workspace-previous-week"
        }
        try await mxKey(window, 49, " ")
        await mxReady(0.8)
        try report.require(mxHas(root, range(-1)), "Space on the band back arrow shows the previous week")
        _ = try await tabUntil(window, limit: 28, tag: "workspaceWeekForward") { identity, _ in
            identity == "workspace-next-week"
        }
        try await mxKey(window, 49, " ")
        await mxReady(0.8)
        try report.require(mxHas(root, range(0)), "Space on the band forward arrow restores the current week")
        try report.require(days.contains(fixture.store.today), "week fixture includes today")

        let menuID = "week-menu-\(task.id)"
        _ = try await tabUntil(window, limit: 40, tag: "workspaceWeekTaskMenu") { identity, _ in
            identity == menuID
        }
        let before = fixture.store.planner.tasks
        let observation = MatrixMenuObservation()
        observation.start()
        defer { observation.stop() }
        try await mxKey(window, 49, " ")
        guard let menu = await observation.waitForMenu() else {
            mxDumpAX(root, "workspace-week-menu")
            throw MatrixFailure(label: "Space did not open workspace task actions")
        }
        try report.require(
            menu.items.contains { $0.title == AppL10n.text("Details…") && $0.isEnabled },
            "workspace task menu contains Details")
        try await mxKey(window, 53, "\u{1b}")
        observation.cancel()
        await mxReady(0.7)
        try mxAssertFocused(menuID, "Escape returns focus to workspace task actions", report: report)
        fixture.model.detailsTaskID = task.id
        await mxReady(1.4)
        guard let sheet = window.attachedSheet else {
            throw MatrixFailure(label: "workspace task details did not attach")
        }
        try await mxKey(sheet, 53, "\u{1b}")
        await mxReady(1.2)
        try report.require(window.attachedSheet == nil, "nested Escape dismisses workspace task details")
        try report.require(window.isKeyWindow, "workspace regains key status after nested Escape")
        try report.require(fixture.store.planner.tasks == before, "workspace navigation and Escape preserve tasks")
        try mxSave(host, output.appendingPathComponent("workspace-week-keyboard.png"))
    }
}
