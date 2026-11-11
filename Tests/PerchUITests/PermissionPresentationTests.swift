import Foundation
import XCTest
@testable import PerchUI

@MainActor
private final class PermissionFake: PermissionAccess {
    var states: [PermissionFeature: PermissionReading] = [:]
    var requested: [PermissionFeature] = []
    var result: PermissionReading = PermissionReading(.denied)
    var fails = false
    var pending: CheckedContinuation<Void, Never>?
    var suspend = false
    func read(_ feature: PermissionFeature) async -> PermissionReading {
        states[feature] ?? PermissionReading(.notDetermined)
    }
    func request(_ feature: PermissionFeature) async throws {
        requested.append(feature)
        if suspend { await withCheckedContinuation { pending = $0 } }
        if fails { throw NSError(domain: "PermissionTest", code: 1) }
        states[feature] = result
    }
}

final class PermissionPresentationTests: XCTestCase {
    @MainActor func testRefreshNeverRequestsAccess() async {
        let fake = PermissionFake()
        let workflow = PermissionWorkflow(access: fake)
        await workflow.refresh()
        XCTAssertEqual(workflow.readings.count, PermissionFeature.allCases.count)
        XCTAssertTrue(workflow.readings.values.allSatisfy { $0.state == .notDetermined })
        XCTAssertTrue(fake.requested.isEmpty)
    }

    @MainActor func testDeniedCompletionNeverLooksGrantedForAnyFeature() async {
        for feature in PermissionFeature.allCases {
            let fake = PermissionFake()
            let workflow = PermissionWorkflow(access: fake)
            await workflow.refresh()
            await workflow.request(feature)
            XCTAssertEqual(workflow.readings[feature]?.state, .denied)
            XCTAssertEqual(fake.requested, [feature])
            XCTAssertNil(workflow.requesting)
        }
    }

    @MainActor func testActualGrantAndLaterRevocationSurviveRepeatedReads() async {
        let fake = PermissionFake()
        fake.result = PermissionReading(.allowed)
        let workflow = PermissionWorkflow(access: fake)
        await workflow.refresh()
        await workflow.request(.calendar)
        XCTAssertEqual(workflow.readings[.calendar]?.state, .allowed)
        fake.states[.calendar] = PermissionReading(.denied)
        await workflow.refresh()
        XCTAssertEqual(workflow.readings[.calendar]?.state, .revoked)
        await workflow.refresh()
        XCTAssertEqual(workflow.readings[.calendar]?.state, .revoked)
        fake.states[.calendar] = PermissionReading(.allowed)
        await workflow.refresh()
        XCTAssertEqual(workflow.readings[.calendar]?.state, .allowed)
    }

    @MainActor func testRestrictedLimitedAndUnavailableStayDistinct() async {
        let fake = PermissionFake()
        let workflow = PermissionWorkflow(access: fake)
        for state in [PermissionState.restricted, .limited, .unavailable] {
            fake.states[.speech] = PermissionReading(state, detail: "Synthetic state detail")
            await workflow.refresh()
            await workflow.request(.speech)
            XCTAssertEqual(workflow.readings[.speech], PermissionReading(state, detail: "Synthetic state detail"))
        }
        XCTAssertTrue(fake.requested.isEmpty)
    }

    @MainActor func testThrownRequestRereadsTruthAndSurfacesError() async {
        let fake = PermissionFake()
        fake.fails = true
        let workflow = PermissionWorkflow(access: fake)
        await workflow.refresh()
        await workflow.request(.notifications)
        XCTAssertEqual(workflow.readings[.notifications]?.state, .notDetermined)
        XCTAssertNotNil(workflow.errors[.notifications])
        XCTAssertNil(workflow.requesting)
        fake.fails = false
        fake.result = PermissionReading(.allowed)
        await workflow.request(.notifications)
        XCTAssertEqual(workflow.readings[.notifications]?.state, .allowed)
        XCTAssertNil(workflow.errors[.notifications])
    }

    @MainActor func testMicrophoneDenialIsIndependentOfSpeechGrant() async {
        let fake = PermissionFake()
        fake.states[.speech] = PermissionReading(.allowed)
        fake.states[.microphone] = PermissionReading(.denied)
        let workflow = PermissionWorkflow(access: fake)
        await workflow.refresh()
        XCTAssertEqual(workflow.readings[.speech]?.state, .allowed)
        XCTAssertEqual(workflow.readings[.microphone]?.state, .denied)
        XCTAssertFalse(PermissionFeature.speech.detail.isEmpty)
    }

    @MainActor func testRequestWithoutReadOrAfterDenialDoesNotPrompt() async {
        let fake = PermissionFake()
        let workflow = PermissionWorkflow(access: fake)
        await workflow.request(.reminders)
        XCTAssertTrue(fake.requested.isEmpty)
        fake.states[.reminders] = PermissionReading(.denied)
        await workflow.refresh()
        await workflow.request(.reminders)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    @MainActor func testConcurrentClicksCannotRequestTwoPermissions() async {
        let fake = PermissionFake()
        fake.suspend = true
        let workflow = PermissionWorkflow(access: fake)
        await workflow.refresh()
        let first = Task { await workflow.request(.speech) }
        while fake.pending == nil { await Task.yield() }
        await workflow.request(.microphone)
        XCTAssertEqual(fake.requested, [.speech])
        XCTAssertEqual(workflow.requesting, .speech)
        fake.pending?.resume()
        await first.value
        XCTAssertNil(workflow.requesting)
    }

    func testEveryFeatureHasItsOwnSystemSettingsDestination() {
        let urls = PermissionFeature.allCases.map(\.settingsURL)
        XCTAssertEqual(Set(urls).count, PermissionFeature.allCases.count)
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "x-apple.systempreferences" })
        XCTAssertEqual(PermissionFeature.calendar.settingsURL.query, "Privacy_Calendars")
        XCTAssertEqual(PermissionFeature.speech.settingsURL.query, "Privacy_SpeechRecognition")
        XCTAssertEqual(PermissionFeature.microphone.settingsURL.query, "Privacy_Microphone")
        XCTAssertEqual(PermissionFeature.reminders.settingsURL.query, "Privacy_Reminders")
        XCTAssertEqual(
            PermissionFeature.notifications.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.notifications")
    }

    func testStatesHaveDistinctVisibleLabels() {
        XCTAssertEqual(Set(PermissionState.allCases.map(\.title)).count, PermissionState.allCases.count)
        XCTAssertEqual(PermissionState.revoked.title, "Revoked")
        XCTAssertEqual(PermissionState.restricted.title, "Restricted")
    }
}
