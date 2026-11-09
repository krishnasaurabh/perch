import AppKit
import PlannerCore
import SwiftUI

// MARK: - Color tokens

/// Perch uses a black shell and opaque pastel cards with dark ink,
/// white only on black, one warm accent, no strokes and no shadows.
///
/// Ink tokens are two-faced. They resolve against the SwiftUI `colorScheme` of the subtree that draws them:
/// `.dark` means "on the black shell or a dark tile" (white ink, orange accent), `.light` means "on a pastel card"
/// (near-black ink, monochrome accent). `CardSurface` sets the scheme from its `CardTone`, so a view inside a card
/// picks the right ink without knowing where it sits.
///
/// WCAG contrast against the measured surfaces (sage / lavender / black):
/// text 6.3 / 5.8 / 17.6, secondary 5.0 / 4.7 / 7.8, tertiary 4.0 / 3.7 / 4.4 (hints and finished rows only).
enum Theme {
    /// The camera housing and the expanded shell. Black in every state.
    static let notchBlack = Color.black

    // Surfaces: opaque, flat on the shell.
    /// Task card fill: `#879E8D`.
    static let sage = Color(hex: "#879E8D")
    /// Timer, agenda and chart card fill: `#938EAB`.
    static let lavender = Color(hex: "#938EAB")
    /// Dark tile for white ink (week columns, clips, banners): `#1D1D1D`.
    static let tile = Color(hex: "#1D1D1D")
    /// Highlighted dark tile (today's week column): `#303030`.
    static let tileStrong = Color(hex: "#303030")
    static let card = tile
    /// Cards carry no stroke; kept for callers that still outline a tile.
    static let cardStroke = Color.clear

    static let text = Color.dynamic(light: (0x000000, 0.90), dark: (0xFFFFFF, 0.92))
    static let secondary = Color.dynamic(light: (0x000000, 0.74), dark: (0xFFFFFF, 0.62))
    static let tertiary = Color.dynamic(light: (0x000000, 0.62), dark: (0xFFFFFF, 0.45))

    /// Warm accent on dark surfaces (`#F19644`); dark ink on pastel cards.
    static let accent = Color.dynamic(light: (0x1A1E20, 1), dark: (0xF19644, 1))
    /// The mascot keeps its color on any surface.
    static let owl = Color(hex: "#F19644")
    /// Label on a prominent fill.
    static let onAccent = Color.dynamic(light: (0xFFFFFF, 1), dark: (0x1A1A1A, 1))
    /// Prominent button fill: `#6C687E` on lavender (black 30 % over the card), the accent on black.
    static let prominent = Color.dynamic(light: (0x000000, 0.30), dark: (0xF19644, 1))
    static let done = Color.dynamic(light: (0x17401F, 1), dark: (0x7AD98F, 1))
    static let danger = Color.dynamic(light: (0x5C110B, 1), dark: (0xFF6B6B, 1))

    /// Quiet control fill for segment tracks and icon buttons: white 12.5 % on black.
    static let fill = Color.dynamic(light: (0xFFFFFF, 0.20), dark: (0xFFFFFF, 0.125))
    /// Selected segment, hovered control. Selected pill on sage measured `#9DADA1`.
    static let fillStrong = Color.dynamic(light: (0xFFFFFF, 0.32), dark: (0xFFFFFF, 0.20))
    /// The capture field: a slightly darker bar on a card.
    static let inputFill = Color.dynamic(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.08))
    static let inputFillFocused = Color.dynamic(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.12))
    /// Unlit LEDs of the dot-matrix timer.
    static let unlit = Color.dynamic(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.05))
    /// Chart: Completed is a solid fill (`#1A1E20`), Planned a translucent dark layer (`#727085` on lavender).
    static let chartCompleted = Color(hex: "#1A1E20")
    static let chartPlanned = Color.black.opacity(0.22)

    /// Priority shows in the ring and the "High" chip's weight, not a rainbow. Only High gets its own color.
    static func priority(_ p: TaskPriority) -> Color {
        switch p {
        case .high: return danger
        case .medium, .low: return secondary
        case .none: return .clear
        }
    }

    // MARK: Type (heading 14 bold, task 12.5 semibold, meta 10.5)
    static let heading = Font.system(size: 14, weight: .bold)
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let body = Font.system(size: 12.5)
    static let meta = Font.system(size: 10.5, weight: .medium)
    static let label = Font.system(size: 11, weight: .semibold)

    // MARK: Spacing (8 pt gutter, 14 pt card padding, 13 pt card radius)
    static let gutter: CGFloat = 8
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 13
    static let controlRadius: CGFloat = 8
    /// Width of the column beside Today's tasks (focus timer, agenda).
    static let sideColumn: CGFloat = 272
}

// MARK: - Motion tokens

/// Critically damped spring tokens used by Perch's interface transitions.
/// Every token is ζ = 1.0 (no overshoot). `response` is the spring period, not a settle time.
enum Motion {
    /// Notch opening: spring R 0.30, ζ 1 (95 % at ≈ 200 ms).
    static let open = Animation.spring(response: 0.30, dampingFraction: 1.0)
    /// Notch closing is nearly a snap (gone in 133–150 ms).
    static let close = Animation.spring(response: 0.20, dampingFraction: 1.0)
    /// Activity strip drop from the notch: easeInOut ≈ 0.19 s (150 ms to 95 %).
    static let activity = Animation.easeInOut(duration: 0.19)
    static let activityDismiss = Animation.spring(response: 0.20, dampingFraction: 1.0)
    /// Page switch: in-place crossfade of ≈ 170 ms. The selected tab pill snaps.
    static let page = Animation.easeOut(duration: 0.18)
    /// Row tick and insert: the row fades in place while the rows below slide up. Spring R 0.24, ζ 1 (≈ 250 ms).
    static let row = Animation.spring(response: 0.24, dampingFraction: 1.0)
    /// Immediate tick feedback: the circle fills before the row leaves.
    static let tick = Animation.spring(response: 0.16, dampingFraction: 1.0)
    /// A card entering or leaving Home (the timer starts, today's events load).
    static let card = Animation.spring(response: 0.26, dampingFraction: 1.0)
    /// One Insights bar growing from the baseline: spring R 0.30, ζ 1 (≈ 200 ms), staggered 130 ms left to right.
    static let bar = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let barStagger = 0.13
    /// Reduce Motion stand-in for all of the above: a short fade, no travel.
    static let reduced = Animation.easeInOut(duration: 0.15)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func resolved(_ a: Animation) -> Animation { reduceMotion ? reduced : a }

    /// `withAnimation` that honors Reduce Motion.
    @discardableResult
    static func animate<R>(_ a: Animation, _ body: () throws -> R) rethrows -> R {
        try withAnimation(resolved(a), body)
    }
}

extension View {
    /// `.animation(_:value:)` that honors Reduce Motion.
    func motion<V: Equatable>(_ a: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: a, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View { content.animation(reduce ? Motion.reduced : animation, value: value) }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8E8CF5
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// A color that follows the appearance, and so the SwiftUI `colorScheme`, of whatever draws it.
    static func dynamic(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let (v, a) = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: a)
        })
    }
}

// MARK: - Surfaces

/// A card's job decides its color: tasks are sage, time and charts lavender, everything else a dark tile.
enum CardTone {
    case tasks, timer, tile
    var fill: Color {
        switch self {
        case .tasks: return Theme.sage
        case .timer: return Theme.lavender
        case .tile: return Theme.tile
        }
    }
    /// Pastel cards carry dark ink, tiles white ink.
    var scheme: ColorScheme { self == .tile ? .dark : .light }
}

/// Padded, full-width, flat. Height follows the content; greedy content (a ScrollView, a Spacer) fills the slot.
struct CardSurface: ViewModifier {
    var tone: CardTone = .tile
    var padding: CGFloat = Theme.cardPadding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(tone.fill))
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, tone.scheme)
    }
}

extension View {
    func card(_ tone: CardTone = .tile, padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardSurface(tone: tone, padding: padding))
    }
}

/// Sentence-case card title ("Today's tasks"). Text only, without an icon.
struct CardHeading: View {
    let title: String
    var symbol: String?
    var trailing: AnyView?
    init(_ title: String, symbol: String? = nil, trailing: AnyView? = nil) {
        self.title = title; self.symbol = symbol; self.trailing = trailing
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.heading).foregroundStyle(Theme.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// Small segmented control for "To do / Completed" pills. Selection snaps.
struct SegmentPills<T: Hashable>: View {
    let items: [(value: T, label: String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                let on = selection == it.value
                Button { selection = it.value } label: {
                    Text(it.label)
                        .font(.system(size: 11, weight: on ? .semibold : .medium).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Theme.fillStrong : .clear))
                        .foregroundStyle(on ? Theme.text : Theme.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
        .transaction { $0.animation = nil }
    }
}

struct GlassButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = Theme.text
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(hover ? Theme.fillStrong : Theme.fill))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Small owl mark drawn in SwiftUI (the original ships a Rive animation; this is a static stand-in that blinks).
struct OwlMark: View {
    var size: CGFloat = 18
    var awake = true
    @State private var blink = false
    var body: some View {
        ZStack {
            Ellipse().fill(Theme.owl).frame(width: size, height: size * 0.92)
            HStack(spacing: size * 0.08) {
                eye
                eye
            }
            .offset(y: -size * 0.06)
            Triangle().fill(Color.black.opacity(0.75)).frame(width: size * 0.16, height: size * 0.14).offset(y: size * 0.16)
        }
        .frame(width: size, height: size)
        .task {
            guard awake else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_500_000_000...5_500_000_000))
                withAnimation(.easeInOut(duration: 0.08)) { blink = true }
                try? await Task.sleep(nanoseconds: 120_000_000)
                withAnimation(.easeInOut(duration: 0.08)) { blink = false }
            }
        }
    }
    private var eye: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: size * 0.36, height: size * 0.36)
            Circle().fill(Color.black).frame(width: size * 0.17, height: size * 0.17)
        }
        .scaleEffect(x: 1, y: blink || !awake ? 0.12 : 1)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath(); return p
    }
}

/// Dot-matrix digits for the focus timer face.
struct DotMatrixText: View {
    let text: String
    var dot: CGFloat = 3.2
    var color: Color = Theme.accent

    static let glyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
        ":": ["0", "1", "0", "1", "0"],
    ]

    var body: some View {
        HStack(alignment: .top, spacing: dot * 1.2) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                let rows = Self.glyphs[ch] ?? ["000", "000", "000", "000", "000"]
                VStack(spacing: dot * 0.45) {
                    ForEach(0..<5, id: \.self) { r in
                        HStack(spacing: dot * 0.45) {
                            ForEach(Array(rows[r].enumerated()), id: \.offset) { _, bit in
                                Circle().fill(bit == "1" ? color : Theme.unlit).frame(width: dot, height: dot)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Wraps an action with the store's error surface.
struct ErrorBanner: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        if let e = store.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.danger)
                Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.text).lineLimit(2)
                Spacer()
                Button { store.lastError = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.14)))
            .transition(.opacity)
        }
    }
}
