import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PlannerCore
@testable import PerchUI
@testable import PerchApp

@MainActor
final class InsightsDashboardChartTests: XCTestCase {
    func testCompletedTasksShareZeroBaselineInsteadOfAddingToPlanned() async throws {
        let counts = [(1, 1), (4, 2), (2, 2), (3, 0), (0, 0), (0, 0), (0, 0)]
        let bitmap = try await render(counts: counts, name: "planned-completed")
        let bars = try chartBars(in: bitmap)
        XCTAssertEqual(bars.planned.count, 4, "Every nonempty day has one Planned bar")
        XCTAssertEqual(bars.completed.count, 3, "Only completed tasks have a Completed bar")
        guard bars.planned.count == 4, bars.completed.count == 3 else { return }

        let baseline = try XCTUnwrap(bars.planned.map(\.maxY).max())
        let unit = bars.planned[1].height / 4
        XCTAssertGreaterThan(unit, 10, "The chart must have measurable task-height units")
        for index in 0..<4 {
            let planned = bars.planned[index]
            let completed = index < 3 ? bars.completed[index] : nil
            let (p, c) = counts[index]
            XCTAssertEqual(planned.maxY, baseline, accuracy: 1, "Planned starts at zero: day \(index)")
            XCTAssertEqual(planned.height, Double(p) * unit, accuracy: 2, "Planned height: day \(index)")
            if let completed {
                XCTAssertEqual(completed.maxY, baseline, accuracy: 1, "Completed starts at zero: day \(index)")
                XCTAssertEqual(completed.height, Double(c) * unit, accuracy: 2, "Completed height: day \(index)")
                XCTAssertLessThan(planned.maxX, completed.minX, "Series remain distinguishable side by side")
            }
            let top = min(planned.minY, completed?.minY ?? baseline)
            XCTAssertEqual(
                baseline - top, Double(max(p, c)) * unit, accuracy: 2,
                "planned=\(p), completed=\(c) must plot as \(max(p, c)), never \(p + c)")
        }
        // The three trailing empty dates must not add either series to the four populated dates.
        let lastPopulatedX = bars.planned[3].maxX
        XCTAssertTrue(bars.completed.allSatisfy { $0.maxX < lastPopulatedX })
    }

    func testEmptyWeekHasNoPlannedOrCompletedBars() async throws {
        let bitmap = try await render(counts: Array(repeating: (0, 0), count: 7), name: "empty-week")
        let bars = try chartBars(in: bitmap)
        XCTAssertTrue(bars.planned.isEmpty)
        XCTAssertTrue(bars.completed.isEmpty)
    }

    private func render(counts: [(Int, Int)], name: String) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let finalNow = Date(timeIntervalSince1970: 1_800_014_400)
        var now = finalNow
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { now }, watching: false)
        let lastDay = store.today
        for (index, count) in counts.enumerated() {
            let day = lastDay.adding(days: index - 6)
            // Add and complete while each date is editable, then advance the injected clock.
            now = day.date().addingTimeInterval(12 * 60 * 60)
            if count.0 > 0 {
                let tasks = try XCTUnwrap(
                    store.apply { engine in
                        try engine.addTasks(
                            (0..<count.0).map { "Chart task \(index)-\($0)" }, on: .day(day), literal: true)
                    })
                for task in tasks.prefix(count.1) {
                    XCTAssertNotNil(store.apply { try $0.complete(task.id) })
                }
            }
        }
        now = finalNow
        let days = store.engine.insights().lastSeven
        XCTAssertEqual(days.map(\.planned), counts.map(\.0))
        XCTAssertEqual(days.map(\.completed), counts.map(\.1))

        let size = CGSize(width: 840, height: 620)
        let host = NSHostingView(
            rootView: InsightsDashboard().environmentObject(store)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.gray))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
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
        if let output = ProcessInfo.processInfo.environment["RUNNER_TEMP"] {
            let directory = URL(fileURLWithPath: output).appendingPathComponent("native-diagnostics/dashboard-chart")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    private struct Bar: CustomStringConvertible {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
        var height: Double { maxY - minY }
        var description: String { "(x: \(minX)...\(maxX), y: \(minY)...\(maxY))" }
    }

    private func chartBars(in bitmap: NSBitmapImageRep) throws -> (planned: [Bar], completed: [Bar]) {
        let scale = Double(bitmap.pixelsWide) / 840
        // Find the first timer card by its actual surface, not an assumed dashboard y-coordinate.
        // A column inside its padding is free of text, axes and marks.
        let cardRows = (0..<bitmap.pixelsHigh).filter { y in
            matches(bitmap, x: Int(8 * scale), y: y, token: ThemeTokens.lavender)
        }
        let runs = contiguous(cardRows).filter { Double($0.count) > 180 * scale }
        let card = try XCTUnwrap(runs.first, "The rendered Planned vs. done card must be present")
        // Exclude the heading and legend. Keep the full bar area, including its zero baseline.
        let minY = card.lowerBound + Int(34 * scale)
        let maxY = card.upperBound - Int(35 * scale)
        let minX = Int(18 * scale)
        let maxX = bitmap.pixelsWide - Int(50 * scale)
        func rectangles(token: UInt32) -> [Bar] {
            var bars: [Bar] = []
            for x in minX..<maxX {
                let pixels = (minY..<maxY).filter { matches(bitmap, x: x, y: $0, token: token) }
                guard let run = contiguous(pixels).max(by: { $0.count < $1.count }),
                    Double(run.count) >= 8 * scale
                else { continue }
                let top = Double(run.lowerBound) / scale
                let bottom = Double(run.upperBound) / scale
                if let previous = bars.last,
                    abs(previous.maxX - Double(x) / scale) < 0.1,
                    abs(previous.minY - top) <= 1 / scale,
                    abs(previous.maxY - bottom) <= 1 / scale
                {
                    bars[bars.count - 1].maxX = Double(x + 1) / scale
                } else {
                    bars.append(Bar(minX: Double(x) / scale, maxX: Double(x + 1) / scale, minY: top, maxY: bottom))
                }
            }
            // Glyph stems and antialiasing cannot count as a bar: require a solid rectangular interior.
            return bars.filter { $0.maxX - $0.minX >= 8 }
        }
        let planned = rectangles(token: ThemeTokens.chartPlanned)
        let completed = rectangles(token: ThemeTokens.chartCompleted)
        print("Dashboard chart rectangles: planned=\(planned), completed=\(completed)")
        return (planned, completed)
    }

    private func matches(_ bitmap: NSBitmapImageRep, x: Int, y: Int, token: UInt32) -> Bool {
        // Read encoded components: a display-profile conversion can alter otherwise exact token bytes.
        guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4,
            !bitmap.bitmapFormat.contains(.alphaFirst)
        else { return false }
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: x, y: y)
        return pixel[3] == 255
            && abs(pixel[0] - Int((token >> 16) & 255)) <= 6
            && abs(pixel[1] - Int((token >> 8) & 255)) <= 6
            && abs(pixel[2] - Int(token & 255)) <= 6
    }

    private func contiguous(_ values: [Int]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for value in values {
            if let last = runs.last, last.upperBound == value {
                runs[runs.count - 1] = last.lowerBound..<(value + 1)
            } else {
                runs.append(value..<(value + 1))
            }
        }
        return runs
    }
}
