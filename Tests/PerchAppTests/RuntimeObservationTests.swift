import AppKit
import Combine
import Foundation
import XCTest
@testable import PerchApp
@testable import PlannerCore

private final class RuntimeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var offMain = true
    func read() { lock.lock(); defer { lock.unlock() }; reads += 1; offMain = offMain && !Thread.isMainThread }
    var value: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (reads, offMain) }
}

@MainActor
private final class RuntimeScheduler: AppScheduling {
    final class Token: AppScheduledAction {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    var time = Date(timeIntervalSince1970: 1_800_000_000)
    var jobs: [(Date, Token, @MainActor () -> Void)] = []
    var wakeups = 0
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        let token = Token()
        jobs.append((time.addingTimeInterval(delay), token, action))
        return token
    }
    func advance(_ interval: TimeInterval) {
        let end = time.addingTimeInterval(interval)
        while let next = jobs.filter({ !$0.1.cancelled && $0.0 <= end }).min(by: { $0.0 < $1.0 }) {
            jobs.removeAll { $0.1 === next.1 || $0.1.cancelled }
            time = next.0
            wakeups += 1
            next.2()
        }
        time = end
    }
}

final class RuntimeObservationTests: XCTestCase {
    func testPointerHasNoIdleWakeupsAndStopsAtRelease() async {
        await MainActor.run {
            let scheduler = RuntimeScheduler()
            var pressed = true
            let pointer = DragPointerObservation(
                scheduler: scheduler, now: { scheduler.time },
                pressed: { pressed }, sample: {})
            scheduler.advance(600)
            XCTAssertEqual(scheduler.wakeups, 0)
            pointer.begin()
            scheduler.advance(1)
            XCTAssertGreaterThanOrEqual(pointer.samples, 14)
            XCTAssertLessThanOrEqual(pointer.samples, 15)
            pressed = false
            scheduler.advance(1)
            let stopped = scheduler.wakeups
            scheduler.advance(600)
            XCTAssertEqual(scheduler.wakeups, stopped)
            print("pointer-wakeups idle=0 dragSamples=\(pointer.samples) afterRelease=0")
        }
    }

    func testMissingMouseUpCannotPollForever() async {
        await MainActor.run {
            let scheduler = RuntimeScheduler()
            let pointer = DragPointerObservation(
                scheduler: scheduler, now: { scheduler.time },
                pressed: { true }, sample: {})
            pointer.begin()
            scheduler.advance(121)
            let stopped = scheduler.wakeups
            scheduler.advance(600)
            XCTAssertEqual(scheduler.wakeups, stopped)
            XCTAssertLessThanOrEqual(pointer.samples, 1_800)
            pointer.begin()
            scheduler.advance(1)
            XCTAssertGreaterThan(scheduler.wakeups, stopped)
            pointer.stop()
            let beforeCancel = scheduler.wakeups
            scheduler.advance(600)
            XCTAssertEqual(scheduler.wakeups, beforeCancel)
        }
    }

    func testFullscreenFallbackIsBoundedWhenAXIsUnavailable() async {
        await MainActor.run {
            XCTAssertEqual(FullscreenObservation.recoveryCadence(registeredNotifications: 0), 5)
            XCTAssertEqual(FullscreenObservation.recoveryCadence(registeredNotifications: 4), 30)
        }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRuntimeLoaderSkipsUnchangedRevisionAndDecodesOffMain() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = RuntimeCounters()
        var io = PlannerFile.IO()
        io.read = { url in
            counters.read(); return try Data(contentsOf: url)
        }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), io: io,
            preferences: MemoryPlannerPreferences())
        // A missing synthetic file is valid empty storage, without any live preferences.
        let worker = PlannerRuntimeIO()
        let loaded = expectation(description: "background load")
        worker.load(file, after: nil, force: true) { _, result in
            XCTAssertNotNil(try? result?.get())
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertTrue(counters.value.1)
        let count = counters.value.0
        let unchanged = expectation(description: "metadata-only check")
        worker.load(file, after: nil, force: false) { _, result in
            XCTAssertNil(result)
            unchanged.fulfill()
        }
        await fulfillment(of: [unchanged], timeout: 3)
        XCTAssertEqual(counters.value.0, count)
    }

    func testVnodeObservesInPlaceAtomicAndDirectoryReplacement() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("planner.json")
        try Data("first".utf8).write(to: url)
        let first = expectation(description: "in-place edit")
        let second = expectation(description: "atomic edit")
        let third = expectation(description: "directory replacement")
        let fourth = expectation(description: "new directory remains observed")
        let observer = await MainActor.run { () -> PlannerDirectoryObserver in
            var phase = 0
            return PlannerDirectoryObserver(url: url) {
                let text = try? String(contentsOf: url, encoding: .utf8)
                if phase == 0 && text == "inplace" { phase = 1; first.fulfill() }
                if phase == 1 && text == "atomic" { phase = 2; second.fulfill() }
                if phase == 2 && text == "replacement" { phase = 3; third.fulfill() }
                if phase == 3 && text == "final" { phase = 4; fourth.fulfill() }
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("inplace".utf8))
        try handle.close()
        await fulfillment(of: [first], timeout: 3)
        try Data("atomic".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [second], timeout: 3)
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("old-data"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [third], timeout: 3)
        try Data("final".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [fourth], timeout: 3)
        let registrations = await MainActor.run { observer.registrations }
        XCTAssertGreaterThan(registrations, 3)
        withExtendedLifetime(observer) {}
    }

    func testVnodeBurstIsCoalescedAndObserverIsReleased() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.json")
        try Data("initial".utf8).write(to: url)
        let delivered = expectation(description: "burst delivered")
        delivered.assertForOverFulfill = false
        var observer: PlannerDirectoryObserver? = await MainActor.run {
            PlannerDirectoryObserver(url: url) { delivered.fulfill() }
        }
        weak var weakObserver = observer
        for index in 0..<20 { try Data("\(index)".utf8).write(to: url, options: .atomic) }
        await fulfillment(of: [delivered], timeout: 3)
        let deliveries = await MainActor.run { observer!.deliveries }
        XCTAssertLessThan(deliveries, 20)
        await MainActor.run { observer = nil }
        XCTAssertNil(weakObserver)
    }

    func testRepairFindsFileCreatedAfterWatchRegistration() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("missing")
        let url = directory.appendingPathComponent("planner.json")
        let event = expectation(description: "repaired observer")
        event.assertForOverFulfill = false
        let observer = await MainActor.run { PlannerDirectoryObserver(url: url) { event.fulfill() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: url, options: .atomic)
        await MainActor.run { observer.repair() }
        try Data("changed".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [event], timeout: 3)
        withExtendedLifetime(observer) {}
    }

    func testMissedEventRecoveryCoalescesBurstAndDoesNotRereadUnchangedData() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = RuntimeCounters()
        var io = PlannerFile.IO()
        io.read = { url in
            counters.read(); return try Data(contentsOf: url)
        }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), io: io,
            preferences: MemoryPlannerPreferences())
        let store = await MainActor.run { PlannerStore(file: file, watching: false) }
        let initial = counters.value.0
        var planner = Planner()
        planner.tasks = [PlanTask(title: "Recovered synthetic edit", day: "2027-01-15")]
        try PlannerFile.encoder.encode(PlannerDiskDocument(planner)).write(to: file.url, options: .atomic)
        let loaded = expectation(description: "missed event recovered")
        let subscription = await MainActor.run {
            store.$planner.sink { if !$0.tasks.isEmpty { loaded.fulfill() } }
        }
        await MainActor.run { for _ in 0..<20 { store.recoverObservation() } }
        await fulfillment(of: [loaded], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(counters.value.0 - initial, 1)
        await MainActor.run { for _ in 0..<20 { store.recoverObservation() } }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counters.value.0 - initial, 1)
        withExtendedLifetime(store) {}
    }

    func testStoreIdleDoesNotPublishOrDecodeEverySecond() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = RuntimeCounters()
        var io = PlannerFile.IO()
        io.read = { url in
            counters.read(); return try Data(contentsOf: url)
        }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), io: io,
            preferences: MemoryPlannerPreferences())
        let store = await MainActor.run { PlannerStore(file: file) }
        let initialReads = counters.value.0
        let publications = await MainActor.run { () -> AnyCancellable in
            store.$planner.dropFirst().sink { _ in XCTFail("Idle planner must not republish") }
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(counters.value.0, initialReads)
        withExtendedLifetime((store, publications)) {}
    }

    func testStoreSchedulesCheckpointWithoutPerSecondPublications() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        var planner = Planner()
        planner.focus = FocusSession(taskID: nil, limit: nil, now: Date().addingTimeInterval(-29.5))
        try file.save(planner)
        let checkpoint = expectation(description: "durable boundary")
        let store = await MainActor.run { PlannerStore(file: file) }
        let subscription = await MainActor.run {
            store.$planner.dropFirst().sink { state in
                if (state.focus?.banked ?? 0) >= 30 { checkpoint.fulfill() }
            }
        }
        await fulfillment(of: [checkpoint], timeout: 3)
        subscription.cancel()
        XCTAssertGreaterThanOrEqual(try file.load().focus?.banked ?? 0, 30)
        let idle = await MainActor.run {
            store.$planner.dropFirst().sink { _ in XCTFail("No timer-second publication between checkpoints") }
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        withExtendedLifetime((store, idle)) {}
    }

    func testStoreObservesSameTimestampAtomicReplacement() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        let store = await MainActor.run { PlannerStore(file: file) }
        let changed = expectation(description: "new revision published")
        let subscription = await MainActor.run {
            store.$planner.sink { if $0.tasks.first?.title == "External synthetic task" { changed.fulfill() } }
        }
        let date = file.modificationDate!
        var planner = Planner()
        planner.tasks = [PlanTask(title: "External synthetic task", day: "2027-01-15")]
        try file.save(planner)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.url.path)
        await fulfillment(of: [changed], timeout: 3)
        withExtendedLifetime((store, subscription)) {}
    }
}
