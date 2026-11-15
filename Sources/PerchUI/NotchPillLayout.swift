import Foundation
import PlannerCore

/// Closed pills expose state, never task names. Privacy removes numeric data before rendering or AX.
public struct NotchPillPresentation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case time, tasks, nextBlock }
    public var id: Kind { kind }
    public let kind: Kind
    public let text: String
    public let accessibilityLabel: String
    public var help: String { accessibilityLabel }
    public let showsDot: Bool
    public let paused: Bool
    public var ink: UInt32 { paused ? NotchPillLayout.pausedInk : NotchPillLayout.ink }

    public static func make(planner: Planner, today: DayKey, now: Date, locale: Locale = .current) -> [Self] {
        let prefs = planner.preferences
        guard prefs.notchTimerPlacement != .hidden else { return [] }
        var result: [Self] = []
        let focus = planner.focus.flatMap { $0.state == .finished ? nil : $0 }
        if prefs.notchTimePill, let focus {
            let paused = focus.state == .paused
            let face = NotchTimerPresentation(seconds: focus.remaining(at: now) ?? focus.elapsed(at: now))
            let state = PerchL10n.text(paused ? "Paused" : "Time set aside", locale: locale)
            result.append(
                Self(
                    kind: .time, text: prefs.hideCountsAndTimes ? "" : face.text,
                    accessibilityLabel: prefs.hideCountsAndTimes
                        ? state : PerchL10n.format("%@, %@ left", locale: locale, state, face.fullText),
                    showsDot: !paused, paused: paused))
        }
        let open = planner.tasks.filter { !$0.done && $0.day == today }
        if prefs.notchTaskCount, !open.isEmpty {
            let text = PerchL10n.format("%lld left", locale: locale, open.count)
            result.append(
                Self(
                    kind: .tasks, text: prefs.hideCountsAndTimes ? "" : text,
                    accessibilityLabel: prefs.hideCountsAndTimes ? PerchL10n.text("Tasks left", locale: locale) : text,
                    showsDot: prefs.hideCountsAndTimes, paused: false))
        }
        if prefs.notchNextBlock,
            let next = open.compactMap(\.startAt).filter({
                $0 > now && $0.timeIntervalSince(now) <= NotchPillLayout.nextBlockLead
            }).min()
        {
            let time = next.formatted(.dateTime.locale(locale).hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
            let text = PerchL10n.format("Next %@", locale: locale, time)
            result.append(
                Self(
                    kind: .nextBlock, text: prefs.hideCountsAndTimes ? "" : text,
                    accessibilityLabel: prefs.hideCountsAndTimes ? PerchL10n.text("Next block", locale: locale) : text,
                    showsDot: prefs.hideCountsAndTimes, paused: false))
        }
        return result
    }
}

/// Pill metrics are independent of AppKit and shared by paint and hit routing.
public enum NotchPillLayout {
    public static let height: CGFloat = DesignTokens.Size.switchHeight.value
    public static let gap: CGFloat = DesignTokens.Size.stepCheckboxRadius.value
    public static let maximumWidth: CGFloat = 96
    public static let horizontalInset: CGFloat = DesignTokens.Size.cardPadding.value / 2
    public static let dotSize: CGFloat = DesignTokens.Size.stepCheckboxRadius.value
    public static let nextBlockLead: TimeInterval = 15 * 60
    public static let background: UInt32 = 0x000000
    public static let ink: UInt32 = 0xFFFFFF
    public static let pausedInk: UInt32 = 0xB9ADA3
    public static let dotInk = DesignTokens.ColorToken.brandFill.hex(in: .dark)
    public static let font = DesignTokens.TypeRole.detailStrong
    /// Fixed-width digit advance plus room for wider localized letters. Never scale type below 12 pt.
    public static let glyphAdvance = DesignTokens.TypeRole.detailStrong.spec.size * 0.65

    public static func width(text: String, showsDot: Bool) -> CGFloat {
        min(
            maximumWidth,
            max(height, CGFloat(text.count) * glyphAdvance + horizontalInset * 2 + (showsDot ? dotSize + gap : 0)))
    }

    public static func frames(pills: [NotchPillPresentation], housing: CGRect, placement: NotchTimerPlacement)
        -> [CGRect]
    {
        guard placement != .hidden else { return [] }
        var left = housing.minX - gap
        var right = housing.maxX + gap
        return pills.enumerated().map { index, pill in
            let w = width(text: pill.text, showsDot: pill.showsDot)
            let onLeft = placement == .left || (placement == .split && index % 2 == 1)
            let x: CGFloat
            if onLeft { x = left - w; left = x - gap } else { x = right; right = x + w + gap }
            return CGRect(x: x, y: housing.midY - height / 2, width: w, height: height)
        }
    }

    public static func contains(_ pointer: CGPoint, frames: [CGRect]) -> Bool {
        frames.contains { NotchLayout.capsuleContains($0, pointer: pointer) }
    }
}
