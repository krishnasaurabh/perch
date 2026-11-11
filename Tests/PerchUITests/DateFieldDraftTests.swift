import Foundation
import PlannerCore
import PlannerTestSupport
import XCTest

@testable import PerchUI

final class DateFieldDraftTests: XCTestCase {
    private let today: DayKey = "2026-11-09"
    private var calendar: Calendar { Fixture.calendar }

    private func draft(
        _ original: DayKey?, required: Bool = false, past: DateFieldDraft.PastDayPolicy = .warn
    ) -> DateFieldDraft {
        DateFieldDraft(
            original: original, today: today, requirement: required ? .required : .optional, pastDays: past)
    }

    // MARK: Valid input

    func testSelectingADayFromThePickerCommitsThatDay() throws {
        var d = draft(nil)
        d.select(Fixture.date("2026-11-12 00:00"), calendar: calendar)
        XCTAssertEqual(d.entry, .day("2026-11-12"))
        XCTAssertEqual(d.text, "2026-11-12")
        XCTAssertNil(d.issue)
        XCTAssertTrue(d.hasChanges)
        XCTAssertEqual(d.commit(), .set("2026-11-12"))
    }

    func testPickerDateLateInTheEveningStaysOnItsCivilDay() {
        var d = draft(nil)
        d.select(Fixture.date("2026-11-12 23:59"), calendar: calendar)
        XCTAssertEqual(d.entry, .day("2026-11-12"))
    }

    func testTypedIsoDayIsAcceptedAndTrimmed() {
        var d = draft(nil)
        d.type("  2026-12-01 ")
        XCTAssertEqual(d.entry, .day("2026-12-01"))
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(d.commit(), .set("2026-12-01"))
    }

    func testPickerDateRoundTripsThroughTheStorageCalendar() {
        let d = draft("2026-03-08")  // DST change day in the fixture zone.
        let shown = d.pickerDate(calendar: calendar)
        XCTAssertEqual(DayKey(shown, calendar: calendar), "2026-03-08")
    }

    func testUntouchedDraftCommitsUnchangedWithoutAnEdit() {
        var d = draft("2026-11-20")
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.commit(), .unchanged)
        XCTAssertEqual(d.commit()?.change.isKeep, true)
    }

    func testCommitMapsToATypedFieldChange() throws {
        var set = draft(nil)
        set.type("2026-11-30")
        guard case .set(let value)? = set.commit()?.change else { return XCTFail("Expected a set change") }
        XCTAssertEqual(value, "2026-11-30")

        var cleared = draft("2026-11-30")
        cleared.clear()
        guard case .set(let none)? = cleared.commit()?.change else { return XCTFail("Expected a clearing change") }
        XCTAssertNil(none)
    }

    // MARK: Invalid input

    func testUnparseableTextShowsAnInlineErrorAndBlocksCommit() {
        var d = draft("2026-11-20")
        d.type("next blursday")
        XCTAssertEqual(d.entry, .invalid("next blursday"))
        XCTAssertEqual(d.visibleIssue, .unparseable("next blursday"))
        XCTAssertEqual(d.visibleIssue?.message, "“next blursday” is not a date. Use YYYY-MM-DD.")
        XCTAssertEqual(d.visibleIssue?.severity, .error)
        XCTAssertFalse(d.canCommit)
        XCTAssertNil(d.commit())
    }

    func testImpossibleCalendarDaysAreRejectedNotNormalized() {
        for text in ["2026-02-30", "2025-02-29", "2026-13-01", "2026-11-9", "26-11-09"] {
            var d = draft(nil)
            d.type(text)
            XCTAssertEqual(d.entry, .invalid(text), text)
            XCTAssertNil(d.commit(), text)
        }
        var leap = draft(nil)
        leap.type("2028-02-29")
        XCTAssertEqual(leap.entry, .day("2028-02-29"))
    }

    func testInvalidTextKeepsTheUserTextAndDoesNotTouchTheLastValidPickerDay() {
        var d = draft("2026-11-20")
        d.type("2026-11-2")
        XCTAssertEqual(d.text, "2026-11-2")
        XCTAssertEqual(DayKey(d.pickerDate(calendar: calendar), calendar: calendar), "2026-11-20")
    }

    func testFixingInvalidTextClearsTheError() {
        var d = draft(nil)
        d.type("soon")
        XCTAssertNotNil(d.visibleIssue)
        d.type("2026-11-21")
        XCTAssertNil(d.visibleIssue)
        XCTAssertTrue(d.canCommit)
    }

    // MARK: None and cleared

    func testNoneIsAnExplicitStateWithoutADate() {
        let d = draft(nil)
        XCTAssertEqual(d.entry, .none)
        XCTAssertEqual(d.text, "")
        XCTAssertNil(d.issue)
        XCTAssertTrue(d.canCommit)
    }

    func testClearingAnOptionalDateCommitsCleared() {
        var d = draft("2026-11-20")
        d.clear()
        XCTAssertEqual(d.entry, .none)
        XCTAssertEqual(d.text, "")
        XCTAssertTrue(d.hasChanges)
        XCTAssertEqual(d.commit(), .cleared)
    }

    func testDeletingAllTypedTextMeansNoDate() {
        var d = draft("2026-11-20")
        d.type("   ")
        XCTAssertEqual(d.entry, .none)
        XCTAssertEqual(d.commit(), .cleared)
    }

    func testRequiredDateWithNoSelectionBlocksCommitWithAnInlineError() {
        var d = draft(nil, required: true)
        XCTAssertEqual(d.issue, .required)
        XCTAssertFalse(d.attempted)
        XCTAssertFalse(d.canCommit)
        XCTAssertEqual(d.visibleIssue, .required, "A disabled Apply must explain the missing required date")
        XCTAssertEqual(d.visibleIssue?.message, "Choose a date.")
        XCTAssertNil(d.commit())
        XCTAssertEqual(d.visibleIssue, .required)
    }

    func testRevertingToRequiredNoneKeepsTheDisabledCommitExplained() {
        var d = draft(nil, required: true)
        d.addSuggested()
        XCTAssertNil(d.visibleIssue)
        XCTAssertTrue(d.canCommit)
        d.revert()
        XCTAssertEqual(d.entry, .none)
        XCTAssertFalse(d.attempted)
        XCTAssertFalse(d.canCommit)
        XCTAssertEqual(d.visibleIssue, .required)
    }

    func testClearingARequiredDateShowsTheErrorImmediately() {
        var d = draft("2026-11-20", required: true)
        d.clear()
        XCTAssertEqual(d.visibleIssue, .required)
        XCTAssertFalse(d.canCommit)
        d.select(Fixture.date("2026-11-22 09:00"), calendar: calendar)
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(d.commit(), .set("2026-11-22"))
    }

    func testAddingFromNoneSuggestsTheOriginalOrTodayWithoutCommitting() {
        var none = draft(nil)
        none.addSuggested()
        XCTAssertEqual(none.entry, .day(today))
        var cleared = draft("2026-11-20")
        cleared.clear()
        cleared.addSuggested()
        XCTAssertEqual(cleared.entry, .day("2026-11-20"))
        XCTAssertFalse(cleared.hasChanges)
    }

    // MARK: Cancel

    func testRevertRestoresTheOriginalAfterEdits() {
        var d = draft("2026-11-20", required: true)
        d.type("garbage")
        d.clear()
        _ = d.commit()
        d.revert()
        XCTAssertEqual(d.entry, .day("2026-11-20"))
        XCTAssertEqual(d.text, "2026-11-20")
        XCTAssertFalse(d.hasChanges)
        XCTAssertNil(d.visibleIssue, "Reverting also forgets a failed commit attempt")
        XCTAssertEqual(d, draft("2026-11-20", required: true))
    }

    func testRevertRestoresNoneOriginal() {
        var d = draft(nil)
        d.type("2026-11-25")
        d.revert()
        XCTAssertEqual(d.entry, .none)
        XCTAssertEqual(d.commit(), .unchanged)
    }

    func testCommittingNeverChangesTheOriginal() {
        var d = draft("2026-11-20")
        d.type("2026-11-21")
        _ = d.commit()
        XCTAssertEqual(d.original, "2026-11-20")
    }

    // MARK: Past days

    func testPastOriginalIsRepresentedExactly() {
        let d = draft("2026-10-01", past: .reject)
        XCTAssertEqual(d.entry, .day("2026-10-01"))
        XCTAssertEqual(d.text, "2026-10-01")
        XCTAssertEqual(DayKey(d.pickerDate(calendar: calendar), calendar: calendar), "2026-10-01")
    }

    func testUnchangedPastOriginalWarnsButStillCommitsUnchanged() {
        var d = draft("2026-10-01", past: .reject)
        XCTAssertEqual(d.issue, .pastDay("2026-10-01"))
        XCTAssertEqual(d.issue?.severity, .warning)
        XCTAssertEqual(d.commit(), .unchanged)
        XCTAssertEqual(d.entry, .day("2026-10-01"), "Validation must not move the day")
    }

    func testNewlyChosenPastDayWarnsAndCommitsByDefault() {
        var d = draft(nil)
        d.type("2026-11-08")
        XCTAssertEqual(d.visibleIssue, .pastDay("2026-11-08"))
        XCTAssertEqual(d.visibleIssue?.severity, .warning)
        XCTAssertEqual(d.visibleIssue?.message, "This day has already passed.")
        XCTAssertEqual(d.commit(), .set("2026-11-08"))
    }

    func testNewlyChosenPastDayIsAnErrorWhenRejectedAndIsNotClamped() {
        var d = draft("2026-11-20", past: .reject)
        d.select(Fixture.date("2026-11-01 12:00"), calendar: calendar)
        XCTAssertEqual(d.visibleIssue, .pastDayNotAllowed("2026-11-01"))
        XCTAssertEqual(d.visibleIssue?.severity, .error)
        XCTAssertEqual(d.visibleIssue?.message, "Choose today or a later day.")
        XCTAssertNil(d.commit())
        XCTAssertEqual(d.entry, .day("2026-11-01"), "The rejected day stays visible instead of jumping to today")
        XCTAssertEqual(d.text, "2026-11-01")
    }

    func testTodayIsNeverPastAndAllowedPolicyIsSilent() {
        var d = draft(nil, past: .reject)
        d.type(today.raw)
        XCTAssertNil(d.issue)
        var allowed = draft(nil, past: .allow)
        allowed.type("2020-01-01")
        XCTAssertNil(allowed.issue)
        XCTAssertEqual(allowed.commit(), .set("2020-01-01"))
    }

    // MARK: Accessibility and focus

    func testFocusOrderRunsFromEntryToActions() {
        XCTAssertEqual(DateFieldControl.focusOrder, [.text, .picker, .clear, .cancel, .commit])
    }

    func testAccessibilityLabelsNameTheField() {
        let labels = DateFieldControl.focusOrder.map { $0.accessibilityLabel(field: "Deadline") }
        XCTAssertEqual(
            labels,
            ["Deadline, typed date", "Deadline", "Clear deadline", "Cancel deadline edit", "Apply deadline"])
        XCTAssertEqual(DateFieldControl.add.accessibilityLabel(field: "Deadline"), "Add deadline")
        let ids = DateFieldControl.allCases.map { $0.identifier(field: "deadline") }
        XCTAssertEqual(Set(ids).count, DateFieldControl.allCases.count)
        XCTAssertEqual(DateFieldControl.commit.identifier(field: "deadline"), "deadline-date-commit")
    }

    func testAccessibilityValueDescribesNoneDayAndInvalidText() {
        var d = draft(nil)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(d.accessibilityValue(calendar: calendar, locale: locale), "No date")
        d.type("2026-11-12")
        XCTAssertEqual(d.accessibilityValue(calendar: calendar, locale: locale), "Thursday, November 12, 2026")
        d.type("later")
        XCTAssertEqual(d.accessibilityValue(calendar: calendar, locale: locale), "Not a date: later")
    }
}

extension FieldChange {
    fileprivate var isKeep: Bool { if case .keep = self { true } else { false } }
}
