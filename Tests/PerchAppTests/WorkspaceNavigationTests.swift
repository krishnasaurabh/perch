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
        XCTAssertTrue(result.contains("960pt and 1280pt"))
    }

    func testNativeFocusDeadlineStillRejectsUnfocusedWeek() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Inject a failed AX read only in this disposable package. The normal
        // probe and its scenarios remain unchanged; no runtime bypass flag exists.
        for name in ["Package.swift", "Sources", "Tests"] {
            try FileManager.default.copyItem(
                at: root.appendingPathComponent(name), to: temporary.appendingPathComponent(name))
        }
        let scripts = temporary.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let runner = scripts.appendingPathComponent("check_workspace_navigation.sh")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("scripts/check_workspace_navigation.sh"), to: runner)
        let probe = temporary.appendingPathComponent("Tests/PerchAppTests/WorkspaceBandProbe.swift")
        let source = try String(contentsOf: probe, encoding: .utf8)
        let original = "    func bool(_ node: NSObject, _ name: String) throws -> Bool {"
        XCTAssertEqual(source.components(separatedBy: original).count, 2, "Failure trigger must match exactly once")
        let trigger =
            original + """

                    if name == "isAccessibilityFocused",
                        attribute(node, "accessibilityIdentifier") as? String == "workspace-page-week"
                    { return false }
                """
        try source.replacingOccurrences(of: original, with: trigger).write(to: probe, atomically: true, encoding: .utf8)
        let log = temporary.appendingPathComponent("failure-control.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runner.path, temporary.appendingPathComponent("diagnostics").path]
        process.currentDirectoryURL = temporary
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let result = try String(contentsOf: log, encoding: .utf8)
        FileHandle.standardError.write(Data(result.utf8))
        XCTAssertEqual(process.terminationReason, .exit, "Deadline control must exit normally")
        XCTAssertEqual(process.terminationStatus, 1, "Unfocused week must remain a hard failure")
        XCTAssertTrue(
            result.contains("FAIL: workspace navigation: assertion(\"Native focus must be workspace-page-week\""))
        let diagnostic = try XCTUnwrap(
            result.components(separatedBy: "\n").first {
                $0.hasPrefix("Workspace focus failure target=workspace-page-week ")
            })
        for field in [
            "appActive=true", "appBecameActive=true", "anyNodeFocused=", "focusedIdentifiers=",
            "deadline=3.0s", "pid=", "windowNumber=", "key=true",
        ] {
            XCTAssertTrue(diagnostic.contains(field), "Missing timeout diagnostic: \(field)")
        }
        let elapsedText = try XCTUnwrap(diagnostic.components(separatedBy: "elapsed=").dropFirst().first)
        let elapsed = try XCTUnwrap(Double(elapsedText.prefix { $0 != "s" }))
        XCTAssertGreaterThanOrEqual(elapsed, 3, "The deadline must expire before failing native focus")
        XCTAssertFalse(result.contains("PASS: workspace keyboard, selection, targets, layout and focus rings"))
    }
}
