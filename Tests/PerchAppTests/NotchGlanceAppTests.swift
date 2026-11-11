import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

private final class UnwritableGlancePreferences: PlannerPreferencesAdapter {
    func load() -> DevicePreferences? {
        var preferences = Preferences()
        preferences.notchTaskCount = true
        return DevicePreferences(preferences)
    }
    func save(_ preferences: DevicePreferences?) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

final class NotchGlanceAppTests: XCTestCase {
    func testCountDoesNotChangeHousingOrHoverTargetAndItsGapStaysClickThrough() {
        for hardware in [true, false] {
            for scale in [CGFloat(1), 2] {
                let screen = NotchLayout.Screen(
                    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    safeAreaTop: hardware ? 32 : 0,
                    auxiliaryLeftWidth: hardware ? 663 : nil,
                    auxiliaryRightWidth: hardware ? 664 : nil)
                let g = NotchGeometry(screen: screen, backingScaleFactor: scale)
                let capsule = g.glanceRect
                let center = CGPoint(x: capsule.midX, y: capsule.midY)
                let gap = CGPoint(x: (g.notchRect.maxX + capsule.minX) / 2, y: capsule.midY)
                XCTAssertEqual(g.idle(timer: nil, activity: false), g.tuckedNotch)
                XCTAssertEqual(
                    g.idle(timer: nil, activity: false, glance: true), g.tuckedNotch.union(capsule))
                XCTAssertTrue(g.window.contains(capsule))
                XCTAssertFalse(g.shapeContains(center, expanded: false, timer: nil, activity: false))
                XCTAssertTrue(g.shapeContains(center, expanded: false, timer: nil, activity: false, glance: true))
                XCTAssertFalse(g.shapeContains(gap, expanded: false, timer: nil, activity: false, glance: true))
                XCTAssertFalse(
                    g.shapeContains(
                        CGPoint(x: capsule.minX + 0.1, y: capsule.maxY - 0.1),
                        expanded: false, timer: nil, activity: false, glance: true))
                let hover = g.hover(expanded: false, timer: nil, activity: false)
                XCTAssertEqual(hover, g.notchRect)
                XCTAssertFalse(NotchLayout.contains(hover, pointer: center))
                XCTAssertFalse(NotchLayout.contains(hover, pointer: gap))
            }
        }
        let flatBuiltIn = NotchGeometry(
            screen: .init(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isBuiltIn: true))
        let capsule = flatBuiltIn.glanceRect
        XCTAssertFalse(
            flatBuiltIn.shapeContains(
                CGPoint(x: capsule.midX, y: capsule.midY), expanded: false,
                timer: nil, activity: false, glance: true))
    }

    func testShortExternalHousingStillHasReadablePixelAlignedCount() {
        for scale in [CGFloat(1), 2] {
            let g = NotchGeometry(
                screen: .init(
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 878)),
                backingScaleFactor: scale)
            XCTAssertEqual(g.glanceRect.height, 20)
            XCTAssertEqual(g.glanceRect.minY * scale, (g.glanceRect.minY * scale).rounded())
            XCTAssertEqual(g.glanceRect.maxY * scale, (g.glanceRect.maxY * scale).rounded())
            XCTAssertTrue(g.window.contains(g.glanceRect))
            XCTAssertTrue(g.screenFrame.contains(g.glanceRect))
        }
    }

    @MainActor
    func testHideMenuActionPersistsAndOnlyExplicitReenableRestoresCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MemoryPlannerPreferences()
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter)
        let store = PlannerStore(file: file, watching: false)
        _ = try XCTUnwrap(store.apply { try $0.addTasks(["Synthetic private task"], on: .day($0.today)) })
        store.updatePrefs { $0.notchTaskCount = true }
        let model = NotchModel()
        let delegate = AppDelegate()
        delegate.store = store
        delegate.model = model
        XCTAssertNotNil(model.glance(in: store, expanded: false, activityVisible: false))
        delegate.hideTaskCount()
        XCTAssertTrue(model.taskCountSuppressed)
        XCTAssertFalse(store.prefs.notchTaskCount)
        XCTAssertFalse(try file.load().preferences.notchTaskCount)
        let relaunched = PlannerStore(file: file, watching: false)
        XCTAssertNil(NotchModel().glance(in: relaunched, expanded: false, activityVisible: false))
        model.taskCountPreferenceChanged(enabled: false)
        XCTAssertNil(model.glance(in: store, expanded: false, activityVisible: false))
        store.updatePrefs { $0.notchTaskCount = true }
        model.taskCountPreferenceChanged(enabled: true)
        XCTAssertNotNil(model.glance(in: store, expanded: false, activityVisible: false))
    }

    @MainActor
    func testHideIsImmediateEvenWhenThePreferenceCannotBeSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.json")
        let seed = PlannerStore(file: PlannerFile(url: url, preferences: MemoryPlannerPreferences()), watching: false)
        _ = try XCTUnwrap(seed.apply { try $0.addTasks(["Synthetic private task"], on: .day($0.today)) })
        let store = PlannerStore(
            file: PlannerFile(url: url, preferences: UnwritableGlancePreferences()), watching: false)
        let model = NotchModel()
        XCTAssertNotNil(model.glance(in: store, expanded: false, activityVisible: false))
        model.hideTaskCount(in: store)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.prefs.notchTaskCount, "The failed save must remain visible as a failure")
        XCTAssertTrue(model.taskCountSuppressed)
        XCTAssertNil(model.glance(in: store, expanded: false, activityVisible: false))
    }

    @MainActor
    func testCountInkFitsCapsuleAtBothBackingScales() async throws {
        for scale in [CGFloat(1), 2] {
            for height in [CGFloat(20), 23] {
                for count in [1, 999, 1000] {
                    var planner = Planner()
                    planner.preferences.notchTaskCount = true
                    planner.tasks = (0..<count).map { _ in PlanTask(title: "Synthetic", day: "2026-11-09") }
                    let glance = try XCTUnwrap(NotchGlancePresentation(planner: planner, today: "2026-11-09"))
                    let textSize = NSAttributedString(
                        string: glance.text,
                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
                    ).size()
                    XCTAssertLessThanOrEqual(
                        textSize.width, 64, "The complete count must fit, not just a truncated label")
                    let view = NotchGlanceCapsule(glance: glance, openToday: {})
                        .frame(width: 76, height: height)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = scale
                    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    var ink: [CGPoint] = []
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            if color.alphaComponent > 0.5 && color.redComponent > 0.5 {
                                ink.append(CGPoint(x: x, y: y))
                            }
                        }
                    }
                    XCTAssertGreaterThan(ink.count, 20, "The count must actually render")
                    XCTAssertTrue(
                        ink.allSatisfy {
                            $0.x >= 5 * scale && $0.x < 71 * scale
                                && $0.y >= 2 * scale && $0.y < (height - 2) * scale
                        }, "Count text must stay inset from every capsule edge")
                }
            }
        }
    }
}
