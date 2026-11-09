import AppKit
import PlannerCore
import SwiftUI
import UniformTypeIdentifiers

/// The week ahead, plus the Inbox. Drag a task to any day.
struct WeekPage: View {
    @EnvironmentObject var store: PlannerStore
    @State private var anchor = 0  // weeks from this one
    @State private var target: String?

    var body: some View {
        let start = store.today.adding(days: anchor * 7)
        let days = (0..<7).map { start.adding(days: $0) }
        VStack(spacing: 8) {
            HStack {
                GlassButton(symbol: "chevron.left", help: "Previous week", size: 22) { go(anchor - 1) }
                Text(anchor == 0 ? "This week" : start.date().formatted(.dateTime.month(.wide).day()))
                    .font(.system(size: 12, weight: .semibold))
                GlassButton(symbol: "chevron.right", help: "Next week", size: 22) { go(anchor + 1) }
                if anchor != 0 { Button("Today") { go(0) }.buttonStyle(PillStyle()) }
                Spacer()
                Text("Drop tasks onto a day, or park them in the Inbox.").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
            // Changing weeks crossfades the day columns in place, like a page switch (`Motion.page`).
            ZStack(alignment: .top) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(days, id: \.self) { d in
                        column(title: d.date().formatted(.dateTime.weekday(.abbreviated)), subtitle: d.date().formatted(.dateTime.day()),
                               ref: .day(d), isToday: d == store.today, past: d < store.today)
                    }
                    column(title: "Inbox", subtitle: "", ref: .inbox, isToday: false, past: false).frame(width: 130)
                }
                .id(anchor)
                .transition(.opacity)
            }
        }
    }

    private func go(_ week: Int) { Motion.animate(Motion.page) { anchor = week } }

    func column(title: String, subtitle: String, ref: DayRef, isToday: Bool, past: Bool) -> some View {
        let tasks = store.engine.tasks(on: ref)
        let key = ref.key?.raw ?? "inbox"
        return VStack(alignment: .leading, spacing: 5) {
            // Day, date and count each keep one line at their natural width; a Spacer would otherwise be offered
            // a share of the row and squeeze the day name into two lines ("MO" / "N").
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(isToday ? Theme.accent : Theme.secondary)
                    .lineLimit(1).fixedSize()
                Text(subtitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(isToday ? Theme.accent : Theme.tertiary)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                if !tasks.isEmpty {
                    Text("\(tasks.filter(\.done).count)/\(tasks.count)").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            WeekDayList(tasks: tasks, ref: ref, past: past)
            // Pinned under the list, so a busy day never scrolls its Add away.
            if !past { MiniComposer(ref: ref) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(target == key ? Theme.accent.opacity(0.16) : (isToday ? Color.white.opacity(0.08) : Theme.card)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isToday ? Theme.accent.opacity(0.4) : Theme.cardStroke))
        .opacity(past ? 0.6 : 1)
        .onDrop(of: [.plainText], isTargeted: Binding(get: { target == key }, set: { target = $0 ? key : (target == key ? nil : target) })) { items in
            guard !past else { return false }
            items.first?.loadObject(ofClass: NSString.self) { s, _ in
                guard let s = s as? String, let id = UUID(uuidString: s) else { return }
                Task { @MainActor in
                    guard let t = store.planner.tasks.first(where: { $0.id == id }) else { return }
                    store.apply { try $0.move(id.uuidString, from: t.day.map { .day($0) } ?? .inbox, to: ref) }
                }
            }
            return true
        }
    }
}

/// One day's chips. When they overflow, the list fades out at the bottom and a quiet "+N more" says how many
/// chips sit below the fold; scrolling to the end clears both.
private struct WeekDayList: View {
    let tasks: [PlanTask]
    let ref: DayRef
    let past: Bool
    @State private var bottoms: [UUID: CGFloat] = [:]
    @State private var viewport: CGFloat = 0
    private static let space = "week-day-list"
    private static let fade: CGFloat = 22

    var body: some View {
        let hidden = WeekColumnLayout.hiddenBelow(chipBottoms: tasks.compactMap { bottoms[$0.id].map { Double($0) } },
                                                  viewport: Double(viewport))
        VStack(alignment: .leading, spacing: 3) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks) { t in
                        WeekChip(task: t, past: past)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChipBottoms.self, value: [t.id: g.frame(in: .named(Self.space)).maxY])
                            })
                            .onDrag { NSItemProvider(object: t.id.uuidString as NSString) }
                            .transition(.opacity)
                    }
                    if tasks.isEmpty {
                        EmptyStateView(past ? "No plans" : ref == .inbox ? "For later" : "Open day",
                                       symbol: ref == .inbox ? "tray" : "calendar",
                                       compact: true)
                    }
                }
                .motion(Motion.row, value: tasks.map(\.id))
            }
            .coordinateSpace(.named(Self.space))
            .scrollIndicators(.never)
            .onPreferenceChange(ChipBottoms.self) { bottoms = $0 }
            .background(GeometryReader { g in
                Color.clear.onAppear { viewport = g.size.height }.onChange(of: g.size.height) { _, h in viewport = h }
            })
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, hidden > 0 ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
            if let more = WeekColumnLayout.overflowLabel(hidden: hidden) {
                Text(more).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("\(hidden) more \(hidden == 1 ? "task" : "tasks") below")
                    .transition(.opacity)
            }
        }
        .motion(Motion.row, value: hidden > 0)
    }

    private struct ChipBottoms: PreferenceKey {
        static let defaultValue: [UUID: CGFloat] = [:]
        static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }
}

struct WeekChip: View {
    let task: PlanTask
    let past: Bool
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var titleWidth: CGFloat = 0

    var body: some View {
        let fit = WeekColumnLayout.titleFit(widestWord: Self.widestWord(task.title, repeating: task.repeatRule != nil),
                                            available: Double(titleWidth) - 1)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(task.done ? Theme.done : (task.priority == .none ? Theme.tertiary : Theme.priority(task.priority))).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            title(size: fit.size)
                .lineLimit(fit.lines).truncationMode(.tail)
                // The title takes the whole row: it wraps only between words, and a word wider than the row
                // steps the type down (see `WeekColumnLayout.titleFit`) rather than breaking inside the word.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.onAppear { titleWidth = g.size.width }.onChange(of: g.size.width) { _, w in titleWidth = w }
                })
                .layoutPriority(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.repeatRule.map { "\(task.title), repeats \($0.description)" } ?? task.title)
        .onTapGesture(count: 2) { model.detailsTaskID = task.id }
        .help(WeekColumnLayout.chipHelp(title: task.title, past: past))
    }

    /// The title, led by the small repeat glyph the Today row uses. Inline, the glyph flows with the first line
    /// instead of holding a column of its own beside every line of the title.
    private func title(size: Double) -> Text {
        let words = Text(task.title).font(.system(size: CGFloat(size)))
            .strikethrough(task.done).foregroundStyle(task.done ? Theme.tertiary : Theme.text)
        guard task.repeatRule != nil else { return words }
        let glyph = Text(Image(systemName: "repeat")).font(.system(size: CGFloat(size) - 2, weight: .semibold)).foregroundStyle(Theme.secondary)
        return glyph + Text(" ") + words
    }

    /// Width of the title's widest word at the regular chip size; the first word also carries the repeat glyph.
    private static func widestWord(_ title: String, repeating: Bool) -> Double {
        let font = NSFont.systemFont(ofSize: CGFloat(WeekColumnLayout.titleSize))
        let glyph: CGFloat = repeating ? 14 : 0
        var widest: CGFloat = 0
        for (i, word) in title.split(whereSeparator: { $0.isWhitespace }).enumerated() {
            let w = (String(word) as NSString).size(withAttributes: [.font: font]).width + (i == 0 ? glyph : 0)
            widest = max(widest, w)
        }
        return Double(widest)
    }
}

struct MiniComposer: View {
    let ref: DayRef
    @EnvironmentObject var store: PlannerStore
    @State private var text = ""
    var body: some View {
        TextField(ref == .inbox ? "Add to Inbox" : "Add a task", text: $text)
            .textFieldStyle(.plain).font(.system(size: 10.5))
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
            .onSubmit {
                guard !text.isEmpty else { return }
                if store.apply({ try $0.addTasks([text], on: ref) }) != nil { text = "" }
            }
    }
}

/// Clips: a clothesline of screenshots, recordings and copied things.
struct ClipsPage: View {
    @EnvironmentObject var services: Services
    var body: some View { ClipsBody(clips: services.clips) }
}

private struct ClipsBody: View {
    @ObservedObject var clips: ClipsService
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading("Clips", symbol: "paperclip")
                Spacer()
                Toggle("Catch screenshots", isOn: Binding(get: { store.prefs.catchScreenshots }, set: { v in store.updatePrefs { $0.catchScreenshots = v } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                Toggle("Catch copies", isOn: Binding(get: { store.prefs.catchCopies }, set: { v in store.updatePrefs { $0.catchCopies = v } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                if !clips.clips.isEmpty { Button("Clear") { clips.clearUnpinned() }.buttonStyle(PillStyle()) }
            }
            ZStack(alignment: .top) {
                // The rope.
                if !clips.clips.isEmpty {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 14))
                        p.addQuadCurve(to: CGPoint(x: 780, y: 14), control: CGPoint(x: 390, y: 34))
                    }
                    .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(height: 40)
                }

                if clips.clips.isEmpty {
                    EmptyStateView("Drop something here to keep it close.", symbol: "paperclip")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(clips.clips.enumerated()), id: \.element.id) { i, c in
                                ClipCard(clip: c, clips: clips).rotationEffect(.degrees(i.isMultiple(of: 2) ? -2 : 2), anchor: .top)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 16)
                    }.scrollIndicators(.never)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !clips.clips.isEmpty {
                Text("Click: copy · Double-click: open · Drag: move or share").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
        .card()
    }
}

private struct ClipCard: View {
    let clip: ClipsService.Clip
    let clips: ClipsService
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Clothespin.
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 8, height: 18).offset(y: 6).zIndex(1)
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let img = clip.thumbnail {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else if case .text(let s) = clip.content {
                        Text(s).font(.system(size: 10.5)).foregroundStyle(.black.opacity(0.8)).padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        Image(systemName: "doc").font(.system(size: 22)).foregroundStyle(.black.opacity(0.4))
                    }
                }
                .frame(width: 132, height: 92).clipped()
                .background(Color.white.opacity(0.92))
                HStack(spacing: 4) {
                    Text(copied ? "Copied" : clip.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                        .foregroundStyle(copied ? Theme.accent : .black.opacity(0.7))
                    Spacer(minLength: 0)
                    if clip.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.black.opacity(0.6)) }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 4)
        }
        .onTapGesture(count: 2) { clips.open(clip) }
        .onTapGesture {
            clips.copy(clip)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .onDrag {
            switch clip.content {
            case .file(let u): return NSItemProvider(contentsOf: u) ?? NSItemProvider()
            case .text(let s): return NSItemProvider(object: s as NSString)
            case .image(let d): return NSItemProvider(item: d as NSData, typeIdentifier: UTType.png.identifier)
            }
        }
        .contextMenu {
            Button(clip.pinned ? "Unpin" : "Keep this clip when the shelf fills up") { clips.togglePin(clip.id) }
            Button("Copy") { clips.copy(clip) }
            if clips.clipURL(clip) != nil {
                Button("Open") { clips.open(clip) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clips.clipURL(clip)!]) }
            }
            Divider()
            Button("Remove", role: .destructive) { clips.remove(clip.id) }
        }
    }
}
