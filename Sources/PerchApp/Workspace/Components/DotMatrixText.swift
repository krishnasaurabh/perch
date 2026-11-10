import SwiftUI

/// Dot-matrix digits for the focus timer face.
struct DotMatrixText: View {
    let text: String
    var dot: CGFloat = 3.2
    var color: Color = Theme.accent
    /// Off dots. `.clear` draws only the lit dots (the closed timer pill).
    var unlit: Color = Theme.unlit

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
                                Circle().fill(bit == "1" ? color : unlit).frame(width: dot, height: dot)
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
