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
            let page = args.firstIndex(of: "--page").flatMap { i in
                i + 1 < args.count ? NotchPage(rawValue: args[i + 1]) : nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.open(page: page, pinned: true) }
        }
        if !store.prefs.welcomeCompleted && !CommandLine.arguments.contains("--preview-open") { showWelcome() }
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
        Publishers.Merge(
            NotificationCenter.default.publisher(for: ShortcutStore.didChange),
            NotificationCenter.default.publisher(for: ShortcutStore.didFail)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.openItem?.title = Self.openTitle() }
        .store(in: &cancellables)
    }

    private static func openTitle() -> String { "Open Perch (\(ShortcutStore.load().display))" }

    @objc func openWorkspace() { NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home) }
    @objc func openDashboard() { DashboardWindow.show(store: store, model: model, services: services) }
    @objc func openSettings() { SettingsWindow.show(store: store, services: services) }

    // perch://add?title=Buy%20milk   perch://open?page=week
    var externalTaskConfirmation: ExternalTaskConfirming = ExternalTaskConfirmationController()
    private var pendingExternalTask: UUID?

    private func setupURLScheme() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let store, let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let request = ExternalURLRequest.parse(raw, now: store.engine.now(), resetHour: store.prefs.resetHour)
        else { return }
        switch request {
        case .add(let task):
            // One visible request at a time. Neither another URL nor a repeated callback can
            // replace what the person reviewed, approve it, or perform the write twice.
            guard pendingExternalTask == nil else { return }
            let token = UUID()
            pendingExternalTask = token
            externalTaskConfirmation.present(task) { [weak self] confirmed in
                guard let self, self.pendingExternalTask == token else { return }
                self.pendingExternalTask = nil
                guard confirmed else { return }
                if store.apply({ try $0.addTasks([task.title], on: task.day, literal: true) }) != nil {
                    // Keep untrusted task text out of status/agent messages.
                    self.model?.show(
                        .init(kind: .message, title: "Task added", subtitle: "Confirmed external request"), for: 2.5)
                }
            }
        case .open(let page):
            guard let destination = NotchPage(rawValue: page) else { return }
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: destination)
        }
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

extension AppDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.flushPendingText() == false ? .terminateCancel : .terminateNow
    }
}
