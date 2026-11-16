import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class GuardedDeletionUndoTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file: PlannerFile
        let pipeline: PlannerCommandPipeline
        let deleted: PlanTask
        let kept: PlanTask
        let token: PlannerDeletionUndoToken

        init(
            io: PlannerFile.IO = PlannerFile.IO(),
            clock: any PlannerClock = ClosurePlannerClock { FixtureTime.now }
        ) throws {
            file = PlannerFile(
                url: root.appendingPathComponent("planner.json"), io: io, preferences: MemoryPlannerPreferences())
            pipeline = PlannerCommandPipeline(file: file, clock: clock)
            let tasks = try pipeline.perform(origin: .user) {
                try $0.addTasks(["Call the bank", "Kept task"], literal: true)
            }.value
            deleted = tasks[0]; kept = tasks[1]
            let result = try pipeline.perform(origin: .user) { try $0.delete(tasks[0].id, on: .day($0.today)) }
            token = PlannerDeletionUndoToken(after: result.state, taskIDs: [tasks[0].id])
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private enum FixtureTime { static let now = Date(timeIntervalSince1970: 1_800_000_000) }

    func testGuardedDeletionRestoresOnlyNamedTaskAndPreservesRedo() throws {
        let f = try Fixture()
        let restored = try XCTUnwrap(f.pipeline.undoLocalDeletion(f.token))
        XCTAssertEqual(restored.tasks.map(\.id), [f.deleted.id, f.kept.id])
        XCTAssertTrue(f.pipeline.canRedo)
        XCTAssertNil(try f.pipeline.undoLocalDeletion(f.token), "A used token cannot traverse the preceding edit")
        _ = try f.pipeline.redo()
        XCTAssertEqual(try f.file.load().tasks.map(\.id), [f.kept.id])
        _ = try f.pipeline.undo()
        XCTAssertEqual(try f.file.load().tasks.map(\.id), [f.deleted.id, f.kept.id])
    }

    func testSupersedingLocalEditRejectsWithoutConsumingEitherStack() throws {
        let f = try Fixture()
        _ = try f.pipeline.perform(origin: .user) { try $0.rename(f.kept.id, on: .day($0.today), to: "Changed") }
        let bytes = try Data(contentsOf: f.file.url)
        XCTAssertNil(try f.pipeline.undoLocalDeletion(f.token))
        XCTAssertEqual(try Data(contentsOf: f.file.url), bytes)
        XCTAssertFalse(f.pipeline.canRedo)
        _ = try f.pipeline.undo()
        XCTAssertEqual(try f.file.load().tasks.first?.title, "Kept task")
        XCTAssertTrue(f.pipeline.canRedo)
        let wrong = PlannerDeletionUndoToken(after: try f.file.load(), taskIDs: [UUID()])
        let before = try Data(contentsOf: f.file.url)
        XCTAssertNil(try f.pipeline.undoLocalDeletion(wrong))
        XCTAssertEqual(try Data(contentsOf: f.file.url), before)
        _ = try f.pipeline.redo()
        XCTAssertEqual(try f.file.load().tasks.first?.title, "Changed")
        _ = try f.pipeline.undo()
        XCTAssertNotNil(try f.pipeline.undoLocalDeletion(f.token), "Rejection did not consume the deletion")
    }

    func testWriterBetweenPreflightAndUndoCannotBeUndoneByDeletionToken() throws {
        let f = try Fixture()
        XCTAssertTrue(f.token.isValid(in: try f.file.load()))
        // A real separate CLI process records an agent change after the old UI preflight.
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/perch-cli")
        let process = Process()
        process.executableURL = cli
        process.arguments = ["add_tasks", "{\"titles\":[\"New agent task\"],\"literal\":true}"]
        var environment = ProcessInfo.processInfo.environment
        environment["PERCH_DATA"] = f.file.url.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: response, as: UTF8.self))
        let current = try f.file.load()
        XCTAssertGreaterThan(current.agentActions.sequence, 0)
        let agent = try XCTUnwrap(current.tasks.first { $0.title == "New agent task" })
        let bytes = try Data(contentsOf: f.file.url)
        XCTAssertNil(try f.pipeline.undoLocalDeletion(f.token))
        XCTAssertEqual(try Data(contentsOf: f.file.url), bytes, "No agent inverse or migration can run on rejection")
        XCTAssertFalse(f.pipeline.canRedo)
        XCTAssertEqual(try f.file.load().tasks.map(\.id), current.tasks.map(\.id))
        XCTAssertNil(try f.file.load().agentActions.changes.last?.undoneAt)
        // Ordinary Undo retains its existing agent-before-local ordering.
        _ = try f.pipeline.undo()
        XCTAssertFalse(try f.file.load().tasks.contains { $0.id == agent.id })
        XCTAssertFalse(try f.file.load().tasks.contains { $0.id == f.deleted.id })
        _ = try f.pipeline.undo()
        XCTAssertTrue(try f.file.load().tasks.contains { $0.id == f.deleted.id })
        _ = try f.pipeline.redo()
        XCTAssertFalse(try f.file.load().tasks.contains { $0.id == f.deleted.id })
    }

    func testDeterministicWriterInFormerPreflightToHistoryGap() throws {
        var onClockRead: (() -> Void)?
        let clock = ClosurePlannerClock {
            let action = onClockRead
            onClockRead = nil
            action?()
            return FixtureTime.now
        }
        let f = try Fixture(clock: clock)
        XCTAssertTrue(f.token.isValid(in: try f.file.load()))
        var writerError: Error?
        var bytesAfterWrite: Data?
        // Generic Undo asks its clock after the UI's separate persisted check.
        // Arm that exact gap; the guarded path instead checks under its later lock.
        onClockRead = {
            do {
                let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent(".build/debug/perch-cli")
                let process = Process(), output = Pipe()
                process.executableURL = cli
                process.arguments = ["add", "Gap writer task"]
                var environment = ProcessInfo.processInfo.environment
                environment["PERCH_DATA"] = f.file.url.path
                process.environment = environment
                process.standardOutput = output; process.standardError = output
                try process.run()
                let response = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, String(decoding: response, as: UTF8.self))
                bytesAfterWrite = try Data(contentsOf: f.file.url)
            } catch { writerError = error }
        }
        XCTAssertNil(try f.pipeline.undoLocalDeletion(f.token))
        XCTAssertNil(writerError)
        XCTAssertNotNil(bytesAfterWrite)
        XCTAssertEqual(try Data(contentsOf: f.file.url), bytesAfterWrite)
        let current = try f.file.load()
        XCTAssertEqual(Set(current.tasks.map(\.title)), ["Kept task", "Gap writer task"])
        XCTAssertNil(current.agentActions.changes.last?.undoneAt)
        XCTAssertFalse(f.pipeline.canRedo)
        _ = try f.pipeline.undo()
        _ = try f.pipeline.undo()
        XCTAssertTrue(try f.file.load().tasks.contains { $0.id == f.deleted.id })
    }

    func testWriterContendingDuringValidationRunsAfterDeletionRestoration() throws {
        final class Probe: @unchecked Sendable {
            var file: URL?
            var cli: URL?
            var process: Process?
            var output: Pipe?
            var handshake: Data?
            func decoded() {
                guard let file, let cli, process == nil else { return }
                let process = Process(), output = Pipe()
                self.process = process; self.output = output
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [
                    "python3", "-c",
                    """
                    import fcntl, os, sys
                    with open(sys.argv[1] + '.lock', 'a') as lock:
                        try:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            sys.stdout.write('B'); sys.stdout.flush()
                            fcntl.flock(lock, fcntl.LOCK_EX)
                        else:
                            sys.stdout.write('U'); sys.stdout.flush()
                    os.environ['PERCH_DATA'] = sys.argv[1]
                    os.execv(sys.argv[2], [sys.argv[2], 'add', 'Contending agent task'])
                    """,
                    file.path, cli.path,
                ]
                process.standardOutput = output; process.standardError = output
                do {
                    try process.run()
                    handshake = try output.fileHandleForReading.read(upToCount: 1)
                } catch { handshake = Data("E".utf8) }
            }
        }
        let probe = Probe()
        var io = PlannerFile.IO()
        io.didDecode = { probe.decoded() }
        let f = try Fixture(io: io)
        probe.file = f.file.url
        probe.cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/perch-cli")
        let restored = try XCTUnwrap(f.pipeline.undoLocalDeletion(f.token))
        XCTAssertEqual(probe.handshake, Data("B".utf8), "The real writer must find the validation lock held")
        let process = try XCTUnwrap(probe.process)
        let response = try XCTUnwrap(probe.output).fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: response, as: UTF8.self))
        XCTAssertEqual(Set(restored.tasks.map(\.id)), [f.deleted.id, f.kept.id])
        let current = try f.file.load()
        XCTAssertEqual(Set(current.tasks.map(\.title)), ["Call the bank", "Kept task", "Contending agent task"])
        XCTAssertNil(current.agentActions.changes.last?.undoneAt)
    }

    func testRejectedTokenDoesNotMigrateLegacyBytesOrConsumeHistory() throws {
        let f = try Fixture()
        // An export is version one; a successful transaction would migrate it.
        let legacy = try PlannerFile.encoder.encode(f.file.load())
        try legacy.write(to: f.file.url, options: .atomic)
        let wrong = PlannerDeletionUndoToken(after: try f.file.load(), taskIDs: [f.deleted.id, UUID()])
        XCTAssertNil(try f.pipeline.undoLocalDeletion(wrong))
        XCTAssertEqual(try Data(contentsOf: f.file.url), legacy)
        XCTAssertFalse(f.pipeline.canRedo)
        XCTAssertNotNil(try f.pipeline.undoLocalDeletion(f.token))
        XCTAssertEqual(try f.file.load().tasks.map(\.id), [f.deleted.id, f.kept.id])
        XCTAssertTrue(f.pipeline.canRedo)
    }

    func testFailedSaveLeavesDeletionAndBothStacksRetryable() throws {
        final class Failure: @unchecked Sendable { var enabled = false }
        let failure = Failure()
        var io = PlannerFile.IO()
        io.write = { data, url in
            if failure.enabled && url.lastPathComponent == "planner.json" { throw PlannerError("Synthetic failure.") }
            try data.write(to: url, options: .atomic)
        }
        let f = try Fixture(io: io)
        let bytes = try Data(contentsOf: f.file.url)
        failure.enabled = true
        XCTAssertThrowsError(try f.pipeline.undoLocalDeletion(f.token))
        XCTAssertEqual(try Data(contentsOf: f.file.url), bytes)
        XCTAssertFalse(f.pipeline.canRedo)
        failure.enabled = false
        XCTAssertNotNil(try f.pipeline.undoLocalDeletion(f.token))
        _ = try f.pipeline.redo()
        XCTAssertEqual(try f.file.load().tasks.map(\.id), [f.kept.id])
    }
}
