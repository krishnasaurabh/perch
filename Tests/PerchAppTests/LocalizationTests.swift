import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class LocalizationTests: XCTestCase {
    func testAppErrorsMapThroughCatalogAndKeepDynamicDetails() throws {
        let pseudo = Locale(identifier: "zz")
        XCTAssertEqual(
            AppL10n.format("AI sorting failed: %@", locale: pseudo, "Unavailable"),
            "⟦ÅÎ sörtïng fàïlëd: Unavailable ·~⟧")
        XCTAssertEqual(AppL10n.text("Could not delete this task.", locale: pseudo), "⟦Cöüld nöt dëlëtë thïs tàsk. ·~⟧")
        XCTAssertEqual(AppL10n.format("Removed %lld clips", locale: Locale(identifier: "en"), 1), "Removed 1 clip")
        XCTAssertEqual(AppL10n.format("Removed %lld clips", locale: pseudo, 2), "⟦Rëmövëd 2 clïps ·~⟧")

        let day: DayKey = "2026-11-09"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let task = PlanTask(title: "Sample task", day: day, done: true)
        var planner = Planner()
        planner.tasks = [task]
        let start = day.start(resetHour: planner.preferences.resetHour, calendar: calendar)
        var engine = PlannerEngine(planner: planner, now: { start }, calendar: calendar)
        XCTAssertThrowsError(try engine.complete(task.id)) { error in
            let plannerError = error as? PlannerError
            XCTAssertEqual(plannerError?.message, "Already completed: Sample task.")
            XCTAssertEqual(
                plannerError.map { AppL10n.plannerMessage($0, locale: pseudo) },
                "⟦Ålrëàdy cömplëtëd: Sample task. ·~⟧")
        }

        let error = PerchAppError.unsupportedParserLanguage("fr")
        XCTAssertTrue(error.message.contains("nothing was added"))
        XCTAssertTrue(error.message.contains("fr"))
    }

    func testAppFormattingResolvesCurrentAndExplicitLocale() {
        for locale in [Locale.current, Locale(identifier: "fr_FR")] {
            let expected = String(format: "%.1f", locale: locale, arguments: [1234.5])
            XCTAssertEqual(AppL10n.format("%.1f", locale: locale, 1234.5), expected)
        }
        XCTAssertEqual(
            AppL10n.format("%.1f", 1234.5),
            String(format: "%.1f", locale: Locale.current, arguments: [1234.5]))
        XCTAssertEqual(
            AppL10n.format("Removed %lld clips", 1234),
            String(format: "Removed %lld clips", locale: Locale.current, arguments: [1234]))
    }

    func testSettingsLanguageNamesHaveEnglishAndPseudoCatalogEntries() {
        let english = Locale(identifier: "en")
        let pseudo = Locale(identifier: "zz")
        for (key, expanded) in [
            ("English", "⟦Ënglïsh ·~⟧"), ("System language", "⟦Systëm làngüàgë ·~⟧"),
        ] {
            XCTAssertEqual(AppL10n.text(key, locale: english), key)
            XCTAssertEqual(AppL10n.text(key, locale: pseudo), expanded)
        }
    }

    func testOwnedStorageAndRecoveryErrorsMapThroughCatalog() {
        let english = Locale(identifier: "en")
        let pseudo = Locale(identifier: "zz")
        let original = URL(fileURLWithPath: "/synthetic/planner.json")
        let copy = URL(fileURLWithPath: "/synthetic/planner-copy.json")
        let recovered = URL(fileURLWithPath: "/synthetic/planner-recovered.json")
        let issues = URL(fileURLWithPath: "/synthetic/planner-issues.json")
        let recovery = PlannerRecoveryError(
            recoveredPlanner: Planner(), issues: [], keptCount: 3, quarantinedCount: 2, quarantinedFieldCount: 1,
            originalURL: copy, recoveredURL: recovered, issuesURL: issues)
        let busy = PlannerStorageBusy()
        XCTAssertEqual(busy.perchPresentationDetail(locale: english), busy.localizedDescription)
        XCTAssertEqual(
            busy.perchPresentationDetail(locale: pseudo),
            "⟦Ånöthër pröcëss ïs üpdàtïng thë plànnër. Plëàsë try àgàïn. ·~⟧")
        let cases: [(Error, String)] = [
            (PlannerDataError.unreadable(url: original, reason: "Permission denied"), original.path),
            (PlannerDataError.corrupt(url: original, quarantineURL: nil, reason: "Invalid JSON"), original.path),
            (PlannerDataError.corrupt(url: original, quarantineURL: copy, reason: "Invalid JSON"), copy.path),
            (PlannerSchemaError(version: 97), "97"),
            (recovery, recovered.path),
        ]
        for (error, preservedDetail) in cases {
            XCTAssertEqual(error.perchPresentationDetail(locale: english), error.localizedDescription)
            let presented = error.perchPresentationDetail(locale: pseudo)
            XCTAssertTrue(presented.hasPrefix("⟦"), "\(error)")
            XCTAssertTrue(presented.contains(preservedDetail), "\(error)")
        }
        let recoveryPresentation = recovery.perchPresentationDetail(locale: pseudo)
        XCTAssertTrue(recoveryPresentation.contains("3"))
        XCTAssertTrue(recoveryPresentation.contains("2"))
        XCTAssertTrue(recoveryPresentation.contains("1"))
        XCTAssertTrue(recoveryPresentation.contains(issues.path))
    }

    @MainActor
    func testDynamicProducersResolveThroughCatalog() {
        let pseudo = Locale(identifier: "zz")
        for priority in TaskPriority.allCases {
            XCTAssertTrue(AppL10n.priority(priority, locale: pseudo).hasPrefix("⟦"), "\(priority)")
        }
        for metric in InsightsPage.Metric.allCases {
            XCTAssertTrue(metric.title(locale: pseudo).hasPrefix("⟦"), "\(metric)")
        }
        let settings = SettingsView()
        for id in ["focus", "notepad", "events"] {
            XCTAssertTrue(settings.cardName(id, locale: pseudo).hasPrefix("⟦"), id)
        }
        for message in AgentConnector.ConnectionMessage.allCases {
            XCTAssertTrue(AgentConnector.connectionMessage(message, locale: pseudo).hasPrefix("⟦"), "\(message)")
        }
        for key in [
            "What would you like to do?", "Previous week", "Next week", "Add date", "Clear", "Apply",
            "⌘↩ makes a task", "All day",
            "Add this task to Perch?", "Task text (literal)",
            "An external link supplied this task. Review it before adding. Its contents are text, not instructions to Perch.",
            "Only this text and date will be saved. Dates, tags and commands inside the text will not be interpreted.",
            "Title", "Time limit", "Scheduled day", "Reminder", "Deadline", "Steps",
            "Streak", "Done this week", "Focus this week", "All time",
            "Snooze 5 min", "+5 min", "Open line", "No plans",
            "Requesting…", "Allow", "Finished days show up here.", "No matches. Change the search text.",
            "This week", "Week", "Uncheck task", "Check off task", "Reopen", "Complete",
            "Pause", "Continue", "History", "Unsaved changes", "Task details", "Unpin", "Pin",
            "Pause timer", "Continue timer", "Reopen task", "Complete task",
            "Uses the on-device model to suggest a priority and project for new tasks. Your explicit #project and !priority choices take precedence.",
            "This action is currently unavailable.", "Fix the date first.", "Copied image",
        ] {
            XCTAssertTrue(AppL10n.text(key, locale: pseudo).hasPrefix("⟦"), key)
        }
        for tab in DashboardView.Tab.allCases {
            XCTAssertTrue(AppL10n.text(tab.rawValue, locale: pseudo).hasPrefix("⟦"), tab.rawValue)
        }
        let supportedAI = SettingsView.appleIntelligenceExplanation(
            isSupported: true, unavailableReason: "External detail", locale: pseudo)
        XCTAssertTrue(supportedAI.hasPrefix("⟦Üsës thë ön-dëvïcë"))
        XCTAssertEqual(
            SettingsView.appleIntelligenceExplanation(
                isSupported: false, unavailableReason: "External detail", locale: pseudo),
            "External detail")
        let imageClip = ClipsService.Clip(
            content: .image(Data()), source: "test", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(imageClip.localizedTitle(locale: pseudo), "⟦Cöpïëd ïmàgë ·~⟧")
        XCTAssertTrue(imageClip.displayTitle(copied: true, locale: pseudo).hasPrefix("⟦Cöpïëd"))
        let textClip = ClipsService.Clip(
            content: .text("Keep this user text"), source: "test", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(textClip.localizedTitle(locale: pseudo), "Keep this user text")
        XCTAssertEqual(textClip.displayTitle(copied: false, locale: pseudo), "Keep this user text")
        let ownedReminder = "No Reminders account is available on this Mac."
        XCTAssertTrue(RemindersSyncFailure.presentedDetail(ownedReminder, locale: pseudo).hasPrefix("⟦Nö Rëmïndërs"))
        XCTAssertEqual(
            RemindersSyncFailure.presentedDetail("EventKit unavailable", locale: pseudo), "EventKit unavailable")
        for prompt in AgentConnector.examplePrompts {
            XCTAssertTrue(AppL10n.text(prompt, locale: pseudo).hasPrefix("⟦"), prompt)
        }
        let shortcutProblem = AppL10n.format(
            "macOS wouldn't give up that combination. Kept %@.", locale: pseudo, "⌥N")
        XCTAssertTrue(shortcutProblem.hasPrefix("⟦"))
        XCTAssertTrue(shortcutProblem.contains("⌥N"))
        let connectionError = AgentConnector.claudeCodeConnectionError(" Unavailable\n")
        XCTAssertEqual(connectionError.message, "Adding Perch to Claude Code failed. Unavailable")
        XCTAssertEqual(
            AppL10n.plannerMessage(connectionError, locale: pseudo),
            "⟦Åddïng Përch tö Clàüdë Cödë fàïlëd. Unavailable ·~⟧")
    }

    func testPackagedCatalogCompilesNativeLookupResources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", root.appendingPathComponent("scripts/compile_localization.py").path,
            root.appendingPathComponent("Resources/Localizable.xcstrings").path, output.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        _ = try XCTUnwrap(Bundle(path: output.path))
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings")))
                as? [String: Any])
        let catalogStrings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for language in ["en", "zz"] {
            let languageDirectory = output.appendingPathComponent("\(language).lproj")
            let generated = try XCTUnwrap(
                PropertyListSerialization.propertyList(
                    from: Data(contentsOf: languageDirectory.appendingPathComponent("Localizable.strings")),
                    options: [], format: nil) as? [String: String])
            XCTAssertEqual(Set(generated.keys), Set(catalogStrings.keys), language)
            for (key, entry) in catalogStrings {
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
                let localization = try XCTUnwrap(localizations[language])
                let unit: [String: Any]
                if let singular = localization["stringUnit"] as? [String: Any] {
                    unit = singular
                } else {
                    let variations = try XCTUnwrap(localization["variations"] as? [String: Any])
                    let plural = try XCTUnwrap(variations["plural"] as? [String: [String: Any]])
                    let other = try XCTUnwrap(plural["other"])
                    unit = try XCTUnwrap(other["stringUnit"] as? [String: Any])
                }
                XCTAssertEqual(generated[key], unit["value"] as? String, "\(language): \(key)")
            }
            // Select the language bundle explicitly. The root bundle chooses the user's
            // preferred localization independently of a formatting Locale argument.
            let languageBundle = try XCTUnwrap(Bundle(path: languageDirectory.path))
            XCTAssertEqual(
                languageBundle.localizedString(forKey: "General", value: "MISSING", table: "Localizable"),
                language == "en" ? "General" : "⟦Gënëràl ·~⟧")
        }
    }

    @MainActor
    func testStatusPointSizesGrowThroughAccessibilityCategories() {
        let sizes: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ]
        let points = sizes.map { StatusLabel.pointSize(for: $0) }
        for (smaller, larger) in zip(points, points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(larger, smaller)
        }
        XCTAssertGreaterThan(StatusLabel.pointSize(for: .xxxLarge), StatusLabel.pointSize(for: .large))
        XCTAssertGreaterThan(StatusLabel.pointSize(for: .accessibility5), StatusLabel.pointSize(for: .xxxLarge))
    }

    @MainActor
    func testNativePseudoRTLAndDynamicTypeLayoutUseTheProductionStatusView() async throws {
        let title =
            "Perch has no Reminders permission. Grant it under System Settings › Privacy & Security › Reminders."
        let standard = try await measureStatus(title: title, locale: Locale(identifier: "en"), dynamicType: .large)
        let enlarged = try await measureStatus(title: title, locale: Locale(identifier: "en"), dynamicType: .xxxLarge)
        let standardLabelFrame = try XCTUnwrap(standard.labelFrame)
        let enlargedLabelFrame = try XCTUnwrap(enlarged.labelFrame)
        XCTAssertGreaterThan(enlarged.pointSize, standard.pointSize)
        XCTAssertGreaterThan(enlargedLabelFrame.height, standardLabelFrame.height)

        let pseudo = try await measureStatus(
            title: title, locale: Locale(identifier: "zz"), dynamicType: .xxxLarge, direction: .rightToLeft)
        XCTAssertEqual(pseudo.direction, .rightToLeft)
        XCTAssertLessThanOrEqual(pseudo.size.width, 281)
        XCTAssertGreaterThan(pseudo.size.height, 30)
        XCTAssertEqual(pseudo.labels.count, 1)
        XCTAssertTrue(pseudo.labels[0].hasPrefix("⟦Përch hàs nö Rëmïndërs përmïssïön."))
        let hostFrame = try XCTUnwrap(pseudo.hostFrame)
        let labelFrame = try XCTUnwrap(pseudo.labelFrame)
        XCTAssertTrue(
            hostFrame.insetBy(dx: -1, dy: -1).contains(labelFrame),
            "The production accessibility label stays inside the rendered host at enlarged pseudo-locale text")
    }

    @MainActor
    private final class LayoutObservation {
        var metrics: StatusLabel.LayoutMetrics?
    }

    private struct StatusMeasurement {
        var size: CGSize
        var labels: [String]
        var hostFrame: NSRect?
        var labelFrame: NSRect?
        var direction: LayoutDirection
        var pointSize: CGFloat
    }

    @MainActor
    private func measureStatus(
        title: String, locale: Locale, dynamicType: DynamicTypeSize,
        direction: LayoutDirection = .leftToRight
    ) async throws -> StatusMeasurement {
        let measuredDirection = try await measureDirection(
            locale: locale, dynamicType: dynamicType, direction: direction)
        let observation = LayoutObservation()
        let host = NSHostingView(
            rootView: StatusLabel(title: title, tone: .warning, locale: locale)
                .frame(width: 280, alignment: .leading)
                .onPreferenceChange(StatusLabel.LayoutMetricsKey.self) { metrics in
                    MainActor.assumeIsolated { observation.metrics = metrics }
                }
                .environment(\.dynamicTypeSize, dynamicType)
                .environment(\.layoutDirection, direction)
                .environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let metrics = try await Self.waitForLayout(observation, host: host)
        XCTAssertEqual(metrics.pointSize, StatusLabel.pointSize(for: dynamicType))
        XCTAssertEqual(metrics.isRightToLeft, direction == .rightToLeft)
        let nodes = Self.nodes(host)
        let labels = Array(
            Set(
                nodes.compactMap { Self.attribute($0, "accessibilityLabel") as? String }
                    .filter { $0.hasPrefix("⟦") || $0.hasPrefix("Perch has no Reminders") })
        ).sorted()
        let hostFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        let labelFrame = nodes.first(where: {
            (Self.attribute($0, "accessibilityLabel") as? String) == labels.first
        }).flatMap { Self.accessibilityFrame(of: $0) }
        FileHandle.standardError.write(
            Data(
                "Status layout: size=\(dynamicType), points=\(metrics.pointSize), host=\(hostFrame), label=\(String(describing: labelFrame))\n"
                    .utf8))
        return StatusMeasurement(
            size: host.fittingSize, labels: labels, hostFrame: hostFrame, labelFrame: labelFrame,
            direction: measuredDirection, pointSize: metrics.pointSize)
    }

    /// A short, single-line production label exposes leading/trailing rendered geometry without wrapped text
    /// filling both edges. The long-label measurement above separately retains the clipping and expansion checks.
    @MainActor
    private func measureDirection(
        locale: Locale, dynamicType: DynamicTypeSize, direction: LayoutDirection
    ) async throws -> LayoutDirection {
        let observation = LayoutObservation()
        let host = NSHostingView(
            rootView: StatusLabel(title: "General", tone: .info, locale: locale)
                .frame(width: 280, alignment: .leading)
                .onPreferenceChange(StatusLabel.LayoutMetricsKey.self) { metrics in
                    MainActor.assumeIsolated { observation.metrics = metrics }
                }
                .environment(\.dynamicTypeSize, dynamicType)
                .environment(\.layoutDirection, direction)
                .environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let metrics = try await Self.waitForLayout(observation, host: host)
        let title = AppL10n.text("General", locale: locale)
        let node = try XCTUnwrap(
            Self.nodes(host).first { (Self.attribute($0, "accessibilityLabel") as? String) == title })
        let labelFrame = try XCTUnwrap(Self.accessibilityFrame(of: node))
        let hostFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        let leadingInset = labelFrame.minX - hostFrame.minX
        let trailingInset = hostFrame.maxX - labelFrame.maxX
        let diagnostics = "RTL=\(metrics.isRightToLeft); host=\(hostFrame); label=\(labelFrame)"
        FileHandle.standardError.write(Data((diagnostics + "\n").utf8))
        XCTAssertEqual(metrics.isRightToLeft, direction == .rightToLeft, diagnostics)
        if direction == .rightToLeft {
            XCTAssertGreaterThan(leadingInset, trailingInset + 1, diagnostics)
        } else {
            XCTAssertGreaterThan(trailingInset, leadingInset + 1, diagnostics)
        }
        return metrics.isRightToLeft ? .rightToLeft : .leftToRight
    }

    @MainActor
    private static func waitForLayout<V: View>(
        _ observation: LayoutObservation, host: NSHostingView<V>
    ) async throws -> StatusLabel.LayoutMetrics {
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            if observation.metrics != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let metrics = try XCTUnwrap(observation.metrics, "Production status environment was not published")
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        return metrics
    }

    private static func accessibilityFrame(of node: NSObject) -> NSRect? {
        guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
            let value = node.value(forKey: "accessibilityFrame") as? NSValue
        else { return nil }
        return value.rectValue
    }

    private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor
    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = (attribute(node, "accessibilityChildren") as? [NSObject]) ?? []
            let contents = (attribute(node, "accessibilityContents") as? [NSObject]) ?? []
            let subviews = (node as? NSView)?.subviews ?? []
            return [node] + (children + contents + subviews).flatMap { walk($0) }
        }
        return walk(root)
    }

    @MainActor
    func testUnsupportedParserLanguageDoesNotWriteOrRewriteTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.json")
        let store = PlannerStore(
            file: PlannerFile(url: url), now: { Date(timeIntervalSince1970: 1_800_000_000) },
            watching: false, parserLanguage: { nil })
        XCTAssertNil(store.addTasks(["Repair tomorrow at 5pm"]))
        guard case .unsupportedParserLanguage = store.lastError else {
            return XCTFail("unsupported language error missing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.planner.tasks.isEmpty)

        // Literal imports never invoke the natural-language parser and remain available.
        let added = try XCTUnwrap(store.addTasks(["Repair tomorrow at 5pm"], literal: true))
        XCTAssertEqual(added.first?.title, "Repair tomorrow at 5pm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try PlannerFile(url: url).load().tasks.first?.title, "Repair tomorrow at 5pm")
    }
}
