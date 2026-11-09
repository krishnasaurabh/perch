import AppKit
import AVFoundation
import Combine
import EventKit
import PlannerCore
import Speech
import UserNotifications

/// Every system integration, behind one object the views can observe.
@MainActor
final class Services: ObservableObject {
    let store: PlannerStore
    weak var model: NotchModel?
    let calendar: CalendarService
    let reminders: ReminderService
    let remindersSync: RemindersSync
    let voice: VoiceCapture
    let clips: ClipsService

    init(store: PlannerStore) {
        self.store = store
        calendar = CalendarService(store: store)
        reminders = ReminderService(store: store)
        remindersSync = RemindersSync(store: store)
        voice = VoiceCapture()
        clips = ClipsService(store: store)
    }

    func attach(model: NotchModel) {
        self.model = model
        reminders.model = model
        clips.model = model
    }

    func focusFinished() {
        let p = store.planner
        let title = p.focus?.taskID.flatMap { id in p.tasks.first { $0.id == id }?.title }
        if p.preferences.focusCompletionSound { NSSound(named: "Glass")?.play() }
        let mins = Int((p.focus?.limit ?? 0) / 60)
        model?.show(.init(kind: .focusDone(p.focus?.taskID), title: "Timer finished",
                          subtitle: title.map { "You gave \($0) \(mins) minutes of focus. Mark it done, or take a break." } ?? "\(mins)-minute focus block done."))
        reminders.notify(id: "focus-\(UUID())", title: "Timer finished", body: title ?? "Time for a break.")
    }
}

// MARK: - Calendar (read-only)

@MainActor
final class CalendarService: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let colorHex: String
        let location: String?
        let calendarTitle: String
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [EKCalendar] = []
    private let ek = EKEventStore()
    private let store: PlannerStore

    init(store: PlannerStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    var hasAccess: Bool { access == .fullAccess }

    func requestAccess() async {
        _ = try? await ek.requestFullAccessToEvents()
        access = EKEventStore.authorizationStatus(for: .event)
        refresh()
    }

    func refresh(day: Date = Date()) {
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { events = []; return }
        calendars = ek.calendars(for: .event)
        let hidden = Set(store.prefs.hiddenCalendarIDs)
        let cals = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { events = []; return }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: cals)
        events = ek.events(matching: pred).sorted { $0.startDate < $1.startDate }.map {
            Event(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Event",
                  start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                  colorHex: $0.calendar.cgColor.flatMap { NSColor(cgColor: $0) }.map(SwiftUIColorBridge.hex) ?? "#8E8CF5",
                  location: $0.location, calendarTitle: $0.calendar.title)
        }
    }

    /// The next event starting within `minutes`, for the closed-notch "In 5 min" nudge.
    func startingSoon(within minutes: Double = 5, now: Date = Date()) -> Event? {
        events.first { !$0.allDay && $0.start > now && $0.start.timeIntervalSince(now) <= minutes * 60 }
    }
}

enum SwiftUIColorBridge {
    static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? .systemPurple
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

// MARK: - Reminders that ring in the notch

@MainActor
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    let store: PlannerStore
    weak var model: NotchModel?
    private var fired = Set<String>()
    @Published var notificationsAllowed = false

    init(store: PlannerStore) {
        self.store = store
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            refreshAuthorization()
        }
    }

    func refreshAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            Task { @MainActor in self.notificationsAllowed = s.authorizationStatus == .authorized }
        }
    }

    func requestAuthorization() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        refreshAuthorization()
    }

    /// Called every second. Fires each reminder once, in the notch and as a notification.
    func check(now: Date = Date()) {
        for t in store.planner.tasks where !t.done {
            guard let r = t.remindAt, r <= now, now.timeIntervalSince(r) < 120 else { continue }
            let key = "\(t.id)-\(r.timeIntervalSince1970)"
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            let body = t.minutes.map { "Time for your \($0)-minute block. Start the timer, snooze, or check it off." }
                ?? "It's time for \(t.title). Start the timer, snooze, or check it off."
            model?.show(.init(kind: .reminder(t.id), title: t.title, subtitle: body))
            NSSound(named: "Glass")?.play()
            notify(id: key, title: t.title, body: body)
        }
    }

    func notify(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The notch already shows it; don't double up with a banner while the app is frontmost.
        [.sound]
    }
}

// MARK: - Two-way sync with an Apple Reminders list named "Perch"

@MainActor
final class RemindersSync: ObservableObject {
    static let listName = "Perch"
    let store: PlannerStore
    private let ek = EKEventStore()
    @Published var lastError: String?
    private var syncing = false
    private var cancellable: AnyCancellable?

    init(store: PlannerStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        cancellable = store.$planner.debounce(for: .seconds(1.5), scheduler: RunLoop.main).sink { [weak self] _ in self?.sync() }
    }

    var hasAccess: Bool {
        let s = EKEventStore.authorizationStatus(for: .reminder)
        return s == .fullAccess
    }

    func requestAccess() async -> Bool {
        _ = try? await ek.requestFullAccessToReminders()
        return hasAccess
    }

    private func list() throws -> EKCalendar {
        if let c = ek.calendars(for: .reminder).first(where: { $0.title == Self.listName }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: ek)
        c.title = Self.listName
        guard let source = ek.defaultCalendarForNewReminders()?.source ?? ek.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
        else { throw PlannerError("Perch found no Reminders account on this Mac.") }
        c.source = source
        try ek.saveCalendar(c, commit: true)
        return c
    }

    /// Open tasks from today on go to Reminders; ticking one off on the phone completes it here.
    /// Only the "Perch" list is ever touched.
    func sync() {
        guard store.prefs.remindersSync, hasAccess, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let cal = try list()
            let pred = ek.predicateForReminders(in: [cal])
            var fetched: [EKReminder] = []
            let sem = DispatchSemaphore(value: 0)
            ek.fetchReminders(matching: pred) { r in fetched = r ?? []; sem.signal() }
            sem.wait()
            let byID = Dictionary(fetched.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            let today = store.today
            var links: [UUID: String] = [:]
            var completedRemotely: [UUID] = []

            for t in store.planner.tasks {
                guard let d = t.day, d >= today else { continue }
                let r = t.reminderLink.flatMap { byID[$0] }
                if let r, r.isCompleted, !t.done, d == today { completedRemotely.append(t.id); continue }
                if t.done { if let r, !r.isCompleted { r.isCompleted = true; try? ek.save(r, commit: false) }; continue }
                let rem = r ?? EKReminder(eventStore: ek)
                rem.calendar = cal
                rem.title = t.title
                rem.notes = t.notes.isEmpty ? nil : t.notes
                rem.priority = [.high: 1, .medium: 5, .low: 9, .none: 0][t.priority]!
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: d.date())
                if let at = t.remindAt {
                    comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                    rem.alarms = store.prefs.ringOnPhone ? [EKAlarm(absoluteDate: at)] : nil
                } else { rem.alarms = nil }
                rem.dueDateComponents = comps
                try ek.save(rem, commit: false)
                if t.reminderLink != rem.calendarItemIdentifier { links[t.id] = rem.calendarItemIdentifier }
            }
            try ek.commit()
            guard !links.isEmpty || !completedRemotely.isEmpty else { lastError = nil; return }
            store.apply { e in
                for (id, link) in links { if let i = e.planner.tasks.firstIndex(where: { $0.id == id }) { e.planner.tasks[i].reminderLink = link } }
                for id in completedRemotely { _ = try? e.complete(id.uuidString) }
            }
            lastError = nil
        } catch {
            lastError = "Reminders sync failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - On-device voice capture

@MainActor
final class VoiceCapture: ObservableObject {
    enum State: Equatable { case idle, listening, error(String) }
    @Published var state: State = .idle
    @Published var transcript = ""
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onFinish: ((String) -> Void)?

    func toggle(onFinish: @escaping (String) -> Void) {
        if state == .listening { stop() } else { Task { await start(onFinish: onFinish) } }
    }

    func start(onFinish: @escaping (String) -> Void) async {
        self.onFinish = onFinish
        transcript = ""
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { state = .error("Allow Speech Recognition for Perch under System Settings › Privacy & Security."); return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { state = .error("Perch needs microphone access. Enable it under System Settings › Privacy & Security."); return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { state = .error("Speech recognition isn't available right now."); return }
        guard recognizer.supportsOnDeviceRecognition else {
            state = .error("Dictation for your language isn't installed on this Mac. Download it under System Settings › Keyboard › Dictation.")
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never leaves the Mac
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { state = .error("Perch can't find a microphone."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in request.append(buf) }
        do { try engine.start() } catch { state = .error("Recording failed to start: \(error.localizedDescription)"); return }

        self.engine = engine; self.request = request
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil { self.finish() }
            }
        }
        // Stop on silence-ish: cap a single capture at 30 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in if self?.state == .listening { self?.stop() } }
    }

    func stop() {
        request?.endAudio()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard state == .listening else { return }
        task?.cancel()
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        engine = nil; request = nil; task = nil
        state = .idle
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { state = .error("Heard nothing usable. Tap the mic to retry.") } else { onFinish?(text) }
        onFinish = nil
    }
}
