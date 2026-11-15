import AppKit
import XCTest
@testable import PerchApp

@MainActor
final class SettingsDataConfirmationTests: XCTestCase {
    private let requests: [SettingsDataConfirmation] = [
        .restoreBackup, .emptyParkingLot, .eraseEverything,
        .retention(.thirtyDays), .retention(.ninetyDays),
    ]

    func testOnlyTheExplicitProceedResponseConfirms() {
        for request in requests {
            for response in [
                NSApplication.ModalResponse.alertFirstButtonReturn, .cancel, .abort,
                .alertSecondButtonReturn,
            ] {
                var presented = false
                let accepted = SettingsDataActions.presentConfirmation(for: request) { alert in
                    presented = true
                    XCTAssertEqual(alert.buttons.first?.title, "Cancel")
                    XCTAssertEqual(alert.buttons.last?.title, request.actionTitle)
                    return response
                }
                XCTAssertTrue(presented)
                XCTAssertEqual(accepted, response == .alertSecondButtonReturn)
            }
        }
    }

    func testNativeCancelAndEscapeCancelWhileProceedIsExplicit() async throws {
        _ = NSApplication.shared
        for request in requests {
            for input in Input.allCases {
                let parent = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                parent.isReleasedWhenClosed = false
                parent.orderFront(nil)
                let alert = SettingsDataActions.alert(for: request)
                let result = ConfirmationResult()
                defer {
                    if parent.attachedSheet != nil { parent.endSheet(alert.window, returnCode: .abort) }
                    alert.window.orderOut(nil)
                    parent.close()
                }
                alert.beginSheetModal(for: parent) { response in
                    MainActor.assumeIsolated { result.response = response }
                }
                XCTAssertTrue(parent.attachedSheet === alert.window)
                XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\u{1b}")
                XCTAssertEqual(alert.buttons.last?.keyEquivalent, "")
                XCTAssertFalse(alert.window.defaultButtonCell === alert.buttons.last?.cell)
                switch input {
                case .cancel:
                    alert.buttons[0].performClick(nil)
                case .escape:
                    let event = try XCTUnwrap(
                        NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: alert.window.windowNumber, context: nil,
                            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                            isARepeat: false, keyCode: 53))
                    XCTAssertTrue(alert.window.performKeyEquivalent(with: event))
                case .proceed:
                    alert.buttons[1].performClick(nil)
                }
                for _ in 0..<200 {
                    if result.response != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let response = try XCTUnwrap(result.response, "The native alert must finish for \(input)")
                XCTAssertEqual(response, input == .proceed ? .alertSecondButtonReturn : .alertFirstButtonReturn)
                XCTAssertEqual(
                    SettingsDataActions.presentConfirmation(for: request, runModal: { _ in response }),
                    input == .proceed)
            }
        }
    }

    private enum Input: CaseIterable { case cancel, escape, proceed }
    @MainActor private final class ConfirmationResult { var response: NSApplication.ModalResponse? }
}
