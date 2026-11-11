import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class NotchBehaviorTests: XCTestCase {
    @MainActor
    func testFailedReminderActionStaysVisibleAndSuccessfulRetryDismisses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let model = NotchModel()
        let task = try XCTUnwrap(store.apply { try $0.addTasks(["Synthetic reminder"], on: .day($0.today)) }?.first)
        let activity = PresentedNotchActivity(kind: .reminder(task.id), title: task.title, subtitle: "Due now")
        model.show(activity)
        XCTAssertFalse(model.performActivityAction(in: store) { try $0.complete(UUID()) })
        XCTAssertEqual(model.activity?.id, activity.id)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(model.performActivityAction(in: store) { try $0.complete(task.id) })
        XCTAssertNil(model.activity)
        XCTAssertTrue(try store.file.load().tasks.first { $0.id == task.id }?.done == true)
    }

    @MainActor
    func testKeyboardOpenIsPinnedAndCloseClearsFocusBeforeReopen() async {
        for reduced in [false, true] {
            let model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: reduced))
            model.open(pinned: true)
            XCTAssertTrue(model.expanded)
            XCTAssertTrue(model.pinned)
            model.captureFocusRequest = UUID()
            model.close()
            XCTAssertFalse(model.expanded)
            XCTAssertFalse(model.pinned)
            XCTAssertNil(model.captureFocusRequest)
            model.open()
            XCTAssertTrue(model.expanded)
            XCTAssertFalse(model.pinned)
        }
    }

    @MainActor
    func testTimerInkFitsAtOneAndTwoTimesScaleWhenPausedAndRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let screen = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664)
        for scale in [CGFloat(1), 2] {
            let geometry = NotchGeometry(screen: screen, backingScaleFactor: scale)
            for side in [NotchTimerPlacement.left, .right] {
                let pill = geometry.pill(side: side)
                for seconds in [TimeInterval(754), 7199, 359999, 360000, 3_600_000_000] {
                    for running in [false, true] {
                        let now = Date()
                        var focus = FocusSession(taskID: nil, limit: nil, now: now)
                        focus.banked = seconds
                        if !running { focus.state = .paused; focus.resumedAt = nil }
                        try store.file.mutate { $0.focus = focus }
                        store.reloadFromDisk(external: false)
                        XCTAssertEqual(store.planner.focus?.state, running ? .running : .paused)
                        let view = TimerPillLayer(
                            geometry: geometry, side: side, bounds: pill, focus: store.planner.focus
                        )
                        .frame(width: pill.width, height: pill.height)
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = scale
                        let image = try XCTUnwrap(renderer.cgImage)
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        var ink: [CGPoint] = []
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                                    continue
                                }
                                if color.alphaComponent > 0.5 && color.redComponent > 0.45 {
                                    ink.append(CGPoint(x: x, y: y))
                                }
                            }
                        }
                        XCTAssertGreaterThan(ink.count, 20, "The timer face must actually render")
                        XCTAssertTrue(
                            ink.allSatisfy {
                                $0.x >= 6 * scale && $0.x < (pill.width - 6) * scale
                                    && $0.y >= 2 * scale && $0.y < (pill.height - 2) * scale
                            }, "Timer ink must stay inset from every capsule edge")
                    }
                }
            }
        }
    }
}
