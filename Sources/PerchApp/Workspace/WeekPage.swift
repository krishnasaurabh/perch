import AppKit
import PerchUI
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
                Text("Drop tasks onto a day, or park them in the Inbox.").font(.system(size: 10.5)).foregroundStyle(
                    Theme.tertiary)
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
                            column(
                                title: d.date().formatted(.dateTime.weekday(.abbreviated)),
                                subtitle: d.date().formatted(.dateTime.day()),
                                ref: .day(d), isToday: d == store.today, past: d < store.today
                            )
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

    }

    private func go(_ week: Int) {
        let start = store.today.adding(days: week * 7)
        store.materializeRepeats(on: (0..<7).map { start.adding(days: $0) })
        Motion.animate(Motion.page) { anchor = week }
    }

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
                    Text(subtitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                        isToday ? Theme.accent : Theme.tertiary
                    )
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
        .background(
            RoundedRectangle(cornerRadius: 12).fill(
                target == key ? Theme.accent.opacity(0.16) : (isToday ? Color.white.opacity(0.08) : Theme.card))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
        .opacity(past ? 0.6 : 1)
        .onDrop(
            of: [.plainText],
            isTargeted: Binding(get: { target == key }, set: { target = $0 ? key : (target == key ? nil : target) })
        ) { items in
            guard !past else { return false }
            items.first?.loadObject(ofClass: NSString.self) { s, _ in
                guard let s = s as? String, let id = UUID(uuidString: s) else { return }
                Task { @MainActor in
                    guard let t = store.planner.tasks.first(where: { $0.id == id }) else { return }
                    store.apply { try $0.move(id, from: t.day.map { .day($0) } ?? .inbox, to: ref) }
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
        let hidden = WeekColumnLayout.hiddenBelow(
            chipBottoms: tasks.compactMap { bottoms[$0.id].map { Double($0) } },
            viewport: Double(viewport))
        VStack(alignment: .leading, spacing: 3) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks) { t in
                        WeekChip(task: t, past: past)
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: ChipBottoms.self, value: [t.id: g.frame(in: .named(Self.space)).maxY])
                                }
                            )
                            .onDrag { NSItemProvider(object: t.id.uuidString as NSString) }
                            .transition(.opacity)
                    }
                    if tasks.isEmpty {
                        EmptyStateView(
                            past ? "No plans" : ref == .inbox ? "For later" : "Open day",
                            symbol: ref == .inbox ? "tray" : "calendar",
                            compact: true)
                    }
                }
                .motion(Motion.row, value: tasks.map(\.id))
            }
            .coordinateSpace(.named(Self.space))
            .scrollIndicators(.never)
            .onPreferenceChange(ChipBottoms.self) { bottoms = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.onAppear { viewport = g.size.height }.onChange(of: g.size.height) { _, h in viewport = h
                    }
                }
            )
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
            Circle().fill(
                task.done ? Theme.done : (task.priority == .none ? Theme.tertiary : Theme.priority(task.priority))
            ).frame(width: 6, height: 6)
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
        let glyph = Text(Image(systemName: "repeat")).font(.system(size: CGFloat(size) - 2, weight: .semibold))
            .foregroundStyle(Theme.secondary)
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
