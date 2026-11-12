@testable import PerchUI
@testable import PlannerCore
import XCTest

final class LocalizationTests: XCTestCase {
    private let pseudo = Locale(identifier: "zz")

    func testEnglishAndPseudoPluralPresentationKeepsPlaceholdersAndAccessibility() throws {
        XCTAssertEqual(PerchL10n.tasks(count: 1, locale: Locale(identifier: "en")), "1 task")
        XCTAssertEqual(PerchL10n.tasks(count: 2, locale: Locale(identifier: "en")), "2 tasks")
        XCTAssertEqual(PerchL10n.tasks(count: 1, locale: pseudo), "⟦1 tàsk ·~⟧")
        XCTAssertEqual(PerchL10n.tasks(count: 2, locale: pseudo), "⟦2 tàsks ·~⟧")

        var planner = Planner()
        planner.preferences.notchTaskCount = true
        planner.tasks = [PlanTask(title: "Private fixture title", day: "2026-11-09")]
        let glance = try XCTUnwrap(
            NotchGlancePresentation(
                planner: planner, today: "2026-11-09", locale: pseudo))
        XCTAssertEqual(glance.text, "⟦1 tàsk ·~⟧")
        XCTAssertTrue(glance.accessibilityLabel.hasPrefix("⟦1 ünfïnïshëd tàsk"))
        XCTAssertFalse(glance.accessibilityLabel.contains("Private fixture"))
    }

    func testPseudoExpansionRequiresWrappingAndDynamicTypeScalesLayoutBudget() {
        let english = PerchL10n.text("Choose a date.", locale: Locale(identifier: "en"))
        let expanded = PerchL10n.text("Choose a date.", locale: pseudo)
        XCTAssertGreaterThan(expanded.count, english.count)
        XCTAssertTrue(LocalizedLayout.requiresWrappedContent(english: english, presented: expanded))
        XCTAssertEqual(LocalizedLayout.fittingWidth(base: 100, dynamicTypeScale: 1.5), 150)
        XCTAssertEqual(LocalizedLayout.fittingWidth(base: 100, dynamicTypeScale: 1, expansion: 1.4), 140)
    }

    func testRTLAndNumberPresentationDoNotChangeStoredDayKeys() {
        XCTAssertEqual(LocalizedLayout.direction(for: Locale(identifier: "ar-SA")), .rightToLeft)
        XCTAssertEqual(LocalizedLayout.direction(for: Locale(identifier: "he")), .rightToLeft)
        XCTAssertEqual(LocalizedLayout.direction(for: Locale(identifier: "en")), .leftToRight)
        XCTAssertEqual(PerchL10n.number(1_000_000, locale: Locale(identifier: "hi-IN")), "10,00,000")
        let day: DayKey = "2026-11-09"
        XCTAssertEqual(day.raw, "2026-11-09")
    }

    func testRepeatSummaryAndPreviewAreLocalizedWithoutChangingSchedule() {
        let day: DayKey = "2026-11-09"
        let draft = RepeatPickerDraft(
            original: TaskRepeat(unit: .day, interval: 2), anchor: day,
            calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(draft.summary(locale: Locale(identifier: "en")), "Every 2 days")
        XCTAssertEqual(draft.summary(locale: pseudo), "⟦Ëvëry 2 dàys ·~⟧")
        let preview = draft.preview(count: 2)
        XCTAssertEqual(
            RepeatPickerDraft.previewText(preview, anchor: day, locale: Locale(identifier: "en")),
            "Next: Wed, Nov 11 · Fri, Nov 13")
        let arabic = RepeatPickerDraft.previewText(preview, anchor: day, locale: Locale(identifier: "ar"))
        XCTAssertNotNil(arabic)
        XCTAssertNotEqual(arabic, "Next: Wed, Nov 11 · Fri, Nov 13")
        guard case .scheduled(let days) = preview else { return XCTFail("scheduled preview missing") }
        XCTAssertEqual(days, ["2026-11-11", "2026-11-13"])
    }

    func testFormattingWithoutLocaleUsesCurrentLocaleForNumbers() {
        let value = 1234
        XCTAssertEqual(
            PerchL10n.format("%lld min", value),
            String(format: "%lld min", locale: Locale.current, arguments: [value]))
        XCTAssertEqual(
            PerchL10n.format("%.1f", 1234.5),
            String(format: "%.1f", locale: Locale.current, arguments: [1234.5]))
    }

    func testFormattingUsesExplicitNonUSLocale() {
        let locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(
            PerchL10n.format("%.1f", locale: locale, 1234.5),
            String(format: "%.1f", locale: locale, arguments: [1234.5]))
        XCTAssertTrue(PerchL10n.format("%.1f", locale: locale, 1234.5).contains(",5"))
    }

    func testWeekDatesFollowLocaleOrderWithoutChangingGregorianDay() throws {
        let day: DayKey = "2026-11-09"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let originalDate = day.date(calendar: calendar)
        let british = Locale(identifier: "en_GB")
        let american = Locale(identifier: "en_US")
        XCTAssertEqual(
            WeekColumnLayout.dateLabel(day, template: "MMMd", calendar: calendar, locale: british), "9 Nov")
        XCTAssertEqual(
            WeekColumnLayout.dateLabel(day, template: "yMMMd", calendar: calendar, locale: british), "9 Nov 2026")
        XCTAssertEqual(
            WeekColumnLayout.dateLabel(day, template: "MMMd", calendar: calendar, locale: american), "Nov 9")
        XCTAssertEqual(
            WeekColumnLayout.dateLabel(day, template: "EEE", calendar: calendar, locale: british), "Mon")
        XCTAssertEqual(day.date(calendar: calendar), originalDate)
        XCTAssertEqual(day.raw, "2026-11-09")
        XCTAssertEqual(String(data: try JSONEncoder().encode(day), encoding: .utf8), "\"2026-11-09\"")
    }

    func testValidationAndErrorsUseCatalogEntries() {
        let required = PerchL10n.text("Choose a date.", locale: pseudo)
        XCTAssertEqual(required, "⟦Chöösë à dàtë. ·~⟧")
        XCTAssertEqual(
            PerchL10n.format("Not a date: %@", locale: pseudo, "tomorrow-ish"),
            "⟦Nöt à dàtë: tomorrow-ish ·~⟧")
        XCTAssertEqual(
            PerchL10n.format("Reminder for %@.", locale: pseudo, "Water plants"),
            "⟦Rëmïndër för Water plants. ·~⟧")
    }
}
