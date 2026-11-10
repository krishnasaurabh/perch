import SwiftUI

/// Keeps errors visible until the store resolves them, including read-only recovery warnings.
struct ErrorBanner: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        if let e = store.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.danger)
                Text(e.message).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.14)))
            .transition(.opacity)
        }
    }
}
