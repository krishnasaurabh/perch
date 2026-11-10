import AppKit
import Combine
import PlannerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: PlannerStore!
    var model: NotchModel!
    var services: Services!
    var notch: NotchController!
    var statusItem: NSStatusItem?
    /// "Open Perch (<chord>)": kept so a rebind in Settings can retitle it without a relaunch.
    private var openItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        store = PlannerStore()
        // Once per launch, before the first tick: a timer left running by a crash or kill -9 comes back
        // paused with its last checkpoint banked. The time the app was gone is not focus time.
        store.applyUntracked { $0.recoverFocus() }
        model = NotchModel(motionPolicy: MotionScript.policyOverride)
        services = Services(store: store)
        services.attach(model: model)
        notch = NotchController(store: store, model: model, services: services)
        notch.start()
        setupMenuBar()
        setupURLScheme()
        setupActivityDump()
        MotionScript.startIfRequested(store: store, model: model)  // CI motion capture only (--motion-script)

        let args = CommandLine.arguments
        if args.contains("--demo") { seedDemo() }
        if let i = args.firstIndex(of: "--scenario"), i + 1 < args.count { seedScenario(args[i + 1]) }
        if args.contains("--preview-open") {
            // `--page <home|week|clips|insights>` picks the page the preview opens on (CI snapshots).
            let page = args.firstIndex(of: "--page").flatMap { i in i + 1 < args.count ? NotchPage(rawValue: args[i + 1]) : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.open(page: page, pinned: true) }
        }
        if !store.prefs.welcomeCompleted && !CommandLine.arguments.contains("--preview-open") { showWelcome() }
    }

    /// Sample day for screenshots (`--demo`), only into an empty planner.
    private func seedDemo() {
        guard store.planner.tasks.isEmpty else { return }
        store.apply { e in
            _ = try e.addTasks(["Draft release notes !high #launch for 50 min", "Call the bank at 4pm", "Merge the auth branch #work",
                                "Water the plants every 3 days", "Plan team offsite friday", "Renew car registration next monday",
                                "Learn piano someday"])
            _ = try e.complete("Merge the auth branch")
            try e.writeNotepad(on: e.today, text: "Try batching email to 11 and 4\nQuestions for the design sync")
            _ = try e.startTimer(task: "Draft release notes", minutes: 50)
            e.planner.preferences.welcomeCompleted = true
        }
    }

    /// Fixed planner states for CI snapshots (`--scenario <name>`), only into an empty planner.
    /// `empty`: nothing yet. `three`: three tasks for today. `timer`: the same with a focus session running.
    /// `insights`: two weeks of finished tasks and focus, for the Insights page.
    private func seedScenario(_ name: String) {
        guard store.planner.tasks.isEmpty else { return }
        store.apply { e in
            e.planner.preferences.welcomeCompleted = true
            switch name {
            case "three", "timer":
                let added = try e.addTasks(["Draft the test checklist !high #work", "Review the release notes", "Choose a desk plant"], on: .day(e.today))
                if name == "timer", let first = added.first { _ = try e.startTimer(task: first.id.uuidString, minutes: 45) }
            case "insights":
                let cal = Calendar.current, now = Date()
                let doneByDay = [2, 4, 3, 5, 1, 6, 4, 3, 2, 3, 2, 0, 3, 2]  // index 0 = 13 days ago, 13 = today
                for (i, done) in doneByDay.enumerated() {
                    let ago = doneByDay.count - 1 - i
                    let date = cal.date(byAdding: .day, value: -ago, to: now)!
                    let day = e.dayKey(date)
                    for n in 0..<(done + 1 + i % 2) {
                        let finished = n < done
                        let at = cal.date(bySettingHour: 9 + n, minute: 15, second: 0, of: date) ?? date
                        e.planner.tasks.append(PlanTask(title: "Task \(n + 1)", day: day, done: finished, completedAt: finished ? at : nil, createdAt: date))
                    }
                    if ago > 0, done > 0, let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: date) {
                        e.planner.focusLog.append(FocusSegment(taskID: nil, start: start, end: start.addingTimeInterval(Double(done) * 600)))
                    }
                }
            default: break
            }
        }
    }

    // Menu bar icon: a fallback way in, plus quit.
    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Perch")
        let menu = NSMenu()
        let open = menu.addItem(withTitle: Self.openTitle(), action: #selector(openWorkspace), keyEquivalent: "")
        open.target = self
        openItem = open
        menu.addItem(withTitle: "Dashboard", action: #selector(openDashboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // didFail too: a chord macOS refuses is rolled back after didChange, so re-read the store each time.
        Publishers.Merge(NotificationCenter.default.publisher(for: ShortcutStore.didChange),
                         NotificationCenter.default.publisher(for: ShortcutStore.didFail))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openItem?.title = Self.openTitle() }
            .store(in: &cancellables)
    }

    private static func openTitle() -> String { "Open Perch (\(ShortcutStore.load().display))" }

    @objc func openWorkspace() { NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home) }
    @objc func openDashboard() { DashboardWindow.show(store: store, model: model, services: services) }
    @objc func openSettings() { SettingsWindow.show(store: store, services: services) }

    // perch://add?title=Buy%20milk   perch://open?page=week
    private func setupURLScheme() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URLComponents(string: s) else { return }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch url.host {
        case "add":
            if let title = q["title"], !title.isEmpty {
                let day = try? DayRef.parse(q["date"], now: Date(), resetHour: store.prefs.resetHour)
                if let added = store.apply({ try $0.addTasks([title], on: day) }), let t = added.first {
                    model.show(.init(kind: .message, title: "Added", subtitle: t.title), for: 2.5)
                }
            }
        case "open":
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: q["page"].flatMap(NotchPage.init(rawValue:)) ?? .home)
        default: break
        }
    }

    /// `--dump-activity <path>`: one JSON line per timeline pass (what shows, what the notch shows, next wake).
    private func setupActivityDump() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--dump-activity"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        services.timeline.onPass = { [weak self] showing, wake in
            let row: [String: Any] = ["at": iso.string(from: Date()), "showing": showing ?? NSNull(),
                                      "notch": self?.model.activity?.title ?? NSNull(),
                                      "nextWake": wake.map(iso.string(from:)) ?? NSNull()]
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close()
        }
        services.timeline.refresh()
    }

    private func showWelcome() {
        WindowHost.show("welcome", title: "Welcome to Perch", size: CGSize(width: 560, height: 520)) {
            WelcomeView { [weak self] in
                self?.store.updatePrefs { $0.welcomeCompleted = true }
                WindowHost.windows["welcome"]?.close()
                NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            }
            .environmentObject(store).environmentObject(services)
        }
    }
}

extension PlannerStore {
    /// Engine bookkeeping the user didn't do (launch recovery, timer ticks): a locked write like `apply`,
    /// but kept off the undo stack. Undoing a recovery would resume a timer from before the crash and
    /// credit the offline gap; a checkpoint every 30 s would bury the user's own edits and clear redo.
    @discardableResult
    func applyUntracked<T>(_ body: (inout PlannerEngine) throws -> T) -> T? {
        // Pick up a pending agent edit first so it still lands on the undo stack.
        reloadFromDisk(external: true)
        do {
            let result: T = try file.mutate { p in
                var e = PlannerEngine(planner: p)
                let r = try body(&e)
                p = e.planner
                return r
            }
            reloadFromDisk(external: false)
            return result
        } catch {
            lastError = (error as? PlannerError)?.message ?? error.localizedDescription
            return nil
        }
    }
}

/// First run: what it is, the one shortcut, and optional permissions. Every permission is optional.
struct WelcomeView: View {
    let done: () -> Void
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @State private var granted: Set<String> = []
    @State private var shortcut = ShortcutStore.load().display

    var body: some View {
        VStack(spacing: 18) {
            OwlMark(size: 64).padding(.top, 34)
            Text("Your plan lives in the notch now.").font(.system(size: 22, weight: .bold))
            Text("Hover over the notch, or press \(shortcut). Type or say what's on your mind and it becomes a sorted task.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 400)
                .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in shortcut = ShortcutStore.load().display }
                .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didFail)) { _ in shortcut = ShortcutStore.load().display }
            VStack(spacing: 8) {
                row("calendar", "Calendar", "Shows today's events next to your list. Perch never edits them.", "cal") { await services.calendar.requestAccess() }
                row("bell", "Notifications", "A heads-up when a reminder fires or a timer ends.", "notif") { await services.reminders.requestAuthorization() }
                row("mic", "Voice", "Dictate tasks. Speech is processed on this Mac.", "mic") {
                    _ = await withCheckedContinuation { c in SFSpeechRecognizerBridge.request { c.resume(returning: $0) } }
                }
                row("iphone", "Reminders sync", "Mirror your list to iPhone and Apple Watch.", "rem") {
                    if await services.remindersSync.requestAccess() { store.updatePrefs { $0.remindersSync = true } }
                }
            }
            .frame(width: 440)
            Text("Skip any permission for now. You can enable it later in Settings.").font(.caption).foregroundStyle(.secondary)
            Button("Open my workspace", action: done).keyboardShortcut(.defaultAction).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    func row(_ symbol: String, _ title: String, _ detail: String, _ key: String, _ action: @escaping () async -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted.contains(key) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else {
                Button("Allow") { Task { await action(); granted.insert(key) } }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

import Speech
enum SFSpeechRecognizerBridge {
    static func request(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in done(s == .authorized) }
    }
}
