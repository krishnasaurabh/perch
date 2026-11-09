import PlannerCore
import SwiftUI

/// Visual language: black glass that reads as part of the notch, soft cards, one accent.
enum Theme {
    static let notchBlack = Color.black
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let accent = Color(red: 1.0, green: 0.72, blue: 0.30)  // owl amber
    static let done = Color(red: 0.48, green: 0.85, blue: 0.56)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)

    static func priority(_ p: TaskPriority) -> Color {
        switch p {
        case .high: return Color(red: 1.0, green: 0.45, blue: 0.40)
        case .medium: return Color(red: 1.0, green: 0.75, blue: 0.30)
        case .low: return Color(red: 0.45, green: 0.70, blue: 1.0)
        case .none: return .clear
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8E8CF5
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct CardSurface: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View { modifier(CardSurface(padding: padding)) }
}

struct CardHeading: View {
    let title: String
    var symbol: String?
    var trailing: AnyView?
    init(_ title: String, symbol: String? = nil, trailing: AnyView? = nil) {
        self.title = title; self.symbol = symbol; self.trailing = trailing
    }
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary) }
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            trailing
        }
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
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.08)))
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
            Ellipse().fill(Theme.accent).frame(width: size, height: size * 0.92)
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
                                Circle().fill(bit == "1" ? color : Color.white.opacity(0.045)).frame(width: dot, height: dot)
                            }
                        }
                    }
                }
            }
        }
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
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
