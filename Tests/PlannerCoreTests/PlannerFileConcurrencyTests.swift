import PlannerTestSupport
import XCTest
@testable import PlannerCore

/// Cross-process and in-process contention on planner.json. Every read-modify-write
/// takes an advisory lock, so no update may be lost when 50 perch-cli processes race.
final class PlannerFileConcurrencyTests: XCTestCase {
    private let fixtureCalendar = Fixture.calendar

    // MARK: Helpers

    private func tempPlanner() -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-concurrency-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("planner.json"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlannerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    private func perchCLI() throws -> URL {
        let fm = FileManager.default
        let root = packageRoot()
        for config in ["debug", "release"] {
            let candidate = root.appendingPathComponent(".build/\(config)/perch-cli")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // `swift test` does not always build executable products; build once up front.
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--product", "perch-cli"]
        build.currentDirectoryURL = root
        let err = Pipe()
        build.standardError = err
        build.standardOutput = Pipe()
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PlannerError("could not build perch-cli: \(message)")
        }
        for config in ["debug", "release"] {
            let candidate = root.appendingPathComponent(".build/\(config)/perch-cli")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw PlannerError("perch-cli was built but not found under .build")
    }

    private func seed(_ file: PlannerFile, titles: [String]) throws {
        try file.mutate { p in
            var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: self.fixtureCalendar)
            _ = try e.addTasks(titles, literal: true)
            p = e.planner
        }
    }

    // MARK: Cross-process

    func testFiftyParallelCLIProcessesDoNotLoseWrites() throws {
        let (_, url) = tempPlanner()
        let cli = try perchCLI()
        let count = 50
        let lock = NSLock()
        var failures: [String] = []
        let group = DispatchGroup()

        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = cli
                process.arguments = ["add", "parallel task \(i)"]
                var env = ProcessInfo.processInfo.environment
                env["PERCH_DATA"] = url.path
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    process.waitUntilExit()
                    let outText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if process.terminationStatus != 0 || !errText.isEmpty || !outText.contains("Added 1 task") {
                        lock.lock()
                        failures.append("task \(i): status \(process.terminationStatus) out=\(outText) err=\(errText)")
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failures.append("task \(i): \(error)")
                    lock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 300), .success, "50 processes did not finish")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))

        let planner = try PlannerFile(url: url).load()
        XCTAssertEqual(planner.tasks.count, count, "lost writes")
        let titles = Set(planner.tasks.map(\.title))
        XCTAssertEqual(titles.count, count, "duplicated writes")
        for i in 0..<count {
            XCTAssertTrue(titles.contains("parallel task \(i)"), "missing parallel task \(i)")
        }
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("lock").path))
    }

    // MARK: In-process

    func testHundredConcurrentInProcessMutatesKeepEveryTask() throws {
        let (_, url) = tempPlanner()
        let file = PlannerFile(url: url)
        let count = 100
        let lock = NSLock()
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: count) { i in
            do {
                try file.mutate { p in
                    var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: self.fixtureCalendar)
                    _ = try e.addTasks(["in process \(i)"], literal: true)
                    p = e.planner
                }
            } catch {
                lock.lock()
                failures.append("mutate \(i): \(error)")
                lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let planner = try file.load()
        XCTAssertEqual(planner.tasks.count, count)
        XCTAssertEqual(Set(planner.tasks.map(\.title)).count, count)
    }

    func testReadersDoNotSeeAPartialFileWhileWritersRun() throws {
        let (_, url) = tempPlanner()
        let file = PlannerFile(url: url)
        try seed(file, titles: ["seed"])
        let writers = 25
        let lock = NSLock()
        var failures: [String] = []
        let group = DispatchGroup()

        for i in 0..<writers {
            group.enter()
            DispatchQueue.global().async {
                do {
                    try file.mutate { p in
                        var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: self.fixtureCalendar)
                        _ = try e.addTasks(["writer \(i)"], literal: true)
                        p = e.planner
                    }
                } catch {
                    lock.lock(); failures.append("writer \(i): \(error)"); lock.unlock()
                }
                group.leave()
            }
        }
        for _ in 0..<25 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<10 {
                    do { _ = try file.load() } catch {
                        lock.lock(); failures.append("reader: \(error)"); lock.unlock()
                    }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertTrue(failures.isEmpty, String(failures.joined(separator: "\n").prefix(2_000)))
        XCTAssertEqual(try file.load().tasks.count, 1 + writers)
    }

    func testThrowingBodyLeavesTheFileUntouched() throws {
        let (_, url) = tempPlanner()
        let file = PlannerFile(url: url)
        try seed(file, titles: ["keep me"])
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(
            try file.mutate { p in
                p.tasks.removeAll()
                throw PlannerError("nope")
            })
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try file.load().tasks.map(\.title), ["keep me"])
    }

    func testAtomicSaveLeavesNoStrayFilesAndExportsValidJSON() throws {
        let (dir, url) = tempPlanner()
        let file = PlannerFile(url: url)
        try seed(file, titles: ["a", "b"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["planner.json", "planner.json.lock"])

        let exported = dir.appendingPathComponent("export.json")
        try file.export(to: exported)
        let data = try Data(contentsOf: exported)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        let decoded = try PlannerFile.decoder.decode(Planner.self, from: data)
        XCTAssertEqual(decoded.tasks.count, 2)
    }

    func testConcurrentCompletionsOfDistinctTasksAreAllPersisted() throws {
        // Two processes' worth of interleaved writers, each touching one task, must
        // not clobber the other's completion flag.
        let (_, url) = tempPlanner()
        let file = PlannerFile(url: url)
        try seed(file, titles: (0..<20).map { "job \($0)" })
        let planner = try file.load()
        let ids = planner.tasks.map(\.id)
        let lock = NSLock()
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            do {
                try file.mutate { p in
                    var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: self.fixtureCalendar)
                    _ = try e.complete(ids[i].uuidString)
                    p = e.planner
                }
            } catch {
                lock.lock(); failures.append("complete \(i): \(error)"); lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let after = try file.load()
        XCTAssertEqual(after.tasks.filter(\.done).count, ids.count)
    }
}
