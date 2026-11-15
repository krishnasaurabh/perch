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
    private(set) var menuBarItem: MenuBarItem?
    var statusItem: NSStatusItem? { menuBarItem?.statusItem }

    func applicationDidFinishLaunching(_ n: Notification) {
        #if DEBUG || PERCH_TESTING
            store = Self.makePreviewStore()
        #else
            store = PlannerStore()
        #endif
        // Once per launch, before the first tick: a timer left running by a crash or kill -9 comes back
        // paused with its last checkpoint banked. The time the app was gone is not focus time.
        store.beginApplication()
        #if DEBUG || PERCH_TESTING
            model = NotchModel(motionPolicy: MotionScript.policyOverride)
        #else
            model = NotchModel()
        #endif
        services = Services(store: store)
        services.attach(model: model)
        notch = NotchController(store: store, model: model, services: services)
        notch.start()
        KeysWindow.install(store: store, model: model)
        setupMenuBar()
        setupURLScheme()
        #if DEBUG || PERCH_TESTING
            setupActivityDump()
            MotionScript.startIfRequested(store: store, model: model)  // CI motion capture only (--motion-script)

            let previewOwnsNavigation = startPreviewIfRequested()
            if !store.prefs.welcomeCompleted && !previewOwnsNavigation { showWelcome() }
        #else
            if !store.prefs.welcomeCompleted { showWelcome() }
        #endif
    }

    private func setupMenuBar() {
        menuBarItem = MenuBarItem(
            store: store,
            navigate: { [weak self] action in
                guard let self else { return }
                switch action {
                case .addTask, .openToday: self.openWorkspace()
                case .openWeek: NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.week)
                case .settings: self.openSettings()
                case .quit: NSApp.terminate(nil)
                case .privacy, .pauseOrContinue, .addFiveMinutes: break
                }
            })
    }

    @objc func openWorkspace() { NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home) }
    @objc func hideTaskCount() { model.hideTaskCount(in: store) }
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
                        .init(
                            kind: .message, title: AppL10n.text("Task added"),
                            subtitle: AppL10n.text("Confirmed external request")), for: 2.5)
                }
            }
        case .open(let page):
            guard let destination = NotchPage(rawValue: page) else { return }
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: destination)
        }
    }

    private func showWelcome() {
        WindowHost.show("welcome", title: "Welcome to Perch", size: WelcomeView.windowSize) {
            WelcomeView { [weak self] in self?.completeWelcome() }
                .environmentObject(store).environmentObject(services)
        }
    }

    func completeWelcome() {
        store.updatePrefs {
            $0.welcomeCompleted = true
        }
        WindowHost.windows["welcome"]?.close()
        NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
    }
}

extension AppDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.flushPendingText() == false ? .terminateCancel : .terminateNow
    }
}
