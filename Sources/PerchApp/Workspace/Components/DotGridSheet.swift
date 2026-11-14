import AppKit
import PerchUI
import SwiftUI

/// Shared surface identity lets nested labels resolve ink without forcing appearance.
typealias PerchSurface = DesignTokens.Surface

private struct DesignSurfaceKey: EnvironmentKey {
    static let defaultValue: PerchSurface? = nil
}

extension EnvironmentValues {
    var designSurface: PerchSurface? {
        get { self[DesignSurfaceKey.self] }
        set { self[DesignSurfaceKey.self] = newValue }
    }
}

/// Small subdivisions of the foundation spacing, not a second set of size constants.
enum SurfaceMetrics {
    static let gap = DesignTokens.Size.cardPadding.value / 2
    static let compactGap = DesignTokens.Size.sheetPadding.value - gap
    static let textInset = DesignTokens.Size.cardPadding.value - compactGap
    static let fieldRadius = DesignTokens.Size.addFieldRadius.value - DesignTokens.Size.fieldFocusWidth.value
}

/// Dot-grid paper for a panel below the band, or an ordinary window's content.
struct DotGridSheet<Content: View>: View {
    enum Kind {
        case panel, window

        var padding: CGFloat {
            switch self {
            case .panel: DesignTokens.Size.sheetPadding.value
            case .window: DesignTokens.Size.windowPadding.value
            }
        }

        var bottomRadius: CGFloat {
            self == .panel ? DesignTokens.Size.sheetBottomRadius.value : .zero
        }
    }

    let kind: Kind
    private let content: Content

    init(_ kind: Kind = .panel, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        content
            .padding(kind.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                Theme.fill(.sheet)
                    .overlay {
                        Canvas { context, size in
                            context.fill(Self.gridPath(in: size), with: .color(Theme.dot))
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: kind.bottomRadius,
                    bottomTrailingRadius: kind.bottomRadius)
            )
            .foregroundStyle(Theme.foreground(.ink, on: .sheet))
            .environment(\.controlSurface, Theme.fill(.sheet))
            .environment(\.designSurface, .sheet)
    }

    /// One batch path, anchored to the sheet rather than its children or scroll position.
    static func gridPath(in size: CGSize) -> Path {
        let spacing = DesignTokens.Size.dotSpacing.value
        let diameter = DesignTokens.Size.dotDiameter.value
        var path = Path()
        for y in stride(from: spacing / 2, through: size.height, by: spacing) {
            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                path.addEllipse(
                    in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
            }
        }
        return path
    }
}

#if DEBUG || PERCH_TESTING
    /// Isolated component states for preview capture; no planner or service side effects.
    struct SurfacePreview: View {
        let initiallyFocused: Bool
        @State private var task = ""
        @State private var thought = ""
        @FocusState private var focused: Bool

        static func show(focused: Bool) {
            WindowHost.show(
                "surface-preview", title: "Surfaces",
                size: CGSize(width: Theme.Size.todayWidth.value, height: Theme.Size.todayWidth.value / 2)
            ) {
                Self(initiallyFocused: focused)
            }
        }

        var body: some View {
            DotGridSheet {
                HStack(alignment: .top, spacing: Theme.Size.cardGap.value) {
                    Card(.paper) {
                        VStack(alignment: .leading, spacing: Theme.Size.cardGap.value) {
                            CardHeading(AppL10n.text("Today"))
                            Card(.butter, kind: .currentTask) {
                                VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                                    Text(AppL10n.text("Draft the test checklist")).perchFont(.currentTask)
                                    PerchPill(AppL10n.text("Now"), surface: .paper, ink: .brandText)
                                }
                            }
                            AddField(
                                AppL10n.text("Add a task"), text: $task,
                                prompt: AppL10n.text("Add a task. Tab makes it a step."),
                                focus: $focused, onSubmit: { task = "" },
                                onDictate: { task = AppL10n.text("Draft the test checklist") })
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.Size.cardGap.value) {
                        Card(.blush) {
                            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                                CardHeading(AppL10n.text("Time set aside"))
                                HStack(spacing: SurfaceMetrics.gap) {
                                    PerchPill(AppL10n.text("Now"), surface: .paper, ink: .brandText)
                                    PerchPill(AppL10n.text("Done"), surface: .mint, ink: .doneText, size: .regular)
                                    PerchPill(
                                        AppL10n.text("Carried over"), surface: .paper, ink: .carried, size: .large,
                                        textSize: .standard)
                                }
                            }
                        }
                        Card(.apricot) {
                            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                                CardHeading(AppL10n.text("Parking lot"))
                                PerchField(
                                    AppL10n.text("Jot a stray thought"), text: $thought, onSubmit: { thought = "" })
                            }
                        }
                        Card(.mint) {
                            VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                                CardHeading(AppL10n.text("Your day"))
                                StatusLabel(title: "Done", tone: .success)
                            }
                        }
                    }
                }
            }
            .defaultFocus($focused, initiallyFocused)
            .task { focused = initiallyFocused }
        }
    }
#endif
