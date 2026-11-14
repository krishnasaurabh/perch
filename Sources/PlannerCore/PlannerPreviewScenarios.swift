#if DEBUG || PERCH_TESTING
    import Foundation

    /// Deterministic sample documents. Extend these fixtures as screens gain new engine fields.
    /// No migration or production seeding uses this type.
    public enum PlannerPreviewScenarios {
        public static let names = AppLaunchConfiguration.previewScenarioNames.subtracting([
            "empty", "three", "timer", "insights",
        ])
        public static let referenceDate = date(hour: 10, minute: 20, second: 50)
        public static var calendar: Calendar {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = TimeZone(secondsFromGMT: 0)!
            value.locale = Locale(identifier: "en_US_POSIX")
            value.firstWeekday = 2
            return value
        }

        public struct Fixture {
            public let name: String
            public var planner: Planner
            public let now: Date
            public let day: DayKey
            public var captureText = ""
            public var editingTaskID: UUID?
        }

        /// A typed, test-only storage boundary. Batch callers use a disposable data file;
        /// ordinary preview initialization still checks for an empty document in the app.
        @discardableResult
        public static func install(_ name: String, in file: PlannerFile) throws -> Fixture {
            let fixture: Fixture
            if names.contains(name) {
                fixture = try make(name)
            } else {
                let scenario: PlannerPreview
                switch name {
                case "empty": scenario = .empty
                case "three": scenario = .three
                case "timer": scenario = .timer
                case "insights": scenario = .insights
                default: throw PlannerError("Unknown preview scenario: \(name)")
                }
                var engine = PlannerEngine(planner: Planner(), now: { referenceDate }, calendar: calendar)
                try engine.execute(.seedPreview(scenario))
                fixture = Fixture(name: name, planner: engine.planner, now: referenceDate, day: engine.today)
            }
            try file.mutate { $0 = fixture.planner }
            return fixture
        }

        public static func make(_ name: String) throws -> Fixture {
            guard names.contains(name) else { throw PlannerError("Unknown preview scenario: \(name)") }
            let now: Date
            switch name {
            case "today-before": now = date(hour: 9, minute: 12)
            case "today-editing": now = date(hour: 9, minute: 14)
            case "notch-reminder": now = date(hour: 9, minute: 30)
            case "strip-heads-up": now = date(hour: 10, minute: 40)
            case "strip-ended": now = date(hour: 10, minute: 45)
            default: now = referenceDate
            }
            let day = DayKey("2026-11-13")
            var fixture = Fixture(name: name, planner: Planner(), now: now, day: day)
            fixture.planner.preferences.welcomeCompleted = name != "window-welcome"
            fixture.planner.preferences.notchOnMonitors = true
            if ["today-empty", "notch-idle", "window-welcome", "window-keys", "strip-data", "strip-drop"].contains(name)
            {
                return fixture
            }
            let running = !["today-before", "today-editing", "notch-reminder", "strip-undo", "strip-agent"].contains(
                name)
            fixture.planner.tasks = dayTasks(day, running: running)
            if running {
                var focus = FocusSession(taskID: id(1), limit: 45 * 60, now: date(hour: 10))
                focus.banked = now.timeIntervalSince(date(hour: 10))
                focus.resumedAt = now
                if name == "notch-paused" { focus.state = .paused; focus.resumedAt = nil }
                if name == "strip-ended" { focus.state = .finished; focus.resumedAt = nil }
                fixture.planner.focus = focus
                fixture.planner.notes = [
                    QuickNote(day: day, text: "Order printer ink\nReply to the landlord")
                ]
            }
            if ["strip-heads-up", "strip-ended"].contains(name),
                let index = fixture.planner.tasks.firstIndex(where: { $0.id == id(1) })
            {
                fixture.planner.tasks[index].steps[2].done = true
            }
            if name == "strip-agent" {
                fixture.planner.tasks.append(
                    PlanTask(
                        id: id(800), title: "Book a room for the review", day: day, createdAt: now,
                        agentID: "sample-agent"))
                if let index = fixture.planner.tasks.firstIndex(where: { $0.id == id(6) }) {
                    fixture.planner.tasks[index].agentID = "sample-agent"
                }
            }
            if name == "strip-undo" { fixture.planner.tasks.removeAll { $0.id == id(2) } }
            if name == "today-before" {
                fixture.captureText = "Prep for the design review at 1:30 for 20 min"
            }
            if name == "today-editing" { fixture.editingTaskID = id(1) }
            if ["week-full", "window-review", "window-history"].contains(name) {
                addWeek(to: &fixture)
            }
            if name == "window-projects" { addProjects(to: &fixture) }
            return fixture
        }

        private static func dayTasks(_ day: DayKey, running: Bool) -> [PlanTask] {
            let steps = [
                "List the release areas", "Pull last week's bug list", "Write the smoke tests", "Share it with Sam",
            ]
            let checklist = PlanTask(
                id: id(1), title: "Draft the test checklist", day: day, createdAt: date(hour: 8),
                remindAt: date(hour: 10), priority: .high, minutes: 45,
                steps: steps.enumerated().map {
                    Subtask(id: id(20 + $0.offset), title: $0.element, done: running && $0.offset < 2)
                })
            let bank = PlanTask(
                id: id(2), title: "Call the bank", day: day, done: running,
                completedAt: running ? date(hour: 9, minute: 45) : nil, createdAt: date(hour: 8),
                remindAt: date(hour: 9, minute: 30), minutes: 15, carriedFrom: day.adding(days: -1))
            let review = PlanTask(
                id: id(3), title: "Review the release notes", day: day, createdAt: date(hour: 8),
                remindAt: date(hour: 11), minutes: 30,
                steps: ["Read the draft", "Check the links", "Send feedback"].enumerated().map {
                    Subtask(id: id(30 + $0.offset), title: $0.element)
                })
            let rest = ["Book a dentist appointment", "Water the plants", "Outline the Q4 planning note"]
                .enumerated().map { offset, title in
                    PlanTask(
                        id: id(4 + offset), title: title, day: day, createdAt: date(hour: 8),
                        remindAt: offset == 0 ? date(hour: 16) : nil)
                }
            // Until start-time and parking-lot fields land, reminder and notepad fields carry sample data only.
            return (running ? [checklist, review] + rest + [bank] : [bank, checklist, review] + rest)
        }

        private static func addWeek(to fixture: inout Fixture) {
            let titles = [
                ["Ship v1.1", "Standup notes", "Update the help page", "Check the build"],
                ["Pay the water bill", "Return library books", "Tidy the desk"],
                ["Email the landlord", "Send the invoice", "Book a room for the review", "Sort the notes"],
                ["Refill the bird feeder", "Send the weekly update", "Sort the receipts"],
            ]
            for (offset, dayTitles) in titles.enumerated() {
                let day = fixture.day.adding(days: offset - 4)
                for (index, title) in dayTitles.enumerated() {
                    fixture.planner.tasks.append(
                        PlanTask(
                            id: id(100 + offset * 10 + index), title: title, day: day, done: true,
                            completedAt: day.date(calendar: calendar).addingTimeInterval(12 * 3600),
                            createdAt: day.date(calendar: calendar), minutes: index == 1 ? 30 : nil))
                }
            }
            for (offset, title) in ["Text Sam about Sunday", "Refill the bird feeder"].enumerated() {
                fixture.planner.tasks.append(
                    PlanTask(
                        id: id(200 + offset), title: title, day: fixture.day.adding(days: 1), createdAt: fixture.now))
            }
            fixture.planner.notes = [
                QuickNote(day: fixture.day, text: "Renew passport\nResearch standing desks\nBack up photos")
            ]
            for (offset, minutes) in [30, 25, 45, 30].enumerated() {
                let start = fixture.day.adding(days: offset - 4).date(calendar: calendar).addingTimeInterval(10 * 3600)
                fixture.planner.focusSegments.append(
                    FocusSegment(taskID: nil, start: start, end: start.addingTimeInterval(Double(minutes * 60))))
            }
        }

        private static func addProjects(to fixture: inout Fixture) {
            fixture.planner.tasks = []
            fixture.planner.focus = nil
            for (index, item) in [("Work", 5, 12), ("Launch", 3, 4), ("Home", 2, 9), ("Money", 1, 3)].enumerated() {
                let project = TaskProject(id: id(300 + index), name: item.0)
                fixture.planner.projects.append(project)
                let next = [
                    "Draft the test checklist", "Review the release notes", "Water the plants", "Call the bank",
                ][index]
                for n in 0..<(item.1 + item.2) {
                    fixture.planner.tasks.append(
                        PlanTask(
                            id: id(400 + index * 100 + n), title: n == 0 ? next : "\(item.0) task \(n + 1)",
                            day: fixture.day, done: n >= item.1,
                            completedAt: n >= item.1 ? fixture.now : nil, createdAt: fixture.now, projectID: project.id)
                    )
                }
            }
            for n in 0..<4 {
                fixture.planner.tasks.append(
                    PlanTask(id: id(900 + n), title: "Unfiled task \(n + 1)", day: fixture.day, createdAt: fixture.now))
            }
        }

        private static func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
        }

        private static func date(hour: Int, minute: Int = 0, second: Int = 0) -> Date {
            calendar.date(
                from: DateComponents(year: 2026, month: 11, day: 13, hour: hour, minute: minute, second: second))!
        }
    }
#endif
