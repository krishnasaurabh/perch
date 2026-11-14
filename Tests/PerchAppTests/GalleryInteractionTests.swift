import Foundation
import XCTest

#if DEBUG || PERCH_TESTING
    /// Run the full gallery in a native application's event loop, not XCTest's host.
    final class GalleryInteractionTests: XCTestCase {
        func testActionsChangeTheVisibleGalleryWithoutAPlanner() throws {
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for item in ["Package.swift", "Sources", "Tests"] {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(item), to: temporary.appendingPathComponent(item))
            }
            let probe = source.deletingLastPathComponent().appendingPathComponent("GalleryNativeProbe.swift")
            let main = temporary.appendingPathComponent("Sources/Perch/main.swift")
            let program = try String(contentsOf: probe, encoding: .utf8) + "\nGalleryNativeProbe.run()\n"
            try program.write(to: main, atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("gallery.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import os, pathlib, subprocess, sys
                package = sys.argv[1]
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', package,
                    '-Xswiftc', '-DGALLERY_NATIVE_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', package,
                ], text=True, timeout=30).strip()
                environment = dict(os.environ, PERCH_DATA=str(pathlib.Path(package) / 'data'))
                subprocess.run([
                    str(pathlib.Path(bin_path) / 'Perch'),
                ], env=environment, check=True, timeout=60)
                """#, temporary.path,
            ]
            process.currentDirectoryURL = temporary
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let result = try String(contentsOf: log, encoding: .utf8)
            FileHandle.standardError.write(Data(result.utf8))
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0, "Native gallery check failed:\n\(result)")
            XCTAssertTrue(result.contains("PASS: Gallery native actions and visible state"))
        }
    }
#endif
