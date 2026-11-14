import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class NotchClosedAppTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func geometry(hardware: Bool, builtIn: Bool = false) -> NotchGeometry {
        NotchGeometry(
            screen: .init(
                frame: CGRect(x: -960, y: 0, width: 960, height: 600),
                visibleFrame: CGRect(x: -960, y: 0, width: 960, height: 566),
                safeAreaTop: hardware ? 34 : 0,
                auxiliaryLeftWidth: hardware ? 385 : nil,
                auxiliaryRightWidth: hardware ? 385 : nil, isBuiltIn: builtIn))
    }

    func testRunningAndPausedPointerRoutingMatchThePaintedLine() {
        let g = geometry(hardware: true)
        var planner = Planner()
        planner.focus = FocusSession(taskID: nil, limit: 600, now: now)
        let running = NotchClosedPresentation(planner: planner)
        let line = g.progressLine
        let center = CGPoint(x: line.midX, y: line.midY)
        XCTAssertTrue(g.shapeContains(center, expanded: false, timer: nil, activity: false, closed: running))
        XCTAssertTrue(g.hover(expanded: false, timer: nil, activity: false, closed: running).contains(center))
        XCTAssertFalse(
            g.shapeContains(
                CGPoint(x: line.minX - 1, y: line.midY), expanded: false, timer: nil, activity: false, closed: running))
        planner.focus?.state = .paused
        planner.focus?.resumedAt = nil
        let paused = NotchClosedPresentation(planner: planner)
        let dashes = NotchLayout.pausedDashes(line: line)
        XCTAssertGreaterThan(dashes.count, 1)
        for dash in dashes {
            XCTAssertTrue(
                g.shapeContains(
                    CGPoint(x: dash.midX, y: dash.midY), expanded: false, timer: nil, activity: false, closed: paused))
        }
        XCTAssertFalse(
            g.shapeContains(
                CGPoint(x: (dashes[0].maxX + dashes[1].minX) / 2, y: line.midY),
                expanded: false, timer: nil, activity: false, closed: paused))
        let idle = NotchClosedPresentation(planner: Planner())
        XCTAssertFalse(g.shapeContains(center, expanded: false, timer: nil, activity: false, closed: idle))
    }

    func testReminderCircleAndFlatTabDoNotCaptureTransparentCornersOrMenuBar() {
        let state = NotchClosedPresentation(planner: Planner(), reminderWaiting: true)
        let g = geometry(hardware: true)
        let dot = g.reminderDot(progressVisible: false)
        XCTAssertTrue(
            g.shapeContains(
                CGPoint(x: dot.midX, y: dot.midY), expanded: false, timer: nil, activity: false, closed: state))
        XCTAssertFalse(
            g.shapeContains(
                CGPoint(x: dot.minX + 0.1, y: dot.maxY - 0.1), expanded: false, timer: nil, activity: false,
                closed: state))
        for builtIn in [true, false] {
            let flat = geometry(hardware: false, builtIn: builtIn)
            let tab = flat.closedTab
            XCTAssertEqual(tab.maxY, flat.screen.visibleFrame.maxY)
            XCTAssertTrue(
                flat.shapeContains(
                    CGPoint(x: tab.midX, y: tab.midY), expanded: false, timer: nil, activity: false, closed: state))
            XCTAssertFalse(
                flat.shapeContains(
                    CGPoint(x: tab.midX, y: flat.screenFrame.maxY - 1),
                    expanded: false, timer: nil, activity: false, closed: state))
            XCTAssertFalse(
                flat.shapeContains(
                    CGPoint(x: tab.minX + 0.1, y: tab.minY + 0.1),
                    expanded: false, timer: nil, activity: false, closed: state))
            XCTAssertEqual(flat.hover(expanded: false, timer: nil, activity: false, closed: state), tab)
            let idle = NotchClosedPresentation(planner: Planner())
            XCTAssertEqual(flat.hover(expanded: false, timer: nil, activity: false, closed: idle), .zero)
            XCTAssertFalse(
                flat.shapeContains(
                    CGPoint(x: tab.midX, y: tab.midY), expanded: false, timer: nil, activity: false, closed: idle))
        }
    }

    @MainActor
    func testReminderDotSurvivesTransientExpiryAndClearsAfterAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let creationTime = now.addingTimeInterval(-120)
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            now: { creationTime }, watching: false)
        let task = try XCTUnwrap(
            store.apply {
                try $0.addTasks(["Synthetic reminder"], on: .day($0.today))
            }?.first)
        store.updateTask(task.id) { $0.remindAt = self.now.addingTimeInterval(-60) }
        XCTAssertNil(store.lastError)
        let model = NotchModel()
        model.screenID = 9
        let activity = PresentedNotchActivity(kind: .reminder(task.id), title: task.title, subtitle: "")
        XCTAssertFalse(model.closed(in: store, screenID: 9, now: now).reminder, "A past date alone is not waiting")
        model.show(activity)
        model.dismissActivity()
        XCTAssertTrue(model.closed(in: store, screenID: 9, now: now).reminder)
        XCTAssertFalse(model.closed(in: store, screenID: 10, now: now).reminder)
        store.updatePrefs { $0.notchReminderDot = false }
        XCTAssertFalse(model.closed(in: store, screenID: 9, now: now).reminder)
        store.updatePrefs { $0.notchReminderDot = true }
        model.show(activity)
        model.dismissPresentedActivity(in: store.planner)
        XCTAssertFalse(model.closed(in: store, screenID: 9, now: now).reminder)
        model.show(activity)
        let completed = try XCTUnwrap(store.apply { try $0.complete(task.id) })
        XCTAssertNil(store.lastError)
        XCTAssertTrue(completed.done)
        XCTAssertFalse(model.closed(in: store, screenID: 9, now: now).reminder)
    }

    @MainActor
    func testAnsweringNewerReminderDoesNotEraseAnOlderWaitingAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let creationTime = now.addingTimeInterval(-120)
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            now: { creationTime }, watching: false)
        let tasks = try XCTUnwrap(
            store.apply {
                try $0.addTasks(["First reminder", "Second reminder"], on: .day($0.today))
            })
        XCTAssertEqual(tasks.count, 2)
        for task in tasks { store.updateTask(task.id) { $0.remindAt = self.now.addingTimeInterval(-60) } }
        XCTAssertNil(store.lastError)
        let model = NotchModel()
        for task in tasks {
            model.show(.init(kind: .reminder(task.id), title: task.title, subtitle: ""))
            model.dismissActivity()
        }
        model.show(.init(kind: .reminder(tasks[1].id), title: tasks[1].title, subtitle: ""))
        model.dismissPresentedActivity(in: store.planner)
        XCTAssertTrue(model.closed(in: store, screenID: model.screenID, now: now).reminder)
        model.show(.init(kind: .reminder(tasks[0].id), title: tasks[0].title, subtitle: ""))
        model.dismissPresentedActivity(in: store.planner)
        XCTAssertFalse(model.closed(in: store, screenID: model.screenID, now: now).reminder)
    }

    @MainActor
    func testIdleLayerPaintsNothingAndRunningLayerPaintsExactlyThreePointStrip() async throws {
        let g = geometry(hardware: true)
        let bounds = CGRect(x: g.notchRect.minX, y: g.notchRect.minY - 20, width: g.notchRect.width, height: 20)
        for scale in [CGFloat(1), 2] {
            var planner = Planner()
            for running in [false, true] {
                if running { planner.focus = FocusSession(taskID: nil, limit: 600, now: now) }
                let renderer = ImageRenderer(
                    content: NotchClosedLayer(
                        geometry: g, bounds: bounds, presentation: NotchClosedPresentation(planner: planner), now: now,
                        open: {}))
                renderer.scale = scale
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                var painted = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                        painted += 1
                        XCTAssertTrue(running)
                        XCTAssertLessThan(CGFloat(y), NotchClosedTokens.lineHeight * scale)
                        XCTAssertGreaterThanOrEqual(CGFloat(x), NotchClosedTokens.lineInset * scale)
                        XCTAssertLessThan(CGFloat(x), (bounds.width - NotchClosedTokens.lineInset) * scale)
                    }
                }
                XCTAssertEqual(painted, running ? Int(g.progressLine.width * 3 * scale * scale) : 0)
            }
        }
    }
}
