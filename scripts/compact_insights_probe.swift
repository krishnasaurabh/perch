// Temporary CI entry point: renders the real Insights page at the compact workspace width.
//
// Every other layout snapshot comes from the runner's 1024x768 virtual display, so the page is
// always 784pt wide and Insights takes its two-column branch. This probe hosts the real
// WorkspaceView at both shell widths (NotchRootView's 10pt shell inset + the workspace's own 8pt
// page inset) and writes PNGs plus geometry, so the compact stacked branch is finally rendered
// and measurable. Output is read by scripts/measure_compact_insights.py.
import AppKit
import ApplicationServices
import SwiftUI
@testable import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
#endif

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

@MainActor
func settle() async { try? await Task.sleep(nanoseconds: 900_000_000) }

func wakeAX() async {
    await Task.detached {
        let app = AXUIElementCreateApplication(getpid())
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        for window in (value as? [AXUIElement]) ?? [] {
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        }
    }.value
}

@MainActor
func attribute(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}

@MainActor
func axNodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ node: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        return [node] + ((attribute(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(walk)
    }
    return walk(root)
}

/// Native frame as PNG pixel coordinates (top-left origin), so the numbers line up with the
/// measurements the Python script takes from the same bitmap.
@MainActor
func imageRect(_ screen: NSRect, window: NSWindow, root: NSView) -> [Double] {
    let inWindow = window.convertFromScreen(screen)
    let inRoot = root.convert(inWindow, from: nil)
    let y = root.isFlipped ? inRoot.minY : root.bounds.height - inRoot.maxY
    return [inRoot.minX, y, inRoot.width, inRoot.height]
}

@MainActor
func axLabels(_ root: NSView, window: NSWindow) -> [[String: Any]] {
    var entries: [[String: Any]] = []
    for node in axNodes(root) {
        guard let label = attribute(node, "accessibilityLabel") as? String, !label.isEmpty,
            node.responds(to: NSSelectorFromString("accessibilityFrame")),
            let value = node.value(forKey: "accessibilityFrame") as? NSValue
        else { continue }
        let rect = imageRect(value.rectValue, window: window, root: root)
        entries.append(["label": label, "rect": rect])
    }
    return entries
}

@MainActor
func snapshot(_ root: NSView, _ name: String, into output: URL) {
    root.layoutSubtreeIfNeeded()
    let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
    root.cacheDisplay(in: root.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}

/// Renders the real workspace at one shell width. The shell is 704pt wide at the compact size
/// (820 - 2*8 screen margins on a 720pt screen) and 820pt wide on a wide display.
/// Deliberately unclipped: overflow ink below the shell stays visible instead of being cut at the
/// shape, so the measurement can say what a reviewer would see.
@MainActor
func capture(_ name: String, shellWidth: CGFloat, delegate: AppDelegate, output: URL) async -> [String: Any] {
    let size = CGSize(width: shellWidth, height: WorkspaceLayout.preferredSize().height)
    let window = NSWindow(
        contentRect: CGRect(x: 40, y: 40, width: size.width, height: size.height),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(
        rootView:
            WorkspaceView(notchHeight: 0)
            .environmentObject(delegate.store).environmentObject(delegate.model)
            .environmentObject(delegate.services)
            // NotchRootView keeps the workspace 10pt inside each shell edge; WorkspaceView keeps
            // its page 8pt inside its own edge. Both are part of the real page geometry.
            .padding(.horizontal, 10)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.black)
            .environment(\.colorScheme, .dark))
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    await settle()
    await wakeAX()
    await settle()
    snapshot(root, name, into: output)
    let pageWidth = (size.width - 20) - 16
    let labels = axLabels(root, window: window)
    let entry: [String: Any] = [
        "name": name, "file": name + ".png",
        "shell": [size.width, size.height],
        "pageWidth": pageWidth,
        "layout": String(describing: InsightsPageLayout.resolve(width: pageWidth)),
        "presented": [root.bounds.width, root.bounds.height],
        "isFlipped": root.isFlipped,
        "ax": labels,
    ]
    window.orderOut(nil)
    return entry
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COMPACT_INSIGHTS_OUTPUT"]!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            var metrics: [[String: Any]] = []
            delegate.seedScenario("insights")
            await settle()
            delegate.model.page = .insights
            await settle()

            // Guard the fixture itself: an empty planner renders the "will take shape here" tile
            // instead of the chart and no measurement below would mean anything.
            let insights = delegate.store.engine.insights()
            require(insights.allTimeCompleted > 0, "insights fixture recorded finished tasks")
            require(insights.today.planned > 0, "insights fixture has tasks planned today")
            require(delegate.model.page == .insights, "Insights page is the presented page")
            let expectedStats = [
                "tasks done this week", "focused this week", "streak", "done today",
            ]
            print(
                "fixture: allTimeCompleted=\(insights.allTimeCompleted) today=\(insights.today.completed)/\(insights.today.planned) streak=\(insights.streak) calendarEvents=\(insights.allTimeCompletedCalendarEvents)"
            )

            metrics.append(await capture("insights-compact", shellWidth: 704, delegate: delegate, output: output))
            metrics.append(await capture("insights-wide", shellWidth: 820, delegate: delegate, output: output))

            // Tallest momentum state: with calendar events checked off it carries a fifth stat row.
            delegate.store.seedFixture { e in
                e.planner.completedCalendarEventIDs = ["fixture-event-1", "fixture-event-2"]
                e.planner.completedCalendarEventDays = ["fixture-event-1": e.today, "fixture-event-2": e.today]
            }
            await settle()
            require(
                delegate.store.engine.insights().allTimeCompletedCalendarEvents == 2,
                "calendar-events fixture recorded checked-off events")
            metrics.append(
                await capture("insights-compact-calendar", shellWidth: 704, delegate: delegate, output: output))

            // Diagnostic only: the measurement reads pixels, not the accessibility tree. Recorded so
            // a later card can tell whether momentum rows are exposed to assistive technology when
            // they are drawn past the card fill.
            for entry in metrics {
                let labels = (entry["ax"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
                let stats = labels.filter { label in expectedStats.contains { label.hasSuffix($0) } }
                print(
                    "ax \(entry["name"] as? String ?? "?"): \(labels.count) labelled elements, "
                        + "momentum stat rows exposed: \(stats)")
            }

            let data = try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: output.appendingPathComponent("geometry.json"))
            print("Compact Insights captures finished.")
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}

// Deliberately authored fixture setup, not a production mutation entry point.
@MainActor
private extension PlannerStore {
    func seedFixture(_ body: (inout PlannerEngine) throws -> Void) {
        do {
            try file.mutate { planner in
                var engine = PlannerEngine(planner: planner)
                try body(&engine)
                planner = engine.planner
            }
            reloadFromDisk(external: false)
        } catch { lastError = .planner(error.perchPresentationDetail) }
    }
}
