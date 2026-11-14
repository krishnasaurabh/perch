import PerchUI
import SwiftUI

/// The schedule lane replaces this stub without changing Home's column geometry.
struct YourDayCard: View {
    var body: some View {
        Card(.mint) {
            VStack(alignment: .leading, spacing: HomeLayout.gap) {
                CardHeading(AppL10n.text("Your day"))
                Spacer(minLength: .zero)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("your-day-card")
    }
}
