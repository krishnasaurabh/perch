import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PlannerCore
@testable import PerchUI
@testable import PerchApp

/// Your week intentionally has one completion series, not the retired planned/done comparison.
@MainActor
final class InsightsDashboardChartTests: XCTestCase {
    func testCompletedTasksShareZeroBaselineAndFutureDaysUseFlatStubs() async throws {
        let counts = [1, 4, 2, 3, 1, 0, 0]
        for scheme in [ColorScheme.light, .dark] {
            let bars = try await render(counts: counts, scheme: scheme)
            XCTAssertEqual(bars.count, 7)
            guard bars.count == 7 else { continue }
            let baseline = try XCTUnwrap(bars.map(\.maxY).max())
            let unit = bars[1].height / 4
            XCTAssertGreaterThan(unit, 10)
            for index in counts.indices {
                XCTAssertEqual(bars[index].maxY, baseline, accuracy: 1, "A common zero baseline")
                XCTAssertEqual(bars[index].height, index < 5 ? Double(counts[index]) * unit : 4, accuracy: 2)
                if index > 0 { XCTAssertLessThan(bars[index - 1].maxX, bars[index].minX) }
            }
        }
    }

    func testEmptyWeekRetainsSevenFlatStubs() async throws {
        let bars = try await render(counts: Array(repeating: 0, count: 7), scheme: .light)
        XCTAssertEqual(bars.count, 7)
        for bar in bars { XCTAssertEqual(bar.height, 4, accuracy: 1) }
    }

    private struct Bar {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
        var height: Double { maxY - minY }
    }

    private func render(counts: [Int], scheme: ColorScheme) async throws -> [Bar] {
        _ = NSApplication.shared
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        var planner = Planner()
        for (index, count) in counts.enumerated() {
            let day = DayKey("2026-11-09").adding(days: index, calendar: calendar)
            for n in 0..<count {
                planner.tasks.append(PlanTask(title: "Chart \(index)-\(n)", day: day, done: true))
            }
        }
        let now = DayKey("2026-11-13").date(calendar: calendar).addingTimeInterval(12 * 3600)
        let model = YourWeekModel(engine: PlannerEngine(planner: planner, now: { now }, calendar: calendar))
        XCTAssertEqual(model.days.map(\.done), counts)
        let size = CGSize(width: 400, height: 180)
        let host = NSHostingView(
            rootView:
                Card(.mint) { YourWeekBars(days: model.days, calendar: calendar) }
                .preferredColorScheme(scheme)
                .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / size.width
        let token = DesignTokens.ColorToken.doneFill.hex(in: scheme == .dark ? .dark : .light)
        var bars: [Bar] = []
        for x in 0..<bitmap.pixelsWide {
            let ys = (0..<bitmap.pixelsHigh).filter { y in
                var pixel = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&pixel, atX: x, y: y)
                return pixel[3] == 255 && abs(pixel[0] - Int((token >> 16) & 255)) <= 3
                    && abs(pixel[1] - Int((token >> 8) & 255)) <= 3 && abs(pixel[2] - Int(token & 255)) <= 3
            }
            guard let top = ys.first, let bottom = ys.last else { continue }
            if let previous = bars.last, previous.maxX == Double(x) / scale {
                bars[bars.count - 1].maxX = Double(x + 1) / scale
                bars[bars.count - 1].minY = min(previous.minY, Double(top) / scale)
                bars[bars.count - 1].maxY = max(previous.maxY, Double(bottom + 1) / scale)
            } else {
                bars.append(
                    Bar(
                        minX: Double(x) / scale, maxX: Double(x + 1) / scale,
                        minY: Double(top) / scale, maxY: Double(bottom + 1) / scale))
            }
        }
        return bars.filter { $0.maxX - $0.minX > 8 }
    }
}
