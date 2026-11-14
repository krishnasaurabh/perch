import AppKit
import PerchUI
import PlannerCore
import SwiftUI

/// No title, icon or hover expansion. Activation uses the same explicit Today route as the menu.
struct NotchGlanceCapsule: View {
    let glance: NotchGlancePresentation
    var openToday: () -> Void

    var body: some View {
        Button(action: openToday) {
            Text(glance.text)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule(style: .continuous).fill(Theme.notchBlack))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(glance.accessibilityLabel)
        .accessibilityIdentifier("notch.taskCount")
        .help(glance.accessibilityLabel)
    }
}

/// Shared by the tab's fill, clip, content shape, and pointer routing.
struct NotchClosedTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: NotchClosedTokens.tabRadius,
            bottomTrailingRadius: NotchClosedTokens.tabRadius, topTrailingRadius: 0
        ).path(in: rect)
    }
}

/// One closed presentation, placed in global geometry without moving the housing.
struct NotchClosedLayer: View {
    let geometry: NotchGeometry
    let bounds: CGRect
    let presentation: NotchClosedPresentation
    let now: Date
    var open: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if geometry.hasHardwareNotch {
                if presentation.line != .none {
                    let rect = geometry.progressLine
                    Button(action: open) {
                        NotchProgressLine(presentation: presentation, now: now)
                            .frame(width: rect.width, height: rect.height)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(blockLabel)
                    .accessibilityIdentifier("notch.closed.progress")
                    .offset(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY)
                }
                if presentation.reminder {
                    let rect = geometry.reminderDot(progressVisible: presentation.line != .none)
                    Button(action: open) {
                        Circle().fill(Self.color(NotchClosedTokens.reminder))
                            .frame(width: rect.width, height: rect.height)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppL10n.text("Reminder waiting. Open Today"))
                    .accessibilityIdentifier("notch.closed.reminder")
                    .offset(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY)
                }
            } else if presentation.hasBlock || presentation.reminder {
                let rect = geometry.closedTab
                Button(action: open) {
                    HStack(spacing: NotchClosedTokens.tabSpacing) {
                        if presentation.reminder || presentation.focus?.state == .running {
                            Circle().fill(
                                Self.color(presentation.reminder ? NotchClosedTokens.reminder : NotchClosedTokens.fill)
                            )
                            .frame(width: NotchClosedTokens.dotSize, height: NotchClosedTokens.dotSize)
                            .accessibilityHidden(true)
                        }
                        Text(timeText)
                            .perchFont(.detailStrong)
                            .foregroundStyle(
                                Self.color(
                                    presentation.focus?.state == .paused
                                        ? NotchClosedTokens.paused : NotchClosedTokens.text)
                            )
                            .lineLimit(1)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .background(NotchClosedTabShape().fill(Self.color(NotchClosedTokens.background)))
                    .contentShape(NotchClosedTabShape())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.reminder ? AppL10n.text("Reminder waiting. Open Today") : blockLabel)
                .accessibilityIdentifier("notch.closed.tab")
                .offset(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    private var timeText: String {
        guard let focus = presentation.focus else { return now.formatted(date: .omitted, time: .shortened) }
        return NotchTimerPresentation(seconds: focus.remaining(at: now) ?? focus.elapsed(at: now)).text
    }

    private var blockLabel: String {
        guard let focus = presentation.focus else { return AppL10n.text("Open Today") }
        let state = AppL10n.text(focus.state == .paused ? "Paused" : "Time set aside")
        return AppL10n.format("%@, %@. Open Today", state, timeText)
    }

    static func color(_ hex: UInt32) -> Color { Color.dynamic(light: (hex, 1), dark: (hex, 1)) }
}

private struct NotchProgressLine: View {
    let presentation: NotchClosedPresentation
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .leading) {
                if presentation.line == .paused {
                    let dashes = NotchLayout.pausedDashes(line: rect)
                    ForEach(dashes.indices, id: \.self) { index in
                        Rectangle().fill(NotchClosedLayer.color(NotchClosedTokens.paused))
                            .frame(width: dashes[index].width, height: rect.height)
                            .offset(x: dashes[index].minX)
                    }
                } else {
                    Rectangle().fill(NotchClosedLayer.color(NotchClosedTokens.track))
                    Rectangle().fill(NotchClosedLayer.color(NotchClosedTokens.fill))
                        .frame(
                            width: NotchLayout.progressFill(line: rect, fraction: presentation.fraction(at: now)).width
                        )
                        .designMotion(.time, value: presentation.fraction(at: now))
                }
            }
        }
    }
}

@MainActor
extension NotchModel {
    func activateClosed(in store: PlannerStore, on screen: NotchScreenState) {
        let event = NSApp.currentEvent
        let pointer = event?.type == .leftMouseUp || event?.type == .leftMouseDown
        guard
            NotchClosedPresentation.allowsActivation(
                trigger: store.prefs.notchOpenTrigger, clickCount: pointer ? event?.clickCount : nil)
        else { return }
        screenID = screen.id
        geometry = screen.geometry
        NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
    }

    func drawsClosed(in store: PlannerStore, on id: CGDirectDisplayID) -> Bool {
        let state = closed(in: store, screenID: id)
        return state.hasBlock || state.reminder || (screenID == id && (expanded || displayedActivity != nil))
    }

    /// Do not infer a waiting answer merely because an old reminder date is in the past.
    func closed(in store: PlannerStore, screenID: CGDirectDisplayID, now: Date? = nil) -> NotchClosedPresentation {
        let now = now ?? PreviewClock.date ?? Date()
        var reminderIDs = closedReminderIDs
        if case .reminder(let id) = displayedActivity?.kind { reminderIDs.insert(id) }
        let waiting =
            screenID == self.screenID
            && store.planner.tasks.contains {
                reminderIDs.contains($0.id) && !$0.done && $0.remindAt.map { $0 <= now } == true
            }
        return NotchClosedPresentation(planner: store.planner, reminderWaiting: waiting)
    }
}

#if DEBUG || PERCH_TESTING
    /// Full top-strip fixtures share the live indicator view and geometry; a real
    /// housing is represented only here, never fabricated on a flat production screen.
    struct NotchClosedPreview: View {
        let planner: Planner
        let now: Date
        let hardware: Bool
        let reminderWaiting: Bool

        static let size = CGSize(width: DesignTokens.Size.todayWidth.value, height: 112)
        private static let menuHeight: CGFloat = 34
        private static let housingWidth: CGFloat = 190

        var geometry: NotchGeometry {
            NotchGeometry(
                screen: .init(
                    frame: CGRect(origin: .zero, size: Self.size),
                    visibleFrame: CGRect(
                        x: 0, y: 0, width: Self.size.width, height: Self.size.height - Self.menuHeight),
                    safeAreaTop: hardware ? Self.menuHeight : 0,
                    auxiliaryLeftWidth: hardware ? (Self.size.width - Self.housingWidth) / 2 : nil,
                    auxiliaryRightWidth: hardware ? (Self.size.width - Self.housingWidth) / 2 : nil))
        }

        var body: some View {
            let g = geometry
            ZStack(alignment: .topLeading) {
                Theme.fill(.sheet)
                Theme.fill(.paper).frame(height: Self.menuHeight)
                if let housing = g.camera {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: NotchClosedTokens.tabRadius,
                        bottomTrailingRadius: NotchClosedTokens.tabRadius, topTrailingRadius: 0
                    )
                    .fill(NotchClosedLayer.color(NotchClosedTokens.background))
                    .frame(width: housing.width, height: housing.height)
                    .offset(x: housing.minX, y: g.screenFrame.maxY - housing.maxY)
                }
                NotchClosedLayer(
                    geometry: g, bounds: g.screenFrame,
                    presentation: NotchClosedPresentation(planner: planner, reminderWaiting: reminderWaiting),
                    now: now, open: {})
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .ignoresSafeArea()
        }
    }

    extension AppDelegate.PreviewTarget {
        static func closedNotch(hardware: Bool, progress: Bool = true, reminder: Bool = true) -> Self {
            .window("notch-closed-preview") { app in
                guard let fixture = AppDelegate.activePreviewFixture else { return }
                var planner = app.store.planner
                planner.preferences.notchProgressLine = progress
                planner.preferences.notchReminderDot = reminder
                WindowHost.show("notch-closed-preview", title: "Perch", size: NotchClosedPreview.size) {
                    NotchClosedPreview(
                        planner: planner, now: fixture.now, hardware: hardware,
                        reminderWaiting: fixture.name == "notch-reminder"
                    )
                    .motionDiagnostics(model: app.model)
                }
            }
        }
    }
#endif
