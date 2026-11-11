import SwiftUI

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
            Text(title).font(Theme.heading).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}
