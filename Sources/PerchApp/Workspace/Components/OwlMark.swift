import SwiftUI

/// Quiet, static owl mark. No idle timer or repeating animation in either motion mode.
struct OwlMark: View {
    var size: CGFloat = 18
    var awake = true
    var body: some View {
        ZStack {
            Ellipse().fill(Theme.owl).frame(width: size, height: size * 0.92)
            HStack(spacing: size * 0.08) {
                eye
                eye
            }
            .offset(y: -size * 0.06)
            Triangle().fill(Color.black.opacity(0.75)).frame(width: size * 0.16, height: size * 0.14).offset(
                y: size * 0.16)
        }
        .frame(width: size, height: size)
    }
    private var eye: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: size * 0.36, height: size * 0.36)
            Circle().fill(Color.black).frame(width: size * 0.17, height: size * 0.17)
        }
        .scaleEffect(x: 1, y: awake ? 1 : 0.12)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY));
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath(); return p
    }
}
