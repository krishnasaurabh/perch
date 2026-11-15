import PlannerCore
import PerchUI
import SwiftUI

/// Detached capsules share exact global frames with the controller's mouse routing.
struct NotchPills: View {
    let pills: [NotchPillPresentation]
    let frames: [CGRect]
    let bounds: CGRect
    var open: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(pills.enumerated()), id: \.element.id) { index, pill in
                if index < frames.count {
                    let rect = frames[index]
                    Button(action: open) {
                        NotchPillFace(text: pill.text, showsDot: pill.showsDot, paused: pill.paused)
                            .frame(width: rect.width, height: rect.height)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pill.accessibilityLabel)
                    .accessibilityIdentifier("notch.pill.\(pill.kind.rawValue)")
                    .help(pill.help)
                    .offset(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY)
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }
}

struct NotchPillFace: View {
    let text: String
    let showsDot: Bool
    let paused: Bool

    var body: some View {
        HStack(spacing: NotchPillLayout.gap) {
            if showsDot {
                Circle().fill(NotchClosedLayer.color(NotchPillLayout.dotInk))
                    .frame(width: NotchPillLayout.dotSize, height: NotchPillLayout.dotSize)
                    .accessibilityHidden(true)
            }
            if !text.isEmpty {
                Text(text).perchFont(NotchPillLayout.font)
                    .foregroundStyle(NotchClosedLayer.color(paused ? NotchPillLayout.pausedInk : NotchPillLayout.ink))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, NotchPillLayout.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(NotchClosedLayer.color(NotchPillLayout.background)))
    }
}

@MainActor
extension NotchModel {
    func pills(in store: PlannerStore, now: Date) -> [NotchPillPresentation] {
        var planner = store.planner
        if taskCountSuppressed { planner.preferences.notchTaskCount = false }
        return NotchPillPresentation.make(planner: planner, today: store.today, now: now)
    }

    func peek(on screen: NotchScreenState) {
        guard screenID != screen.id || !expanded else { return }
        if expanded { close() }
        screenID = screen.id
        geometry = screen.geometry
        openPeek()
    }
}

#if DEBUG || PERCH_TESTING
    struct NotchPillsPreview: View {
        let planner: Planner
        let today: DayKey
        let now: Date
        private static let size = CGSize(
            width: DesignTokens.Size.todayWidth.value, height: DesignTokens.Size.cardPadding.value * 7)
        private static let menuHeight = DesignTokens.Size.pillMaxHeight.value
        private static let housingWidth = DesignTokens.Size.taskRowHeight.value * 5

        var body: some View {
            let bounds = CGRect(origin: .zero, size: Self.size)
            let housing = CGRect(
                x: bounds.midX - Self.housingWidth / 2, y: bounds.maxY - Self.menuHeight,
                width: Self.housingWidth, height: Self.menuHeight)
            let pills = NotchPillPresentation.make(planner: planner, today: today, now: now)
            ZStack(alignment: .topLeading) {
                Theme.sheet
                Theme.paper.frame(height: Self.menuHeight)
                UnevenRoundedRectangle(
                    bottomLeadingRadius: Theme.Size.segmentRadius.value,
                    bottomTrailingRadius: Theme.Size.segmentRadius.value
                )
                .fill(Theme.notchBlack).frame(width: housing.width, height: housing.height)
                .offset(x: housing.minX)
                NotchPills(
                    pills: pills,
                    frames: NotchPillLayout.frames(
                        pills: pills, housing: housing, placement: planner.preferences.notchTimerPlacement),
                    bounds: bounds, open: {})
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }

        static func target(_ mode: String) -> AppDelegate.PreviewTarget {
            .window("notch-pills-preview") { app in
                guard let fixture = AppDelegate.activePreviewFixture else { return }
                var planner = app.store.planner
                planner.preferences.hideCountsAndTimes = mode == "private"
                planner.preferences.notchTimePill = ["time", "paused", "both", "left", "private"].contains(mode)
                planner.preferences.notchTaskCount = ["tasks", "both", "left", "private"].contains(mode)
                planner.preferences.notchNextBlock = mode == "next"
                planner.preferences.notchTimerPlacement = mode == "both" ? .split : mode == "left" ? .left : .right
                if mode == "next", !planner.tasks.isEmpty {
                    planner.tasks[0].startAt = fixture.now.addingTimeInterval(NotchPillLayout.nextBlockLead / 2)
                }
                WindowHost.show("notch-pills-preview", title: "Perch", size: Self.size) {
                    Self(planner: planner, today: fixture.day, now: fixture.now).motionDiagnostics(model: app.model)
                }
            }
        }
    }
#endif
