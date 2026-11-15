// Compiled into the Week snapshot executable after the shared native helpers.
@MainActor
func verifyWeekBoard(window: NSWindow, out: URL) async throws {
    let fixture = try PlannerPreviewScenarios.make("week-full")
    let data = out.appendingPathComponent("board-planner.json")
    let file = PlannerFile(url: data, preferences: MemoryPlannerPreferences())
    var planner = fixture.planner
    let today = fixture.day
    let future = today.adding(days: 1, calendar: PlannerPreviewScenarios.calendar)
    planner.tasks.append(
        PlanTask(
            title: "A deliberately long title that wraps across two lines but must never grow a third line", day: future
        ))
    try file.save(planner)
    let store = PlannerStore(file: file, now: { fixture.now }, watching: false)
    let model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
    let days = WeekColumnLayout.days(today: today, calendar: store.engine.calendar)
    for width in [1252.0, 932.0] {
        measurements.removeAll()
        let host = NSHostingView(
            rootView: WeekBoard()
                .environmentObject(store).environmentObject(model)
                .environment(\.accessibilityEnabled, true)
                .environment(\.colorScheme, .light)
                .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 400))
        window.makeKeyAndOrderFront(nil)
        await settle()
        let layout = WeekColumnLayout.columns(days: days, today: today, available: width)
        let parking = frame("board-parking", in: host)
        require(abs(parking.width - layout.parkingWidth) < 2, "Parking width differs from portable layout")
        for day in days {
            let column = frame("board-column:\(day.raw)", in: host)
            require(abs(column.width - layout.width(for: day)) < 2, "Day width differs from portable layout")
        }
        let first = frame("board-column:\(layout.days[0].raw)", in: host)
        require(abs(first.minX) < 2, "Narrow board must initially hide only the earliest past days")
        if width == 1252 {
            require(layout.omittedPastDays == 0, "All seven days fit at normal width")
            let last = frame("board-column:\(days[6].raw)", in: host)
            require(abs(parking.minX - last.maxX - 8) < 2, "Eight-point column gap changed")
        } else {
            require(layout.omittedPastDays > 0, "Narrow board must omit past dates")
        }
        let long = try XCTFreeUnwrap(
            store.planner.tasks.first { $0.title.hasPrefix("A deliberately") }, "two-line board fixture")
        let title = frame("board-title:\(long.id)", in: host)
        report("Week board width=\(width) title-frame=\(title)")
        try save(host, out.appendingPathComponent("week-board-\(Int(width + 28)).png"))
        require(title.height > 18 && title.height <= 42, "Board task title must wrap to at most two lines")
        require(title.width <= layout.width(for: future), "Board text cannot widen a day column")
        let titleMenus = nodes(host).filter {
            attribute($0, "accessibilityIdentifier") as? String == "week-menu-\(long.id)"
        }
        require(!titleMenus.isEmpty, "Wrapped title must retain its accessible task menu")
        let tracker = WeekMenuTracker()
        tracker.start()
        let point = host.convert(NSPoint(x: title.midX, y: title.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTFreeUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1), "board title click")
            window.sendEvent(event)
        }
        tracker.finishWaiting()
        tracker.stop()
        let menu = try XCTFreeUnwrap(tracker.menu, "wrapped title native menu")
        let detailsIndex = try XCTFreeUnwrap(
            menu.items.indices.first { menu.items[$0].title == "Details…" && menu.items[$0].isEnabled },
            "wrapped title Details item")
        model.detailsTaskID = nil
        menu.performActionForItem(at: detailsIndex)
        await settle()
        require(model.detailsTaskID == long.id, "Wrapped title menu must open Details for its own task")
        model.detailsTaskID = nil
    }
    // Exercise the production typed drop destination, then read the exact persisted result.
    let task = try XCTFreeUnwrap(store.planner.tasks.first { $0.day == today && !$0.done }, "board move fixture")
    let taskProvider = NSItemProvider()
    taskProvider.registerDataRepresentation(forTypeIdentifier: UTType.perchTask.identifier, visibility: .all) {
        completion in
        completion(try? JSONEncoder().encode(TaskDragItem(taskID: task.id)), nil); return nil
    }
    require(WeekDrop.accept([taskProvider], on: future, store: store), "Typed task drop must be accepted")
    await settle()
    require(try file.load().tasks.first { $0.id == task.id }?.day == future, "Task drop did not persist its day")
    store.undo()
    require(try file.load().tasks.first { $0.id == task.id }?.day == today, "Task drop must be undoable")
    let thought = try XCTFreeUnwrap(store.planner.parkedThoughts.first, "board parked thought")
    let thoughtProvider = NSItemProvider()
    thoughtProvider.registerDataRepresentation(
        forTypeIdentifier: UTType.perchParkedThought.identifier, visibility: .all
    ) { completion in
        completion(try? JSONEncoder().encode(ParkedThoughtDragItem(thoughtID: thought.id)), nil); return nil
    }
    require(WeekDrop.accept([thoughtProvider], on: future, store: store), "Typed thought drop must be accepted")
    await settle()
    let saved = try file.load()
    require(!saved.parkedThoughts.contains { $0.id == thought.id }, "Promotion must consume the parked thought")
    require(
        saved.tasks.contains { $0.parkedFrom == thought.id && $0.day == future },
        "Promotion must persist a task on its destination")
    store.undo()
    require(try file.load().parkedThoughts.contains { $0.id == thought.id }, "Promotion must be undoable")
    require(!WeekDrop.accept([taskProvider], on: today.adding(days: -1), store: store), "History rejects drops")
    require(
        !WeekDrop.accept([taskProvider, thoughtProvider], on: future, store: store),
        "Ambiguous multi-item drops are rejected")
    report("PASS Week board: eight columns, 1280/960 widths, two-line titles, typed moves, promotion and Undo")
}
