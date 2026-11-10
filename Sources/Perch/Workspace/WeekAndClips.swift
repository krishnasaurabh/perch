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
            GeometryReader { geometry in
                // Give a busy day room for ordinary titles. Below the useful minimum, pan the week
                // horizontally instead of compressing every title; each day's Add stays outside its list.
                let widths = days.map { day -> CGFloat in
                    let count = store.engine.tasks(on: .day(day)).count
                    return count > 4 ? 180 : (count > 0 ? 104 : 88)
                }
                let minimum = widths.reduce(118 + 7 * 6, +)
                let extra = max(0, geometry.size.width - minimum) / 8
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(days.enumerated()), id: \.element) { index, d in
                            column(title: d.date().formatted(.dateTime.weekday(.abbreviated)), subtitle: d.date().formatted(.dateTime.day()),
                                   ref: .day(d), isToday: d == store.today, past: d < store.today)
                                .frame(width: widths[index] + extra)
                        }
                        column(title: "Inbox", subtitle: "", ref: .inbox, isToday: false, past: false)
                            .frame(width: 118 + extra)
                    }
                    .frame(height: geometry.size.height - 12)
                    .id(anchor)
                    .transition(.opacity)
                }
                .scrollIndicators(.visible)
            }
        }
        .showsDays(days)
    }

    private func go(_ week: Int) { Motion.animate(Motion.page) { anchor = week } }

    func column(title: String, subtitle: String, ref: DayRef, isToday: Bool, past: Bool) -> some View {
        let tasks = store.engine.tasks(on: ref)
        let key = ref.key?.raw ?? "inbox"
        return VStack(alignment: .leading, spacing: 5) {
            // Day, date and count each keep one line at their natural width; a Spacer would otherwise be offered
            // a share of the row and squeeze the day name into two lines ("MO" / "N").
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6)
                        .foregroundStyle(isToday ? Theme.accent : Theme.secondary)
                        .lineLimit(1).fixedSize()
                    Text(subtitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(isToday ? Theme.accent : Theme.tertiary)
                        .lineLimit(1).fixedSize()
                }
                // A dedicated line prevents the day label from squeezing or scaling the count.
                Text("\(tasks.filter(\.done).count)/\(tasks.count) done")
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("\(tasks.filter(\.done).count) of \(tasks.count) tasks complete")
            }
            WeekDayList(tasks: tasks, ref: ref, past: past)
            // Pinned under the list, so a busy day never scrolls its Add away.
            if !past { MiniComposer(ref: ref) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(target == key ? Theme.accent.opacity(0.16) : (isToday ? Color.white.opacity(0.08) : Theme.card)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
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

/// One day's chips. When they overflow, the list fades out at the bottom and "+N more" says how many
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
                Text(more).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(task.done ? Theme.done : (task.priority == .none ? Theme.tertiary : Theme.priority(task.priority))).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            title(size: WeekColumnLayout.titleSize)
                .lineLimit(2).truncationMode(.tail)
                // Never shrink text to make a day fit. Width belongs to the column, not the font.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

}

struct MiniComposer: View {
    let ref: DayRef
    @EnvironmentObject var store: PlannerStore
    @State private var text = ""
    var body: some View {
        let prompt = ref == .inbox ? "Add to Inbox" : "Add a task"
        // Prompt drawn by us, as in TaskComposer (review F02): AppKit's own placeholder colour measures 3.9:1 on
        // the dark tile. `Theme.secondary` (dark: white 62 %) clears 4.5:1 there and stays dimmer than real text.
        TextField("", text: $text)
            .textFieldStyle(.plain).font(.system(size: 10.5))
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(prompt)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.inputStroke, lineWidth: 1))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading("Clips", symbol: "paperclip")
                Spacer()
                Toggle("Catch screenshots", isOn: Binding(get: { store.prefs.catchScreenshots }, set: { v in store.updatePrefs { $0.catchScreenshots = v } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                Toggle("Catch copies", isOn: Binding(get: { store.prefs.catchCopies }, set: { v in store.updatePrefs { $0.catchCopies = v } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                Button("Let go of all") { clips.sweep() }.buttonStyle(PillStyle())
                    .opacity(clips.clips.contains(where: { !$0.pinned }) ? 1 : 0)
                    .disabled(!clips.clips.contains(where: { !$0.pinned }))
                    .accessibilityHidden(!clips.clips.contains(where: { !$0.pinned }))
                    .help("Remove unpinned clips. Undo is available for 5 seconds.")
            }
            ZStack(alignment: .top) {
                // Keep the bounded rope geometry; its stroke uses the shared accessibility token below.
                ClipsRope()
                Group {
                    if clips.clips.isEmpty {
                        // Sits just under the rope's lowest point, as if hanging from it.
                        EmptyStateView("Drop something here to keep it close.", symbol: "paperclip")
                            .padding(.top, ClipsLineLayout.emptyMessageTop)
                            .transition(.opacity)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(clips.clips.enumerated()), id: \.element.id) { i, c in
                                    ClipCard(clip: c, clips: clips).rotationEffect(.degrees(i.isMultiple(of: 2) ? -2 : 2), anchor: .top)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 16).padding(.top, 16)
                            .motion(Motion.row, value: clips.clips.map(\.id))
                        }.scrollIndicators(.never)
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                if let banner = clips.letGoBanner {
                    LetGoToast(banner: banner) { clips.undoLetGo() }
                        .transition(.opacity)
                        .padding(.bottom, 4)
                }
            }
            HStack(spacing: 6) {
                if ClipsLineLayout.showsGestureHints(clipCount: clips.clips.count) {
                    Text("Click: copy · Double-click: open · Drag: move or share").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                FolderWatchStatus(state: clips.folderWatch)
            }
        }
        // Populated <-> empty crossfades in place, with the page-switch timing (Reduce Motion aware).
        .motion(Motion.page, value: clips.clips.isEmpty)
        .card()
    }
}

/// The line clips hang on. Its width comes from the space it is given (the card's content box), inset at both ends.
private struct ClipsRope: View {
    var body: some View {
        GeometryReader { g in
            if let rope = ClipsLineLayout.rope(width: g.size.width) {
                Path { p in
                    p.move(to: CGPoint(x: rope.start.x, y: rope.start.y))
                    p.addQuadCurve(to: CGPoint(x: rope.end.x, y: rope.end.y), control: CGPoint(x: rope.control.x, y: rope.control.y))
                }
                // Dedicated boundary ink: do not attenuate a text token a second time.
                .stroke(Theme.rope, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(height: ClipsLineLayout.bandHeight)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "Let go of 2 clips · Undo", with the 5-second window draining underneath.
private struct LetGoToast: View {
    let banner: ClipsService.LetGoBanner
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(banner.count == 1 ? "Let go of 1 clip" : "Let go of \(banner.count) clips")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
            Button("Undo", action: undo).buttonStyle(PillStyle(prominent: true))
                .accessibilityHint("Puts the clips back on the line")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(Color(white: 0.16)))
        .overlay(Capsule().strokeBorder(Theme.cardStroke))
        .overlay(alignment: .bottom) {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let left = max(0, banner.deadline.timeIntervalSince(ctx.date)) / LetGoLedger<ClipsService.Clip>.window
                GeometryReader { g in
                    Capsule().fill(Theme.accent.opacity(0.7)).frame(width: g.size.width * left, height: 2)
                }
                .frame(height: 2).padding(.horizontal, 16).padding(.bottom, 3)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .id(banner.token)
    }
}

/// Whether the screenshot folder itself is watched, or only Spotlight is catching screenshots.
private struct FolderWatchStatus: View {
    let state: ClipsService.FolderWatch

    var body: some View {
        switch state {
        case .off:
            EmptyView()
        case .watching(let url):
            Label("Watching \(url.lastPathComponent)", systemImage: "eye")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                .help("New screenshots in \(url.path) hang here right away.")
        case .unreadable(let url):
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
            } label: {
                Label("Can't read \(url.lastPathComponent): using Spotlight only", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Allow Perch to access \(url.path) in Privacy & Security › Files and Folders, so screenshots appear instantly.")
        }
    }
}

/// A bounded, readable preview even while Quick Look is unavailable or returns blank paper.
struct ClipPreview: View {
    let content: ClipsService.Clip.Content
    let thumbnail: NSImage?
    @State private var fileText: String?

    var body: some View {
        Group {
            if let image = thumbnail, usableThumbnail(image) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let text = previewText {
                Text(text).font(.system(size: 10.5)).foregroundStyle(.black.opacity(0.8))
                    .lineLimit(6).padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: fileSymbol).font(.system(size: 22))
                    Text(filename).font(.system(size: 9.5, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.black.opacity(0.65)).padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 132, height: 92).clipped()
        .background(Color.white.opacity(0.92))
        .task(id: content) {
            fileText = nil
            guard case .file(let url) = content else { return }
            // File metadata and the bounded read stay off the UI thread (including slow external volumes).
            let text = await Task.detached(priority: .utility) { Self.readText(at: url) }.value
            guard !Task.isCancelled else { return }
            fileText = text
        }
    }

    private var previewText: String? {
        let text: String?
        switch content {
        case .text(let value): text = value
        case .file: text = fileText
        case .image: text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(4096))
    }

    private var filename: String {
        if case .file(let url) = content { return url.lastPathComponent }
        return "Empty clip"
    }

    private var fileSymbol: String {
        guard case .file(let url) = content, let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .plainText) { return "doc.text" }
        return "doc"
    }

    /// Only ordinary plain-text files, at most 64 KiB, decoded strictly as UTF-8.
    /// Recheck the actual bounded read so a file growing after the metadata check cannot bypass the cap.
    nonisolated static func readText(at url: URL) -> String? {
        let limit = 64 * 1024
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit,
              values.contentType?.conforms(to: .plainText) == true,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { return nil }
        return String(text.prefix(4096))
    }

    private func usableThumbnail(_ image: NSImage) -> Bool {
        guard case .file = content else { return true }
        // Quick Look can return a white sheet with only a border/shadow. Inspect its interior,
        // not those edges, so it cannot suppress the text or intentional file placeholder.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let interior = cg.cropping(to: CGRect(x: CGFloat(cg.width) * 0.15, y: CGFloat(cg.height) * 0.15,
                                                   width: CGFloat(cg.width) * 0.7, height: CGFloat(cg.height) * 0.7)) else { return false }
        var pixels = [UInt8](repeating: 255, count: 16 * 16 * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            context.draw(interior, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return false }
        let luminance = stride(from: 0, to: pixels.count, by: 4).map { i in
            (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
        }
        return (luminance.max() ?? 0) - (luminance.min() ?? 0) > 24
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
                ClipPreview(content: clip.content, thumbnail: clip.thumbnail)
                HStack(spacing: 4) {
                    Text(copied ? "Copied" : clip.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                        .foregroundStyle(copied ? Theme.accent : .black.opacity(0.7))
                    Spacer(minLength: 0)
                    if clip.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.black.opacity(0.6)) }
                }
                .frame(width: 132, alignment: .leading)
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
            Button("Let go", role: .destructive) { clips.letGo(clip.id) }
        }
    }
}
