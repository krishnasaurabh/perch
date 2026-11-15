import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class NotchBehaviorTests: XCTestCase {
    @MainActor
    func testPeekPaintedHousingIncludesScreenTopAndExcludesCorners() async throws {
        let geometry = NotchGeometry(
            screen: NotchLayout.Screen(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 948),
                safeAreaTop: 34, auxiliaryLeftWidth: 661, auxiliaryRightWidth: 661))
        let rect = NotchPeekLayout.frame(workspace: geometry.workspace, bandHeight: geometry.notchSize.height)
        let local = try XCTUnwrap(NotchPeekLayout.localPoint(CGPoint(x: rect.midX, y: rect.maxY), in: rect))
        let path = geometry.outline(expanded: true).path(in: CGRect(origin: .zero, size: rect.size))
        XCTAssertTrue(path.contains(local))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: rect.height - 1)))
    }

    @MainActor
    func testPeekPromotesToWorkspaceAndCloseClearsItsLevel() async {
        let model = NotchModel()
        model.openPeek()
        XCTAssertTrue(model.expanded)
        XCTAssertTrue(model.peeking)
        XCTAssertFalse(model.pinned)
        model.open(pinned: true)
        XCTAssertFalse(model.peeking)
        XCTAssertTrue(model.pinned)
        model.openPeek()
        XCTAssertFalse(model.peeking, "Hover must not downgrade an explicit workspace")
        model.close()
        XCTAssertFalse(model.expanded)
        XCTAssertFalse(model.peeking)
    }

    @MainActor
    func testPeekCaptureAndBlockActionsPersistAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let model = NotchModel()
        XCTAssertTrue(model.submitPeek("A task", in: store))
        let task = try XCTUnwrap(store.planner.tasks.first)
        XCTAssertEqual(task.day, store.today)
        XCTAssertTrue(model.submitPeek("/ A thought", in: store))
        XCTAssertTrue(model.submitPeek("Another thought", park: true, in: store))
        XCTAssertFalse(model.submitPeek(" / ", in: store))
        XCTAssertEqual(try store.file.load().parkedThoughts.map(\.text), ["A thought", "Another thought"])
        store.undo()
        XCTAssertEqual(try store.file.load().parkedThoughts.map(\.text), ["A thought"])
        model.togglePeekBlock(in: store)
        XCTAssertEqual(try store.file.load().focus?.taskID, task.id)
        model.togglePeekBlock(in: store)
        XCTAssertEqual(try store.file.load().focus?.state, .paused)
        model.togglePeekBlock(in: store)
        XCTAssertEqual(try store.file.load().focus?.state, .running)
    }

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
                        XCTAssertEqual(focus.state, running ? .running : .paused)
                        let view = TimerPillLayer(
                            geometry: geometry, side: side, bounds: pill, focus: focus
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
