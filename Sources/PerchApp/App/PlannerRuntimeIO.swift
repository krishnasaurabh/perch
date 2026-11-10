import AppKit
import PlannerCore

/// Watches both the file (in-place edits) and its directory (atomic replacement).
/// The parent's watch and periodic repair also survive replacement of the directory itself.
@MainActor
final class PlannerDirectoryObserver {
    private struct Watch {
        let identity: UInt64
        let source: DispatchSourceFileSystemObject
    }
    private let url: URL
    private let changed: @MainActor () -> Void
    private var watches: [URL: Watch] = [:]
    private var delivery: DispatchWorkItem?
    private(set) var registrations = 0
    private(set) var deliveries = 0

    init(url: URL, changed: @escaping @MainActor () -> Void) {
        self.url = url.standardizedFileURL
        self.changed = changed
        repair()
    }

    deinit {
        delivery?.cancel()
        for watch in watches.values { watch.source.cancel() }
    }

    func repair() {
        let directory = url.deletingLastPathComponent()
        for path in Set([url, directory, directory.deletingLastPathComponent()]) {
            let identity =
                (try? FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber]) as? NSNumber
            if watches[path]?.identity == identity?.uint64Value { continue }
            watches.removeValue(forKey: path)?.source.cancel()
            guard let identity else { continue }
            let fd = open(path.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.receivedEvent() }
            }
            source.setCancelHandler { close(fd) }
            watches[path] = Watch(identity: identity.uint64Value, source: source)
            registrations += 1
            source.resume()
        }
    }

    private func receivedEvent() {
        repair()
        // Bounded leading-edge coalescing: a continuous writer cannot postpone delivery forever.
        guard delivery == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delivery = nil
                self.deliveries += 1
                self.changed()
            }
        }
        delivery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

/// All unattended file locks, reads, decoding and checkpoint writes run off the UI thread.
final class PlannerRuntimeIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.perch.planner.runtime", qos: .utility)

    func load(
        _ file: PlannerFile, after revision: PlannerFileRevision?, force: Bool,
        completion: @escaping @MainActor (PlannerFileRevision?, Result<Planner, Error>?) -> Void
    ) {
        queue.async {
            let before = PlannerFileRevision(url: file.url)
            let result: Result<Planner, Error>? = force || before != revision ? Result { try file.load() } : nil
            // Bind the result to the pre-read revision. A write during/after load causes a follow-up.
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(before, result) } }
        }
    }

    func tick(
        _ file: PlannerFile, at time: Date,
        completion: @escaping @MainActor (Result<PlannerCommandResult<PlannerActionResult>, Error>) -> Void
    ) {
        queue.async {
            let result = Result {
                try PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { time })
                    .execute(.tick, origin: .background)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}
