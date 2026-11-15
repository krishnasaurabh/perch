import AppKit
import Combine
import PerchUI
import PlannerCore
import ServiceManagement
import SwiftUI

/// Settings-only layout tokens. Shared dimensions still come from the foundation.
enum SettingsMetrics {
    static let windowSize = CGSize(width: 760, height: 600)
    static let sidebarWidth: CGFloat = 208
    static let sidebarRowHeight = DesignTokens.Size.pillMaxHeight.value
    static let sidebarInset = DesignTokens.Size.segmentRadius.value
    static let sectionGap = DesignTokens.Size.cardPadding.value - DesignTokens.Size.fieldFocusWidth.value * 2
    static let titleGap = DesignTokens.Size.fieldFocusWidth.value * 2
    static let rowGap = DesignTokens.Size.segmentRadius.value
    static let rowHeight = DesignTokens.Size.buttonHeight.value
    static let dividerHeight = DesignTokens.Size.cardEdge.value
    static let minimumLabelWidth = DesignTokens.Size.buttonHeight.value * 3
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsView.Pane
    init(pane: SettingsView.Pane = .general) { self.pane = pane }
}

@MainActor
enum SettingsWindow {
    private static var navigation = SettingsNavigation()

    static func show(store: PlannerStore, services: Services, pane: SettingsView.Pane? = nil) {
        if WindowHost.windows["settings"] == nil { navigation = SettingsNavigation() }
        if let pane { navigation.pane = pane }
        WindowHost.show("settings", title: "Perch Settings", size: SettingsMetrics.windowSize) {
            SettingsView(navigation: navigation).environmentObject(store).environmentObject(services)
        }
    }

    #if DEBUG || PERCH_TESTING
        static func preview(_ pane: SettingsView.Pane, app: AppDelegate) {
            show(store: app.store, services: app.services, pane: pane)
        }
    #endif

    static func versionLabel(version: String = AppInfo.version) -> String {
        AppL10n.format("Perch %@", version)
    }
}

struct SettingsView: View {
    @StateObject private var navigation: SettingsNavigation
    @State private var agentStatuses: [AgentConnector.App: AgentConnector.Status] = [:]
    @StateObject private var feedback = SettingsFailureFeedback()
    @FocusState private var focusedPane: Pane?

    init(navigation: SettingsNavigation = SettingsNavigation()) {
        _navigation = StateObject(wrappedValue: navigation)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general, notch, calendar, agents, data
        var id: String { rawValue }
        var previewTarget: String { "settings/\(rawValue)" }
        var title: String {
            switch self {
            case .general: AppL10n.text("General")
            case .notch: AppL10n.text("Notch and menu bar")
            case .calendar: AppL10n.text("Calendar and reminders")
            case .agents: AppL10n.text("AI agents")
            case .data: AppL10n.text("Your data")
            }
        }
        // Preserve symbol identities for existing integrations; the sidebar uses text only.
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .notch: "rectangle.3.group"
            case .calendar: "timer"
            case .agents: "sparkles"
            case .data: "lock.shield"
            }
        }
        func moved(by offset: Int) -> Self {
            let index = Self.allCases.firstIndex(of: self)!
            return Self.allCases[min(max(index + offset, 0), Self.allCases.count - 1)]
        }
    }

    var body: some View {
        DotGridSheet(.window) {
            HStack(alignment: .top, spacing: SettingsMetrics.sectionGap) {
                sidebar
                SettingsDetail(feedback: feedback) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                            selectedPane
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollClipDisabled()
                    .id(navigation.pane)
                    .accessibilityIdentifier("settings.detail.\(navigation.pane.rawValue)")
                }
            }
            // DotGridSheet's ordinary-window padding is 20; Settings uses the 16 pt card inset.
            .padding(Theme.Size.cardPadding.value - Theme.Size.windowPadding.value)
        }
        .perchFont(.body)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
            Text("Settings")
                .perchFont(.cardTitle)
                .padding(.horizontal, SurfaceMetrics.gap)
                .padding(.bottom, SurfaceMetrics.gap)
                .accessibilityAddTraits(.isHeader)
            ForEach(Pane.allCases) { pane in
                Button {
                    navigation.pane = pane
                } label: {
                    Text(pane.title)
                        .perchFont(.pill)
                        .fontWeight(navigation.pane == pane ? .semibold : .medium)
                        .foregroundStyle(navigation.pane == pane ? Theme.ink : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.sidebarRowHeight, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.sidebarInset)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value)
                                .fill(navigation.pane == pane ? Theme.butter : .clear)
                        }
                        .overlay {
                            FocusRing(
                                shape: RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value),
                                focused: focusedPane == pane, surface: .paper)
                        }
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedPane, equals: pane)
                .focusEffectDisabled()
                .accessibilityAddTraits(navigation.pane == pane ? .isSelected : [])
                .accessibilityIdentifier("settings.sidebar.\(pane.rawValue)")
                .onMoveCommand { direction in
                    switch direction {
                    case .up: select(pane.moved(by: -1))
                    case .down: select(pane.moved(by: 1))
                    default: break
                    }
                }
            }
            Spacer(minLength: Theme.Size.cardPadding.value)
            Text(SettingsWindow.versionLabel())
                .perchFont(.detail)
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, SurfaceMetrics.gap)
                .accessibilityIdentifier("settings.version")
        }
        .padding(.horizontal, SettingsMetrics.sidebarInset)
        .padding(.vertical, SettingsMetrics.sectionGap)
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .modifier(SettingsPaperSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func select(_ pane: Pane) {
        navigation.pane = pane
        focusedPane = pane
    }

    @ViewBuilder private var selectedPane: some View {
        switch navigation.pane {
        case .general: SettingsGeneralPane(feedback: feedback)
        case .notch: SettingsNotchPane()
        case .calendar: SettingsCalendarPane()
        case .agents: SettingsAgentsPane(statuses: $agentStatuses, feedback: feedback)
        case .data: SettingsDataPane(feedback: feedback)
        }
    }

    // Shared language presentation remains here for existing localization integrations.
    @ViewBuilder static var language: some View {
        Section("Language") {
            LabeledContent(
                "Interface",
                value: Locale.current.localizedString(
                    forLanguageCode: Locale.current.language.languageCode?.identifier ?? "")
                    ?? AppL10n.text("System language"))
            LabeledContent("Task entry parser", value: AppL10n.text("English"))
            Text(
                "Perch follows the app language for dates, numbers and interface text. Natural-language task entry supports English; other languages never fall back to English or rewrite tasks."
            )
            .perchFont(.detail).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            if TaskParserLanguage.current == nil {
                Text(
                    "Task entry is unavailable in this app language. Choose English to add parsed tasks; existing tasks and literal imports are unchanged."
                )
                .perchFont(.detail).foregroundStyle(Theme.brandText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static var appleIntelligenceHelp: String {
        Self.appleIntelligenceExplanation(
            isSupported: AISorter.isSupported, unavailableReason: AISorter.unavailableReason)
    }

    static func appleIntelligenceExplanation(
        isSupported: Bool, unavailableReason: String, locale: Locale? = nil
    ) -> String {
        isSupported
            ? AppL10n.text(
                "Uses the on-device model to suggest a priority and project for new tasks. Your explicit #project and !priority choices take precedence.",
                locale: locale)
            : unavailableReason
    }

    /// "Midnight" for 0, otherwise the hour in the user's clock style ("4 AM" or "04:00").
    static func hourLabel(_ hour: Int) -> String {
        guard hour > 0, let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else {
            return AppL10n.text("Midnight")
        }
        return d.formatted(date: .omitted, time: .shortened)
    }

    func cardName(_ id: String, locale: Locale? = nil) -> String {
        switch id {
        case "focus": AppL10n.text("Time set aside", locale: locale)
        case "notepad": AppL10n.text("Parking lot", locale: locale)
        case "events": AppL10n.text("Your day", locale: locale)
        default: id
        }
    }

}

/// Typed preference binding shared by the pane entry points.
@MainActor
func settingsPreference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>, store: PlannerStore) -> Binding<Value> {
    Binding(
        get: { store.prefs[keyPath: keyPath] }, set: { value in store.updatePrefs { $0[keyPath: keyPath] = value } })
}

private struct SettingsPaperSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.Size.cardRadius.value).fill(Theme.paper))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Size.cardRadius.value)
                    .strokeBorder(Theme.edge(.paper), lineWidth: Theme.Size.cardEdge.value)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.ink)
            .environment(\.controlSurface, Theme.paper)
            .environment(\.designSurface, .paper)
    }
}

/// Each top-level child is a row, separated once. Conditionals and loops preserve order.
@MainActor
@resultBuilder
struct SettingsSectionBuilder {
    static func buildExpression<V: View>(_ expression: V) -> [AnyView] { [AnyView(expression)] }
    static func buildBlock(_ components: [AnyView]...) -> [AnyView] { components.flatMap { $0 } }
    static func buildOptional(_ component: [AnyView]?) -> [AnyView] { component ?? [] }
    static func buildEither(first component: [AnyView]) -> [AnyView] { component }
    static func buildEither(second component: [AnyView]) -> [AnyView] { component }
    static func buildArray(_ components: [[AnyView]]) -> [AnyView] { components.flatMap { $0 } }
}

struct SettingsSection: View {
    let title: String
    private let rows: [AnyView]

    init(_ title: String, @SettingsSectionBuilder content: () -> [AnyView]) {
        self.title = title
        rows = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text(AppL10n.text(title))
                .perchFont(.stripTitle)
                .padding(.bottom, SettingsMetrics.titleGap)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows.indices, id: \.self) { index in
                if index != rows.startIndex {
                    Rectangle().fill(Theme.edge(.paper))
                        .frame(height: SettingsMetrics.dividerHeight)
                        .accessibilityHidden(true)
                }
                rows[index]
            }
        }
        .padding(.horizontal, Theme.Size.cardPadding.value)
        .padding(.vertical, SettingsMetrics.sectionGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsPaperSurface())
        .accessibilityElement(children: .contain)
    }
}

/// A 40 pt minimum row. Long labels and help grow; controls keep their own AX names.
struct SettingsRow<Control: View>: View {
    let title: String
    let help: String?
    private let control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.titleGap) {
            SettingsRowLayout {
                Text(AppL10n.text(title))
                    .perchFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                control
            }
            .frame(minHeight: SettingsMetrics.rowHeight)
            if let help {
                Text(AppL10n.text(help))
                    .perchFont(.detail)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, SurfaceMetrics.gap)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Measures each child once per proposal; narrow rows stack instead of clipping their controls.
private struct SettingsRowLayout: Layout {
    struct Cache {
        var sizes: [CGSize] = []
        var stacked = false
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? SettingsMetrics.windowSize.width
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let remaining = width - control.width - SettingsMetrics.rowGap
        cache.stacked = remaining < SettingsMetrics.minimumLabelWidth
        let label = subviews[0].sizeThatFits(
            ProposedViewSize(width: cache.stacked ? width : remaining, height: nil))
        cache.sizes = [label, control]
        return CGSize(
            width: width,
            height: cache.stacked
                ? label.height + SettingsMetrics.titleGap + control.height : max(label.height, control.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard cache.sizes.count == 2 else { return }
        let label = cache.sizes[0], control = cache.sizes[1]
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: cache.stacked ? bounds.minY : bounds.midY - label.height / 2),
            proposal: ProposedViewSize(label))
        subviews[1].place(
            at: CGPoint(
                x: bounds.maxX - control.width,
                y: cache.stacked ? bounds.maxY - control.height : bounds.midY - control.height / 2),
            proposal: ProposedViewSize(control))
    }
}

/// Retains only the failed Settings operation, never a guessed retry for an unrelated store error.
@MainActor
final class SettingsFailureFeedback: ObservableObject {
    @Published private(set) var retryError: PerchAppError?
    var failedAgentDisconnects: Set<AgentConnector.App> = []
    private var retryAction: (() -> Void)?
    private var retryID: UUID?
    private weak var observedStore: PlannerStore?
    private var errorObservation: AnyCancellable?

    func canRetry(_ error: PerchAppError) -> Bool {
        retryID != nil && retryError == error && retryAction != nil
    }

    private func invalidateRetry() {
        retryID = nil
        retryAction = nil
        retryError = nil
    }

    private func observeErrors(in store: PlannerStore) {
        guard observedStore !== store else { return }
        errorObservation?.cancel()
        observedStore = store
        // Observe every publication synchronously, including nil and equal-valued errors.
        // A render-time onChange can coalesce those distinct failure events.
        errorObservation = store.$lastError.sink { [weak self] _ in self?.invalidateRetry() }
    }

    func retry(_ error: PerchAppError) {
        guard canRetry(error) else { return }
        retryAction?()
    }

    @discardableResult
    func perform(
        store: PlannerStore, failure: @escaping (Error) -> PerchAppError,
        operation: @escaping () throws -> Void
    ) -> Bool {
        observeErrors(in: store)
        let previousRetryID = retryID
        do {
            try operation()
            if let previousRetryID, retryID == previousRetryID { store.lastError = nil }
            invalidateRetry()
            return true
        } catch {
            let presented = failure(error)
            // Publishing ends any previous event's ownership before arming this operation.
            store.lastError = presented
            retryID = UUID()
            retryAction = { [weak self, weak store] in
                guard let self, let store else { return }
                self.perform(store: store, failure: failure, operation: operation)
            }
            retryError = presented
            return false
        }
    }

    func updateLoginItem(
        _ enabled: Bool, store: PlannerStore,
        change: @escaping (Bool) throws -> Void = { enabled in
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        }
    ) {
        perform(store: store, failure: { .loginItem($0.perchPresentationDetail) }) { try change(enabled) }
    }

    func exportBackup(
        to url: URL, store: PlannerStore, export: ((URL) throws -> Void)? = nil
    ) {
        let write = export ?? { try store.file.export(to: $0) }
        perform(store: store, failure: { .planner($0.perchPresentationDetail) }) { try write(url) }
    }
}

struct SettingsErrorRow: View {
    let error: PerchAppError
    var retry: (() -> Void)?
    var status: StatusLabel { StatusLabel(title: error.perchPresentationDetail, tone: .danger) }

    var body: some View {
        HStack(alignment: .top, spacing: SurfaceMetrics.gap) {
            status.textSelection(.enabled)
            Spacer(minLength: .zero)
            if let retry {
                PerchButton("Retry", kind: .soft, size: .small, action: retry)
                    .help("Action failed. Please try again.")
                    .accessibilityIdentifier("settings.error.retry")
            }
        }
        .padding(SettingsMetrics.sectionGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsPaperSurface())
    }
}

/// The failure surface stays above the scrolling pane and never disappears on navigation.
struct SettingsDetail<Content: View>: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var feedback: SettingsFailureFeedback
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: SettingsMetrics.sectionGap) {
            if let error = store.lastError {
                SettingsErrorRow(
                    error: error,
                    retry: feedback.canRetry(error) ? { feedback.retry(error) } : nil
                )
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            }
            content()
                .frame(maxWidth: .infinity, minHeight: .zero, maxHeight: .infinity, alignment: .top)
        }
    }
}
