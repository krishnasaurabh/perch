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
         ("add_tasks", {"titles": ["Ship v1.1", "Standup notes"], "date": "tomorrow"})]
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
python3 - "$PROBE/Sources/Perch/Workspace/WeekAndClips.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); week, clips = p.read_text().split('/// Clips:', 1)
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
p.write_text(week + '/// Clips:' + clips)
assert 'title(size: WeekColumnLayout.titleSize)' in week
assert '.lineLimit(2).truncationMode(.tail)' in week
assert 'minimumScaleFactor' not in week and 'titleFit(' not in week
PY
cat > "$PROBE/Sources/Perch/App/main.swift" <<'SWIFT'
import AppKit
import SwiftUI
import PlannerCore
import Vision

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
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEEK_OUTPUT"]!)
    let store = PlannerStore(), model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
    let today = store.today.raw
    let tasks = store.engine.tasks(on: .day(store.today))
    precondition(tasks.count >= 10 && tasks.contains { $0.repeatRule != nil })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
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
                    .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true))
                    .padding(12).background(Color.black))
                window.contentView = host
                await settle()
                try save(host, out.appendingPathComponent("heavy-\(width).png"))
                let addBefore = frame("add:\(today)", in: host)
                let countRead = try recognize(bitmap(host, rect: frame("count:\(today)", in: host)))
                let countWanted = "\(tasks.filter(\.done).count)/\(tasks.count) done"
                precondition(normalized(countRead) == normalized(countWanted), "Unreadable count: \(countRead)")
                let addRead = try recognize(bitmap(host, rect: addBefore))
                precondition(normalized(addRead) == "addatask", "Unreadable Add: \(addRead)")
                precondition(host.bounds.contains(addBefore), "Add is outside the page")
                var titles: [[String: Any]] = [], scores: [Int] = []
                for task in store.planner.tasks {
                    guard let marker = measurements["title:\(task.id)"], marker.window != nil else { continue }
                    let rect = frame("title:\(task.id)", in: host)
                    let list = frame("list:\(task.day?.raw ?? "inbox")", in: host)
                    // Exclude partially clipped titles and the bottom 22pt fade, not failed OCR.
                    guard host.bounds.intersection(list).contains(rect), rect.maxY <= list.maxY - 22 else { continue }
                    let read = try recognize(bitmap(host, rect: rect))
                    let chars = prefixCount(read, task.title), length = normalized(task.title).count
                    scores.append(chars + max(0, 12 - length))
                    titles.append(["title": task.title, "ocr": read, "visibleCharacters": chars,
                                   "required": min(12, length), "rect": [rect.minX, rect.minY, rect.width, rect.height]])
                }
                scores.sort()
                precondition(scores.count >= 5, "Missing title coverage: \(titles)")
                let median = Double(scores[(scores.count - 1) / 2] + scores[scores.count / 2]) / 2
                precondition(median >= 12, "Short median \(median): \(titles)")
                let scroll = scrollParent("title:\(tasks[0].id)")
                let oldOffset = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView!.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle()
                let addAfter = frame("add:\(today)", in: host)
                precondition(abs(scroll.contentView.bounds.origin.y - oldOffset.y) > 20, "List did not scroll")
                precondition(abs(addBefore.minY - addAfter.minY) < 0.5 && abs(addBefore.height - addAfter.height) < 0.5,
                             "Add moved with the list")
                let afterRead = try recognize(bitmap(host, rect: addAfter))
                precondition(normalized(afterRead) == "addatask")
                try save(host, out.appendingPathComponent("heavy-\(width)-scrolled.png"))
                guard let horizontal = allScrolls(host).first(where: {
                    ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 20
                }) else { fatalError("Missing horizontal Week viewport") }
                horizontal.contentView.scroll(to: NSPoint(x: horizontal.documentView!.bounds.width, y: 0))
                horizontal.reflectScrolledClipView(horizontal.contentView)
                await settle()
                precondition(host.bounds.contains(frame("add:inbox", in: host)), "Inbox unreachable")
                try save(host, out.appendingPathComponent("heavy-\(width)-inbox.png"))
                results.append(["width": width, "medianVisibleCharacters": median, "titles": titles,
                                "countOCR": countRead, "addOCR": addRead, "addPinned": true, "inboxReachable": true])
                print("PASS Week \(width): median \(median), \(titles.count) title crops; count \(countRead); Add pinned; Inbox reachable")
            }
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appendingPathComponent("heavy-assertions.json"))
            exit(0)
        } catch { fputs("Week assertion error: \(error)\n", stderr); exit(1) }
    }
    withExtendedLifetime((window, store, model)) { app.run() }
}
SWIFT
swift build --package-path "$PROBE" -c release --product Perch
PERCH_DATA="$DATA" WEEK_OUTPUT="$OUT" "$PROBE/.build/release/Perch"
