import SwiftUI

/// Sentence-case card title ("Today's tasks"). Text only, without an icon.
struct CardHeading: View {
    let title: String
    var symbol: String?
    var trailing: AnyView?
    init(_ title: String, symbol: String? = nil, trailing: AnyView? = nil) {
        self.title = title; self.symbol = symbol; self.trailing = trailing
    }
    @Environment(\.designSurface) private var surface

    var body: some View {
        HStack(spacing: SurfaceMetrics.compactGap) {
            heading
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder private var heading: some View {
        if let surface {
            Text(title).perchFont(.cardTitle).foregroundStyle(Theme.foreground(.ink, on: surface))
        } else {
            Text(title).font(Theme.heading).foregroundStyle(Theme.text)
        }
    }
}
