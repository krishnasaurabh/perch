import Foundation
import XCTest

/// Launch the real workspace in a separate unbundled process. Apple's XCTest
/// tool has a bundle identifier but is not an application notification host.
final class WorkspaceNavigationTests: XCTestCase {
    func testProductionWorkspaceNavigationProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let diagnostics =
            ProcessInfo.processInfo.environment["RUNNER_TEMP"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("native-diagnostics/workspace-navigation")
            } ?? temporary.appendingPathComponent("diagnostics")
        let log = temporary.appendingPathComponent("probe.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            root.appendingPathComponent("scripts/check_workspace_navigation.sh").path, diagnostics.path,
        ]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let result = try String(contentsOf: log, encoding: .utf8)
        FileHandle.standardError.write(Data(result.utf8))
        XCTAssertEqual(process.terminationReason, .exit, "Native workspace probe must exit normally")
        XCTAssertEqual(process.terminationStatus, 0, "Native workspace probe failed:\n\(result)")
        XCTAssertTrue(result.contains("PASS: workspace keyboard, selection, targets, layout and focus rings"))
        XCTAssertTrue(result.contains("PASS: workspace passive presentation and page activation"))
    }
}
