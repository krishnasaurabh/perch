#!/usr/bin/env bash
# Week heavy fixture: real app snapshot plus OCR/scroll assertions at 820 and 620pt.
set -euo pipefail
OUT=${1:?usage: week_shots.sh OUTPUT_DIRECTORY}; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/Perch.app/Contents/MacOS/Perch"
DATA="$OUT/week-heavy.json"; rm -f "$DATA"
python3 - <<'EOF' | PERCH_DATA="$DATA" "$APP" --mcp > "$OUT/week-seed.log" 2>&1
import json
today = ["Outline the onboarding guide for new contributors covering setup, testing and the release checklist #work",
         "Refill the bird feeder every 3 days", "Text Sam about Saturday at 4pm", "Pay the water bill !high",
         "Return library books", "Phone the landlord at 6pm", "Buy a USB-C charger", "Prep 1:1 agenda",
         "Update insurance card !high", "Read chapter 6 for book club", "Schedule car service",
         "Fix flaky FocusSession test"]
calls = [("add_tasks", {"titles": today}), ("complete_task", {"task": "Buy a USB-C charger"}),
         ("complete_task", {"task": "Return library books"}),
         ("add_tasks", {"titles": ["Ship v1.1", "Standup notes"], "date": "tomorrow"}),
         ("add_tasks", {"titles": ["Multiline heading\nA second line that must remain visible without squeezing the title"], "literal": True}),
         ("add_tasks", {"titles": ["Unscheduled draft"], "date": "inbox"})]
msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "ci", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"}]
msgs += [{"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": n, "arguments": a}} for i, (n, a) in enumerate(calls, 1)]
print("\n".join(json.dumps(m) for m in msgs))
EOF
python3 - "$DATA" <<'EOF'
import json, sys, datetime
p = json.load(open(sys.argv[1])); p.setdefault("preferences", {}).update(
    welcomeCompleted=True, catchCopies=False, catchScreenshots=False)
json.dump(p, open(sys.argv[1], "w"))
on = [t for t in p["tasks"] if t.get("day") == datetime.date.today().isoformat()]
print(f"seeded {len(p['tasks'])} tasks, {len(on)} today, {sum(bool(t.get('repeatRule')) for t in on)} repeating")
assert len(on) >= 10, "need at least 10 tasks today"
EOF
SNAP="$OUT/week-heavy"; rm -rf "$SNAP"; mkdir -p "$SNAP"
PERCH_DATA="$DATA" "$APP" --preview-open --page week --snapshot "$SNAP" > "$OUT/week-heavy.log" 2>&1 &
PID=$!; sleep 6
screencapture -x "$OUT/week-heavy-screen.png" || true
kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true
ls "$SNAP"/*.png || { echo "no Week snapshot"; exit 1; }

# Non-layout measurement backgrounds in an isolated source copy only. The production text,
# columns and scroll views remain unchanged. OCR reads rendered crops, never AX full titles.
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
python3 - "$PROBE/Sources/PerchApp/Workspace/WeekPage.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); week = p.read_text()
edits = {
    '.layoutPriority(1)': '.layoutPriority(1)\n                .background(WeekMeasure(key: "title:\\(task.id)"))',
    '.coordinateSpace(.named(Self.space))': '.coordinateSpace(.named(Self.space))\n            .background(WeekMeasure(key: "list:\\(ref.key?.raw ?? "inbox")"))',
    '.accessibilityLabel("\\(tasks.filter(\\.done).count) of \\(tasks.count) tasks complete")':
        '.accessibilityLabel("\\(tasks.filter(\\.done).count) of \\(tasks.count) tasks complete")\n                    .background(WeekMeasure(key: "count:\\(key)"))',
    '            .onSubmit {': '            .background(WeekMeasure(key: "add:\\(ref.key?.raw ?? "inbox")"))\n            .onSubmit {'
}
for old, new in edits.items():
    assert week.count(old) == 1, f'Week measurement hook changed: {old}'
    week = week.replace(old, new)
p.write_text(week)
assert '.font(Theme.body)' in week
assert '.lineLimit(2)' not in week
assert 'minimumScaleFactor' not in week and 'titleFit(' not in week
PY
cat > "$PROBE/Sources/Perch/main.swift" <<'SWIFT'
import AppKit
import ApplicationServices
import SwiftUI
@testable import PlannerCore
#if canImport(PerchApp)
@testable import PerchApp
import PerchUI
import PerchMCP
#endif
import Vision

func require(_ condition: Bool, _ message: String = "Week assertion failed") {
    guard condition else { fputs("Week assertion failed: \(message)\n", stderr); exit(1) }
}
@MainActor var measurements: [String: NSView] = [:]
struct WeekMeasure: NSViewRepresentable {
    let key: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); measurements[key] = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) { measurements[key] = view }
}
@MainActor func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }
@MainActor func frame(_ key: String, in host: NSView) -> CGRect {
    guard let view = measurements[key], view.window != nil else { fatalError("Missing \(key)") }
    return host.convert(view.bounds, from: view)
}
@MainActor func bitmap(_ host: NSView, rect: CGRect? = nil) -> NSBitmapImageRep {
    let rect = rect ?? host.bounds
    guard let image = host.bitmapImageRepForCachingDisplay(in: rect) else { fatalError("No bitmap") }
    host.cacheDisplay(in: rect, to: image)
    return image
}
@MainActor func save(_ host: NSView, _ url: URL) throws {
    try bitmap(host).representation(using: .png, properties: [:])!.write(to: url)
}
func recognize(_ image: NSBitmapImageRep) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.01
    try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
    let rows = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    return rows.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}
func normalized(_ text: String) -> String {
    String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}
func prefixCount(_ recognized: String, _ title: String) -> Int {
    let read = Array(normalized(recognized)), wanted = Array(normalized(title))
    // OCR sometimes spells out the inline repeat glyph. Ignore at most that short prefix.
    let starts = [0] + (read.count > 1 ? Array(1...min(6, read.count - 1)) : [])
    return starts.map { offset in zip(read.dropFirst(offset), wanted).prefix { $0 == $1 }.count }.max() ?? 0
}
@MainActor func scrollParent(_ key: String) -> NSScrollView {
    var node: NSView? = measurements[key]
    while let view = node {
        if let scroll = view as? NSScrollView { return scroll }
        node = view.superview
    }
    fatalError("Missing list scroll view")
}
@MainActor func allScrolls(_ root: NSView) -> [NSScrollView] {
    let own = (root as? NSScrollView).map { [$0] } ?? []
    return own + root.subviews.flatMap { allScrolls($0) }
}
func XCTFreeUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "WeekProbe", code: 1) }
    return value
}
func wakeAccessibility() async {
    await Task.detached {
        let app = AXUIElementCreateApplication(getpid())
        var windows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] {
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        }
    }.value
}
@MainActor func attribute(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}
@MainActor func nodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    @MainActor func walk(_ node: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let children = (attribute(node, "accessibilityChildren") as? [NSObject]) ?? []
        let contents = (attribute(node, "accessibilityContents") as? [NSObject]) ?? []
        let subviews = (node as? NSView)?.subviews ?? []
        return [node] + (children + contents + subviews).flatMap { walk($0) }
    }
    return walk(root)
}
@MainActor func completionName(_ task: PlanTask, in host: NSView) -> String {
    let identifier = "week-check-\(task.id)"
    guard let node = nodes(host).first(where: { attribute($0, "accessibilityIdentifier") as? String == identifier })
    else { require(false, "Missing completion control: \(identifier)"); return "" }
    require(attribute(node, "accessibilityRole") as? String == "AXButton", "Completion control is not a button")
    let name = (attribute(node, "accessibilityLabel") as? String)
        ?? (attribute(node, "accessibilityTitle") as? String) ?? ""
    let expected = "\(task.done ? "Uncheck task" : "Check off task"): \(task.title)"
    require(name == expected, "Completion name is not task-specific: \(name)")
    return name
}
@MainActor func press(_ identifier: String, in host: NSView) {
    guard let node = nodes(host).first(where: { attribute($0, "accessibilityIdentifier") as? String == identifier })
    else { require(false, "Missing native control: \(identifier)"); return }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        require(false, "Control cannot press: \(identifier)"); return
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    require(unsafeBitCast(implementation, to: Press.self)(node, selector), "Native press rejected")
}
@MainActor func contextMenu(in root: NSView) -> NSMenu? {
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: root.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    if let menu = root.menu(for: event), menu.items.contains(where: { $0.title == "Details…" }) { return menu }
    for child in root.subviews { if let menu = contextMenu(in: child) { return menu } }
    return nil
}
@MainActor func verifyCalendarRollover(window: NSWindow, out: URL, model: NotchModel,
                                       seedDay: DayKey, whileInInbox: Bool) async throws -> [String: Any] {
    let calendar = Calendar.current
    let lastDay = WeekColumnLayout.days(today: seedDay, calendar: calendar).last!
    let nextDay = lastDay.adding(days: 1, calendar: calendar)
    let boundary = nextDay.start(resetHour: 4, calendar: calendar)
    var now = boundary.addingTimeInterval(-1)
    let file = PlannerFile(url: out.appendingPathComponent("rollover-\(seedDay.raw).json"))
    var seed = Planner(); seed.preferences.resetHour = 4
    try file.save(seed)
    let store = PlannerStore(file: file, now: { now }, watching: false)
    let id = try XCTFreeUnwrap(store.send(.addTasks(["Daily week fixture"], day: nil,
        literal: true, agentID: nil))?.tasks.first?.id)
    var edit = TaskEdit(); edit.repeatRule = "daily"
    require(store.send(.update(id, edit)) != nil, "Daily fixture setup failed")
    store.beginApplication()
    measurements.removeAll()
    let host = NSHostingView(rootView: WeekPage().environmentObject(store).environmentObject(model)
        .environment(\.accessibilityEnabled, true)
        .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)).padding(12))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    await settle()
    for _ in 0..<3 {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        require(window.performKeyEquivalent(with: event), "Next-week shortcut not handled")
        await settle()
    }
    let oldDays = WeekColumnLayout.days(today: store.today, weekOffset: 3, calendar: calendar)
    require(oldDays.allSatisfy { day in store.engine.tasks(on: .day(day)).count == 1 },
            "Navigation did not generate the selected week")
    let newDays = WeekColumnLayout.days(today: nextDay, weekOffset: 3, calendar: calendar)
    require(store.engine.tasks(on: .day(newDays.last!)).isEmpty,
            "Negative control is already covered by the reminder horizon")
    if whileInInbox {
        await wakeAccessibility(); press("week-inbox", in: host); await settle()
        require(measurements["add:inbox"]?.window != nil, "Inbox fixture not active")
    }
    now = boundary.addingTimeInterval(-0.5)
    store.advanceLifecycle(); await settle()
    require(store.today == lastDay, "Week changed before its configured reset hour")
    now = boundary
    store.advanceLifecycle(); await settle()
    require(store.today == nextDay, "Logical day did not advance at reset")
    let saved = try file.load()
    for day in newDays {
        require(saved.tasks.filter { $0.day == day && $0.title == "Daily week fixture" }.count == 1,
                "Missing or duplicated recurring task on displayed day \(day.raw)")
    }
    if whileInInbox {
        press("week-inbox", in: host); await settle()
    }
    require(newDays.allSatisfy { measurements["count:\($0.raw)"]?.window != nil },
            "Rendered week did not follow the logical-week boundary")
    let editableID = try XCTFreeUnwrap(saved.tasks.first { $0.day == newDays.first }?.id)
    require(store.send(.rename(editableID, "Renamed fixture")) != nil, "Rename fixture failed")
    store.undo(); await settle()
    require(store.canRedo, "Range observation replayed a mutation after Undo")
    let bytes = try Data(contentsOf: file.url)
    let modified = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
    store.lastError = .planner("Synthetic presentation update")
    await settle()
    require(try Data(contentsOf: file.url) == bytes, "Unrelated presentation update rewrote tasks")
    let afterModified = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
    require(afterModified == modified, "Unrelated presentation update touched storage")
    try save(host, out.appendingPathComponent("rollover-\(seedDay.raw).png"))
    print("PASS Week rollover: \(lastDay.raw) to \(nextDay.raw), seven persisted occurrences, Inbox \(whileInInbox)")
    return ["before": lastDay.raw, "after": nextDay.raw, "resetHour": 4,
            "displayedDays": newDays.map(\.raw), "whileInInbox": whileInInbox, "persistedOccurrences": 7]
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEEK_OUTPUT"]!)
    let store = PlannerStore(watching: false), model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
    let today = store.today.raw
    let tasks = store.engine.tasks(on: .day(store.today))
    require(tasks.count >= 10 && tasks.contains { $0.repeatRule != nil })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .black
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    Task { @MainActor in
        do {
            var results: [[String: Any]] = []
            for width in [820, 620] {
                measurements.removeAll()
                window.setContentSize(NSSize(width: width, height: 300))
                let host = NSHostingView(rootView: WeekPage()
                    .environmentObject(store).environmentObject(model)
                    .environment(\.colorScheme, .dark)
                    .environment(\.accessibilityEnabled, true)
                    .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true))
                    .padding(12).background(Color.black))
                window.contentView = host
                await settle()
                try save(host, out.appendingPathComponent("heavy-\(width).png"))
                let addBefore = frame("add:\(today)", in: host)
                let countRead = try recognize(bitmap(host, rect: frame("count:\(today)", in: host)))
                let countWanted = "\(tasks.filter(\.done).count)/\(tasks.count) done"
                require(normalized(countRead) == normalized(countWanted), "Unreadable count: \(countRead)")
                let addRead = try recognize(bitmap(host, rect: addBefore))
                require(normalized(addRead) == "addatask", "Unreadable Add: \(addRead)")
                require(host.bounds.contains(addBefore), "Add is outside the page")
                var titles: [[String: Any]] = [], scores: [Int] = []
                let listScroll = scrollParent("title:\(tasks[0].id)")
                var seen = Set<UUID>()
                let maximum = max(0, listScroll.documentView!.bounds.height - listScroll.contentView.bounds.height)
                // Scan the actual scrolling viewport; short panels need not display five rows simultaneously.
                for offset in stride(from: CGFloat(0), through: maximum + 1, by: CGFloat(40)) {
                    listScroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, maximum)))
                    listScroll.reflectScrolledClipView(listScroll.contentView)
                    await settle()
                for task in store.planner.tasks where !seen.contains(task.id) {
                    guard let marker = measurements["title:\(task.id)"], marker.window != nil else { continue }
                    let rect = frame("title:\(task.id)", in: host)
                    let list = frame("list:\(task.day?.raw ?? "inbox")", in: host)
                    // Exclude partially clipped titles and the bottom 22pt fade, not failed OCR.
                    guard host.bounds.intersection(list).contains(rect), rect.maxY <= list.maxY - 22 else { continue }
                    let read = try recognize(bitmap(host, rect: rect))
                    let chars = prefixCount(read, task.title), length = normalized(task.title).count
                    seen.insert(task.id)
                    scores.append(chars + max(0, 12 - length))
                    titles.append(["title": task.title, "ocr": read, "visibleCharacters": chars,
                                   "required": min(12, length), "rect": [rect.minX, rect.minY, rect.width, rect.height]])
                }
                }
                let multiline = try XCTFreeUnwrap(tasks.first { $0.title.contains("\n") })
                let multilineRect = frame("title:\(multiline.id)", in: host)
                let reference = NSHostingView(rootView: Text(multiline.title).font(Theme.body)
                    .fixedSize(horizontal: false, vertical: true).frame(width: multilineRect.width))
                reference.frame.size.width = multilineRect.width
                require(reference.fittingSize.height > 40, "Multiline positive control must exceed two lines")
                require(multilineRect.height >= reference.fittingSize.height - 1, "Multiline title clipped")
                listScroll.contentView.scroll(to: .zero)
                listScroll.reflectScrolledClipView(listScroll.contentView)
                await settle()
                scores.sort()
                require(scores.count >= 5, "Missing title coverage: \(titles)")
                let median = Double(scores[(scores.count - 1) / 2] + scores[scores.count / 2]) / 2
                require(median >= 12, "Short median \(median): \(titles)")
                let scroll = scrollParent("title:\(tasks[0].id)")
                let oldOffset = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView!.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle()
                let addAfter = frame("add:\(today)", in: host)
                require(abs(scroll.contentView.bounds.origin.y - oldOffset.y) > 20, "List did not scroll")
                require(abs(addBefore.minY - addAfter.minY) < 0.5 && abs(addBefore.height - addAfter.height) < 0.5,
                             "Add moved with the list")
                let afterRead = try recognize(bitmap(host, rect: addAfter))
                require(normalized(afterRead) == "addatask")
                try save(host, out.appendingPathComponent("heavy-\(width)-scrolled.png"))
                // The Inbox is a real button outside the seven-day scroll, never an eighth column.
                await wakeAccessibility()
                press("week-inbox", in: host)
                await settle()
                let inboxFrame = frame("add:inbox", in: host)
                require(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inboxFrame), "Inbox unreachable")
                try save(host, out.appendingPathComponent("heavy-\(width)-inbox.png"))
                press("week-inbox", in: host)
                await settle()
                await wakeAccessibility()
                let checkID = "week-check-\(tasks[0].id)"
                let namedTasks = Array(store.engine.tasks(on: .day(store.today)).prefix(2))
                require(namedTasks.count == 2 && namedTasks[0].title != namedTasks[1].title,
                        "Distinct task-name positive control is missing")
                let completionNames = namedTasks.map { completionName($0, in: host) }
                require(Set(completionNames).count == 2, "Completion buttons share an accessible name")
                let wasDone = store.planner.tasks.first { $0.id == tasks[0].id }!.done
                press(checkID, in: host)
                await settle()
                require(store.planner.tasks.first { $0.id == tasks[0].id }!.done != wasDone, "Check action did not publish")
                let saved = try store.file.load()
                require(saved.tasks.first { $0.id == tasks[0].id }!.done != wasDone, "Check action did not persist")
                require(saved.tasks.count == store.planner.tasks.count, "Check changed task identity/count")
                await wakeAccessibility()
                _ = completionName(try XCTFreeUnwrap(saved.tasks.first { $0.id == tasks[0].id }), in: host)
                require(saved.tasks.first { $0.id == namedTasks[1].id }!.done == namedTasks[1].done,
                        "Checking one task changed its neighbour")
                press(checkID, in: host)
                await settle()
                require(store.planner.tasks.first { $0.id == tasks[0].id }!.done == wasDone, "Uncheck did not persist")
                // Invoke the real native context menu, not a substitute model mutation.
                let menu = try XCTFreeUnwrap(contextMenu(in: host))
                let detailsIndex = menu.items.firstIndex { $0.title == "Details…" }!
                menu.performActionForItem(at: detailsIndex)
                await settle()
                require(store.planner.tasks.contains { $0.id == model.detailsTaskID }, "Native Details menu lost task identity")
                model.detailsTaskID = nil
                // Command-Option-I is the Week keyboard shortcut, including when a task list scrolled.
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "i",
                    charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
                require(window.performKeyEquivalent(with: event), "Inbox keyboard shortcut not handled")
                await settle()
                require(measurements["add:inbox"]?.window != nil, "Shortcut did not reveal Inbox")
                results.append(["width": width, "medianVisibleCharacters": median, "titles": titles,
                                "countOCR": countRead, "addOCR": addRead, "addPinned": true, "inboxReachable": true, "nativeCheck": true, "nativeMenu": true, "inboxShortcut": true])
                print("PASS Week \(width): median \(median), \(titles.count) title crops; count \(countRead); Add pinned; Inbox reachable")
            }
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appendingPathComponent("heavy-assertions.json"))
            var rollovers: [[String: Any]] = []
            for (seed, inbox) in [("2026-03-08", false), ("2026-11-01", true)] {
                rollovers.append(try await verifyCalendarRollover(window: window, out: out, model: model,
                    seedDay: DayKey(seed)!, whileInInbox: inbox))
            }
            try JSONSerialization.data(withJSONObject: rollovers, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appendingPathComponent("rollover-assertions.json"))
            exit(0)
        } catch { fputs("Week assertion error: \(error)\n", stderr); exit(1) }
    }
    withExtendedLifetime((window, store, model)) { app.run() }
}
SWIFT
# The instrumented Week view is in the app library, so its measurement helper must
# live there too. Keep one shared registry; the executable reads it with @testable.
python3 - "$PROBE" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
entry = root / 'Sources/Perch/main.swift'
source = entry.read_text()
start = source.index('@MainActor var measurements:')
end = source.index('@MainActor func settle()', start)
helper = source[start:end]
(root / 'Sources/PerchApp/Workspace/WeekMeasure.swift').write_text(
    'import AppKit\nimport SwiftUI\n\n' + helper)
entry.write_text(source[:start] + source[end:])
PY
swift build --jobs 2 -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
PERCH_DATA="$DATA" WEEK_OUTPUT="$OUT" "$PROBE/.build/release/Perch"
