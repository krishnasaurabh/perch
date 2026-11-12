import SwiftUI

/// Quiet guidance in an empty card. The symbol is decorative; VoiceOver reads the copy once.
struct EmptyStateView: View {
    let message: String
    let symbol: String
    var compact = false

    init(_ message: String, symbol: String, compact: Bool = false) {
        self.message = message
        self.symbol = symbol
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 13, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            Text(AppL10n.text(message))
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 6 : 12)
        .accessibilityElement(children: .combine)
    }
}
