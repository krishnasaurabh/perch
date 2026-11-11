import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class DateFieldEditorTests: XCTestCase {
    @MainActor private func editor(_ draft: DateFieldDraft, actions: Bool) -> some View {
        DateFieldEditor(
            field: "Deadline", draft: .constant(draft),
            onCommit: actions ? { _ in } : nil, onCancel: actions ? {} : nil
        )
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    /// Every state stays inside a narrow column instead of clipping its controls.
    @MainActor func testEditorFitsNarrowWidthsInEveryState() {
        var invalid = DateFieldDraft(original: "2026-11-20", today: "2026-11-09", requirement: .required)
        invalid.type("not a day")
        var cleared = DateFieldDraft(original: "2026-11-20", today: "2026-11-09", requirement: .required)
        cleared.clear()
        let states = [
            DateFieldDraft(original: nil, today: "2026-11-09"),
            DateFieldDraft(original: "2026-11-20", today: "2026-11-09"),
            DateFieldDraft(original: "2026-10-01", today: "2026-11-09"),
            invalid, cleared,
        ]
        for width in [220.0, 320, 460] {
            for draft in states {
                for actions in [true, false] {
                    let host = NSHostingController(rootView: editor(draft, actions: actions))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                    XCTAssertLessThanOrEqual(size.width, width, "\(draft.entry) actions=\(actions) at \(width)")
                    XCTAssertGreaterThan(size.height, 0)
                }
            }
        }
    }
}
