import XCTest
@testable import PlannerCore

final class AppLaunchConfigurationTests: XCTestCase {
    func testProductionLaunchModes() throws {
        for args in [[], ["--mcp"], ["-NSDocumentRevisionsDebugMode", "YES"]] {
            XCTAssertNoThrow(try AppLaunchConfiguration.validate(arguments: args, environment: [:]))
        }
        XCTAssertThrowsError(try AppLaunchConfiguration.validate(arguments: ["--unknown"], environment: [:]))
        XCTAssertThrowsError(try AppLaunchConfiguration.validate(arguments: ["--mcp", "--mcp"], environment: [:]))
    }

    #if DEBUG || PERCH_TESTING
        func testDiagnosticsRequireExplicitIsolatedStorage() throws {
            for args in [["--demo"], ["--demo-clips"], ["--snapshot", "/fixture/out"], ["--scenario", "three"]] {
                XCTAssertThrowsError(try AppLaunchConfiguration.validate(arguments: args, environment: [:]))
                XCTAssertThrowsError(
                    try AppLaunchConfiguration.validate(arguments: args, environment: ["PERCH_DATA": "relative"]))
                XCTAssertNoThrow(
                    try AppLaunchConfiguration.validate(
                        arguments: args, environment: ["PERCH_DATA": "/fixture/planner.json"]))
            }
        }

        func testDiagnosticValuesAndCombinationsAreValidated() {
            let env = ["PERCH_DATA": "/fixture/planner.json"]
            for args in [
                ["--scenario"], ["--scenario", ""], ["--scenario", "typo"],
                ["--page", "home"], ["--preview-open", "--page", "typo"],
                ["--motion-policy", "normal"], ["--motion-script", "x", "--motion-policy", "typo"],
                ["--demo", "--mcp"], ["--demo", "--scenario", "three"],
            ] {
                XCTAssertThrowsError(try AppLaunchConfiguration.validate(arguments: args, environment: env), "\(args)")
            }
            XCTAssertNoThrow(
                try AppLaunchConfiguration.validate(arguments: ["--preview-open", "--page", "week"], environment: env))
            for policy in ["production", "normal", "reduced"] {
                XCTAssertNoThrow(
                    try AppLaunchConfiguration.validate(
                        arguments: ["--motion-script", "x", "--motion-policy", policy], environment: env))
            }
        }

        func testDiagnosticEnvironmentNeedsIsolatedStorage() {
            for key in ["PERCH_SCREENSHOT_FOLDER", "PERCH_MOTION_MISSING_CONTROL", "PERCH_MOTION_AX_WAKE"] {
                XCTAssertThrowsError(try AppLaunchConfiguration.validate(arguments: [], environment: [key: "x"]))
                XCTAssertNoThrow(
                    try AppLaunchConfiguration.validate(
                        arguments: [], environment: [key: "x", "PERCH_DATA": "/fixture/p.json"]))
            }
        }
    #else
        func testReleaseRejectsDiagnosticsEvenWithIsolatedStorage() {
            for args in [["--demo"], ["--scenario", "three"], ["--motion-script", "out"], ["--snapshot", "out"]] {
                XCTAssertThrowsError(
                    try AppLaunchConfiguration.validate(
                        arguments: args,
                        environment: ["PERCH_DATA": "/fixture/planner.json"]))
            }
            XCTAssertNoThrow(
                try AppLaunchConfiguration.validate(
                    arguments: [],
                    environment: ["PERCH_MOTION_MISSING_CONTROL": "x", "PERCH_SCREENSHOT_FOLDER": "/fixture"]))
        }
    #endif
}
