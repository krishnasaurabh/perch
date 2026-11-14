import AppKit
import XCTest

@testable import PerchApp
@testable import PlannerCore

#if DEBUG || PERCH_TESTING
    final class RedesignPreviewTests: XCTestCase {
        func testUnknownTargetsFailRatherThanOpeningToday() async throws {
            try await MainActor.run {
                for name in ["today", "week", "settings", "your-week", "history", "projects"] {
                    XCTAssertNoThrow(try AppDelegate.previewTarget(name))
                }
                XCTAssertThrowsError(try AppDelegate.previewTarget("typo")) { error in
                    XCTAssertTrue(String(describing: error).contains("typo"))
                }
            }
        }

        func testFixtureReplacementDoesNotKeepThePreviousDayOrTimer() async throws {
            try await MainActor.run {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = PlannerFile(
                    url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
                let store = PlannerStore(file: file, now: { PlannerPreviewScenarios.referenceDate }, watching: false)
                store.beginApplication()
                for name in ["week-full", "today-empty", "today-running", "today-before"] {
                    let fixture = try PlannerPreviewScenarios.install(name, in: file)
                    store.reloadFromDisk(external: false)
                    XCTAssertEqual(store.planner, fixture.planner, name)
                }
            }
        }

        func testSnapshotIsActuallyTwoPixelsPerPoint() async throws {
            try await MainActor.run {
                _ = NSApplication.shared
                let rect = NSRect(x: 0, y: 0, width: 32, height: 24)
                let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let view = PaintedPreviewView(frame: rect)
                window.contentView = view
                let shot = try AppDelegate.previewPNG(view: view, rect: view.bounds)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.data))
                XCTAssertEqual(shot.width, 32)
                XCTAssertEqual(shot.height, 24)
                XCTAssertEqual(bitmap.pixelsWide, 64)
                XCTAssertEqual(bitmap.pixelsHigh, 48)
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 32, y: 24)).alphaComponent, 0.9)
                XCTAssertThrowsError(try AppDelegate.previewPNG(view: view, rect: .zero))
                XCTAssertThrowsError(try AppDelegate.previewPNG(view: view, rect: rect.offsetBy(dx: 20, dy: 0)))
            }
        }
    }

    @MainActor
    private final class PaintedPreviewView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }
#endif
