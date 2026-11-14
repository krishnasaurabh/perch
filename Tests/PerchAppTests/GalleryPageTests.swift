import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

#if DEBUG || PERCH_TESTING
    final class GalleryPageTests: XCTestCase {
        @MainActor func testScenarioSelectionAndSheetSizes() throws {
            XCTAssertNoThrow(try AppDelegate.previewTarget("gallery"))
            XCTAssertEqual(GalleryPage.Page.forScenario(nil), .system)
            XCTAssertEqual(GalleryPage.Page.forScenario("empty"), .system)
            XCTAssertEqual(GalleryPage.Page.forScenario("timer"), .motion)
            XCTAssertEqual(GalleryPage.Page.system.size, CGSize(width: 960, height: 640))
            XCTAssertEqual(GalleryPage.Page.motion.size, CGSize(width: 1100, height: 780))
        }

        func testTimeActionsAreDeterministicAndNeverStartAClock() {
            var demo = GalleryDemo()
            XCTAssertFalse(demo.running)
            XCTAssertEqual(demo.timeText, "24:10")
            XCTAssertEqual(demo.progress, 1450.0 / 2700, accuracy: 0.0001)
            demo.addTime()
            XCTAssertEqual(demo.timeText, "29:10")
            XCTAssertFalse(demo.running)
            demo.resetTime()
            XCTAssertEqual(demo.timeText, "24:10")
            demo.running.toggle()
            XCTAssertTrue(demo.running)
            XCTAssertEqual(demo.timeText, "24:10")
        }

        func testChecklistCountsAndTaskToggleStayConsistent() {
            var demo = GalleryDemo()
            XCTAssertEqual(demo.doneCount, 2)
            demo.setStep(2, done: true)
            XCTAssertEqual(demo.doneCount, 3)
            XCTAssertFalse(demo.taskDone)
            demo.setStep(3, done: true)
            XCTAssertEqual(demo.doneCount, 4)
            XCTAssertTrue(demo.taskDone)
            demo.setStep(0, done: false)
            XCTAssertFalse(demo.taskDone)
            demo.setTask(true)
            XCTAssertEqual(demo.doneCount, 4)
            demo.setTask(false)
            XCTAssertEqual(demo.doneCount, 0)
            let original = demo
            demo.setStep(-1, done: true)
            demo.setStep(4, done: true)
            XCTAssertEqual(demo, original)
        }

        func testMinuteChoicesAndBoundedProgress() {
            var demo = GalleryDemo()
            for minutes in [15, 25, 45, 60] {
                demo.selectMinutes(minutes)
                XCTAssertEqual(demo.minutes, minutes)
                XCTAssertEqual(demo.seconds, minutes * 60)
                XCTAssertEqual(demo.progress, 1)
                demo.addTime()
                XCTAssertEqual(demo.progress, 1)
            }
            let original = demo
            demo.selectMinutes(0)
            demo.selectMinutes(20)
            XCTAssertEqual(demo, original)
        }

        @MainActor func testBothPagesLayOutAtTheirDeclaredSizeInBothAppearances() throws {
            _ = NSApplication.shared
            for page in [GalleryPage.Page.system, .motion] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = NSHostingView(
                        rootView: GalleryPage(page: page)
                            .environment(\.colorScheme, scheme)
                            .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
                    view.frame = NSRect(origin: .zero, size: page.size)
                    view.layoutSubtreeIfNeeded()
                    let shot = try AppDelegate.previewPNG(view: view, rect: view.bounds)
                    XCTAssertEqual(shot.width, Int(page.size.width))
                    XCTAssertEqual(shot.height, Int(page.size.height))
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.data))
                    XCTAssertEqual(bitmap.pixelsWide, Int(page.size.width * 2))
                    XCTAssertEqual(bitmap.pixelsHigh, Int(page.size.height * 2))
                }
            }
        }
    }
#endif
