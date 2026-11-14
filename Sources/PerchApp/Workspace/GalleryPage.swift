#if DEBUG || PERCH_TESTING
    import AppKit
    import PerchUI
    import SwiftUI

    /// Local examples only. Opening the gallery never changes a person's planner.
    struct GalleryDemo: Equatable {
        static let initialSeconds = 24 * 60 + 10
        static let stepTitles = [
            AppL10n.text("List the release areas"), AppL10n.text("Pull last week's bug list"),
            AppL10n.text("Write the smoke tests"), AppL10n.text("Share it with Sam"),
        ]
        var running = false
        var taskDone = false
        var steps = [true, true, false, false]
        var headsUp = true
        var minutes = 45
        var seconds = Self.initialSeconds

        var doneCount: Int { steps.filter { $0 }.count }
        var progress: Double { min(1, Double(seconds) / Double(minutes * 60)) }
        var timeText: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

        mutating func addTime() { seconds += 5 * 60 }
        mutating func resetTime() { seconds = Self.initialSeconds }
        mutating func selectMinutes(_ value: Int) {
            guard [15, 25, 45, 60].contains(value) else { return }
            minutes = value
            seconds = value * 60
        }
        mutating func setTask(_ done: Bool) {
            taskDone = done
            steps = steps.map { _ in done }
        }
        mutating func setStep(_ index: Int, done: Bool) {
            guard steps.indices.contains(index) else { return }
            steps[index] = done
            taskDone = steps.allSatisfy { $0 }
        }
    }

    /// Two independent sheets share the same --open gallery entry point.
    struct GalleryPage: View {
        enum Page: Equatable {
            case system, motion
            static func forScenario(_ scenario: String?) -> Self { scenario == "timer" ? .motion : .system }
            var size: CGSize {
                switch self {
                case .system:
                    CGSize(width: Theme.Size.todayWidth.value, height: Theme.Size.stripMaxWidth.value)
                case .motion:
                    CGSize(
                        width: Theme.Size.todayWidth.value + Theme.Size.sheetPadding.value * 10,
                        height: Theme.Size.stripMaxWidth.value + Theme.Size.sheetPadding.value * 10)
                }
            }
        }

        let page: Page
        @State private var demo = GalleryDemo()
        @State private var selectedRow = 0
        @State private var partTask = false
        @State private var partStep = false
        @State private var partDone = true
        @FocusState private var checklistFocused: Bool
        @ScaledMetric(relativeTo: .largeTitle) private var typefaceSize = Theme.Size.addFieldHeight.value
        @ScaledMetric(relativeTo: .body) private var specimenSize = GalleryMetrics.specimenSize

        static func show() {
            let scenario = AppDelegate.activePreviewFixture?.name ?? AppDelegate.previewOption("--scenario")
            let page = Page.forScenario(scenario)
            WindowHost.show("gallery", title: "Foundations", size: page.size) {
                GalleryPage(page: page)
            }
            // WindowHost uses full-size content: keep the sheet clear of titlebar controls.
            WindowHost.windows["gallery"]?.styleMask.remove(.fullSizeContentView)
            WindowHost.windows["gallery"]?.setContentSize(page.size)
        }

        var body: some View {
            DotGridSheet(.window) {
                ScrollView {
                    HStack(alignment: .top, spacing: GalleryMetrics.columnGap) {
                        if page == .system {
                            VStack(spacing: GalleryMetrics.columnGap) {
                                typeCard; textureCard
                            }
                            VStack(spacing: GalleryMetrics.columnGap) {
                                colorCard; partsCard
                            }
                        } else {
                            VStack(spacing: GalleryMetrics.stackGap) {
                                buttonsCard; checklistCard; choicesCard
                            }
                            VStack(spacing: GalleryMetrics.stackGap) {
                                timeCard; motionCard; iconsCard
                            }
                        }
                    }
                    .padding(GalleryMetrics.outerInset)
                }
                .scrollIndicators(.hidden)
            }
            .motionBoundary()
        }

        private var typeCard: some View {
            galleryCard {
                sectionLabel(AppL10n.text("Typeface"))
                Text(AppL10n.text("Lexend"))
                    .font(Theme.font(.windowTitle, scaledSize: typefaceSize))
                Text("Aa Bb Cc Gg Qq Rr 0123456789")
                    .font(Theme.font(.body, scaledSize: specimenSize))
                    .accessibilityLabel(AppL10n.text("Letter and number samples"))
                detail(AppL10n.text("Wide, open letters with generous spacing, drawn to be easy to read at a glance."))
                divider.padding(.vertical, GalleryMetrics.smallGap)
                typeRow(AppL10n.text("Your day"), role: .cardTitle, description: AppL10n.text("20 bold · card titles"))
                typeRow(
                    AppL10n.text("Draft the test checklist"), role: .currentTask,
                    description: AppL10n.text("16 semibold · the current task"))
                typeRow(
                    AppL10n.text("Write the smoke tests"), role: .body,
                    description: AppL10n.text("14 medium · tasks and steps"))
                typeRow(
                    AppL10n.text("10:00 – 10:45 · 2 of 4"), role: .detail,
                    description: AppL10n.text("12 medium · times, never smaller"))
            }
        }

        private func typeRow(_ sample: String, role: DesignTokens.TypeRole, description: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: GalleryMetrics.rowGap) {
                Text(AppL10n.text(sample)).perchFont(role)
                    .frame(width: GalleryMetrics.typeColumn, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                detail(description).frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var textureCard: some View {
            galleryCard(spacing: GalleryMetrics.labelGap) {
                sectionLabel(AppL10n.text("Texture"))
                HStack(alignment: .top, spacing: Theme.Size.cardGap.value) {
                    textureSample(
                        AppL10n.text("Dot-grid paper"),
                        description: AppL10n.text("The sheet behind the cards, like a planner page.")
                    ) {
                        DotGridSheet(.window) { Color.clear }
                    }
                    textureSample(
                        AppL10n.text("Index cards"),
                        description: AppL10n.text("Flat color with a soft edge one shade deeper. No shadows.")
                    ) {
                        HStack(spacing: SurfaceMetrics.gap) {
                            ForEach([PerchSurface.butter, .blush, .mint], id: \.self) { surface in
                                RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value)
                                    .fill(Theme.fill(surface))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Theme.Size.segmentRadius.value)
                                            .strokeBorder(Theme.edge(surface), lineWidth: Theme.Size.cardEdge.value)
                                    }
                            }
                        }
                        .padding(Theme.Size.sheetPadding.value)
                        .background(Theme.sheet)
                    }
                }
            }
        }

        private func textureSample<Content: View>(
            _ title: String, description: String, @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: SurfaceMetrics.compactGap) {
                content()
                    .frame(height: GalleryMetrics.textureHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value)
                            .strokeBorder(Theme.edge(.paper), lineWidth: Theme.Size.cardEdge.value)
                    }
                    .accessibilityHidden(true)
                Text(AppL10n.text(title)).perchFont(.detailStrong)
                detail(description)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }

        private var colorCard: some View {
            galleryCard(spacing: GalleryMetrics.labelGap) {
                sectionLabel(AppL10n.text("Color, one job per card"))
                Grid(horizontalSpacing: SurfaceMetrics.gap, verticalSpacing: SurfaceMetrics.gap) {
                    GridRow {
                        swatch(.paper, title: "Paper", use: AppL10n.text("Checklist"))
                        swatch(.butter, title: "Butter", use: AppL10n.text("The task now"))
                        swatch(.blush, title: "Blush", use: AppL10n.text("Time set aside"))
                    }
                    GridRow {
                        swatch(.apricot, title: "Apricot", use: AppL10n.text("Parking lot"))
                        swatch(.mint, title: "Mint", use: AppL10n.text("Your day, done"))
                        VStack(alignment: .leading, spacing: .zero) {
                            Text(AppL10n.text("Persimmon")).perchFont(.detailStrong)
                            detail(AppL10n.text("One main button"), ink: .onBrand)
                            contrastLabel(foreground: .onBrand, background: .brandFill)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(GalleryMetrics.labelGap)
                        .foregroundStyle(Theme.onBrand)
                        .background(
                            Theme.brandFill, in: RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value))
                    }
                }
            }
        }

        @Environment(\.colorScheme) private var scheme
        private func swatch(_ surface: PerchSurface, title: String, use: String) -> some View {
            VStack(alignment: .leading, spacing: .zero) {
                Text(AppL10n.text(title)).perchFont(.detailStrong)
                detail(use)
                contrastLabel(foreground: .ink, background: surface.fill)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, GalleryMetrics.swatchPadding)
            .padding(.horizontal, GalleryMetrics.rowGap)
            .background(Theme.fill(surface), in: RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value)
                    .strokeBorder(Theme.edge(surface), lineWidth: Theme.Size.cardEdge.value)
            }
        }

        private func contrastLabel(foreground: DesignTokens.ColorToken, background: DesignTokens.ColorToken)
            -> some View
        {
            let appearance: DesignTokens.Appearance = scheme == .dark ? .dark : .light
            let ratio = GalleryMetrics.contrast(
                foreground.resolved(on: background, in: appearance), background.hex(in: appearance))
            return Text(AppL10n.format("Ink %.1f : 1", ratio)).perchFont(.detail)
        }

        private var partsCard: some View {
            galleryCard(spacing: GalleryMetrics.labelGap) {
                sectionLabel(AppL10n.text("The checklist's parts"))
                partRow(
                    AppL10n.text("A task"), description: AppL10n.text("a round box, something to finish today"),
                    value: $partTask, kind: .task)
                partRow(
                    AppL10n.text("A step"), description: AppL10n.text("a square box, one small action inside it"),
                    value: $partStep,
                    kind: .step)
                partRow(
                    AppL10n.text("Done"), description: AppL10n.text("fills green and counts toward the task"),
                    value: $partDone, kind: .step)
                HStack(spacing: GalleryMetrics.labelGap) {
                    PerchPill("10:00 – 10:45", surface: .blush)
                    detail(AppL10n.text("time set aside, shown on the task and in Your day"))
                }
                divider
                Grid(
                    alignment: .leading, horizontalSpacing: Theme.Size.cardGap.value,
                    verticalSpacing: SurfaceMetrics.compactGap
                ) {
                    GridRow {
                        keyHint(AppL10n.text("Return"), AppL10n.text("adds a task"));
                        keyHint(AppL10n.text("Tab"), AppL10n.text("makes it a step"))
                    }
                    GridRow {
                        keyHint(AppL10n.text("Shift Tab"), AppL10n.text("moves it back out"));
                        keyHint(AppL10n.text("Space"), AppL10n.text("checks it off"))
                    }
                }
            }
        }

        private func partRow(_ title: String, description: String, value: Binding<Bool>, kind: PerchCheckbox.Kind)
            -> some View
        {
            HStack(spacing: GalleryMetrics.labelGap) {
                PerchCheckbox(title: AppL10n.text(title), isOn: value, kind: kind)
                Text(AppL10n.text(title)).perchFont(.detailStrong)
                detail(description).frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private func keyHint(_ key: String, _ action: String) -> some View {
            HStack(spacing: GalleryMetrics.smallGap) {
                Text(AppL10n.text(key)).perchFont(.detailStrong)
                detail(action)
            }
        }

        private var buttonsCard: some View {
            galleryCard(spacing: GalleryMetrics.rowGap) {
                heading(
                    AppL10n.text("Buttons"), AppL10n.text("Hover lifts, press sinks, release springs back. Try them."))
                HStack(spacing: GalleryMetrics.labelGap) {
                    PerchButton("Start it now") { demo.running = true }
                    PerchButton("+5 min", kind: .soft) { demo.addTime() }
                    PerchButton("Not today", kind: .quiet) {
                        demo.running = false; demo.resetTime()
                    }
                    PerchButton(action: { demo.running.toggle() }) {
                        HStack(spacing: SurfaceMetrics.compactGap) {
                            Image(systemName: demo.running ? "pause.fill" : "play.fill")
                                .resizable().scaledToFit()
                                .frame(width: GalleryMetrics.ringStroke, height: GalleryMetrics.ringStroke)
                                .accessibilityHidden(true)
                            Text(AppL10n.text(demo.running ? "Pause" : "Start"))
                        }
                        .frame(width: Theme.Size.addFieldHeight.value * 2)
                        .contentTransition(.opacity)
                        .designMotion(.pop, value: demo.running)
                    }
                }
            }
        }

        private var checklistCard: some View {
            galleryCard(.butter, spacing: GalleryMetrics.labelGap) {
                heading(
                    AppL10n.text("Checking things off"),
                    AppL10n.text("The box pops, the tick draws itself, the count follows."))
                VStack(alignment: .leading, spacing: GalleryMetrics.labelGap) {
                    HStack(spacing: SurfaceMetrics.gap) {
                        PerchCheckbox(
                            title: AppL10n.text("Draft the test checklist"),
                            isOn: Binding(get: { demo.taskDone }, set: { demo.setTask($0) }),
                            surface: .butter, keyboardFocusable: false)
                        VStack(alignment: .leading, spacing: .zero) {
                            Text(AppL10n.text("Draft the test checklist")).perchFont(.currentTask)
                                .strikethrough(demo.taskDone)
                                .foregroundStyle(demo.taskDone ? Theme.ink3 : Theme.ink)
                                .designMotion(.strikeThrough, value: demo.taskDone)
                            Text(AppL10n.format("10:00 – 10:45 · %d of 4 steps", demo.doneCount))
                                .perchFont(.detail).foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: .zero)
                        HStack(spacing: GalleryMetrics.smallGap) {
                            ForEach(demo.steps.indices, id: \.self) { index in
                                Capsule().fill(demo.steps[index] ? Theme.doneFill : Theme.edge(.butter))
                                    .frame(width: Theme.Size.cardPadding.value, height: SurfaceMetrics.compactGap)
                                    .designMotion(.tickFill, value: demo.steps[index])
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    .background(rowFocus(0))
                    VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
                        ForEach(GalleryDemo.stepTitles.indices, id: \.self) { index in
                            HStack(spacing: SurfaceMetrics.gap) {
                                PerchCheckbox(
                                    title: AppL10n.text(GalleryDemo.stepTitles[index]),
                                    isOn: Binding(get: { demo.steps[index] }, set: { demo.setStep(index, done: $0) }),
                                    kind: .step, surface: .butter, keyboardFocusable: false)
                                Text(AppL10n.text(GalleryDemo.stepTitles[index])).perchFont(.body)
                                    .strikethrough(demo.steps[index])
                                    .foregroundStyle(demo.steps[index] ? Theme.ink3 : Theme.ink)
                                    .designMotion(.strikeThrough, value: demo.steps[index])
                            }
                            .frame(minHeight: Theme.Size.stepRowHeight.value, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowFocus(index + 1))
                        }
                    }
                    .padding(.leading, Theme.Size.minimumTarget.value + SurfaceMetrics.compactGap)
                }
                .focusable()
                .focused($checklistFocused)
                .focusEffectDisabled()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppL10n.text("Checking things off"))
                .onKeyPress(.upArrow) {
                    selectedRow = max(0, selectedRow - 1); return .handled
                }
                .onKeyPress(.downArrow) {
                    selectedRow = min(demo.steps.count, selectedRow + 1); return .handled
                }
                .onKeyPress(.home) {
                    selectedRow = 0; return .handled
                }
                .onKeyPress(.end) {
                    selectedRow = demo.steps.count; return .handled
                }
                .onKeyPress(.space) {
                    if selectedRow == 0 {
                        demo.setTask(!demo.taskDone)
                    } else {
                        demo.setStep(selectedRow - 1, done: !demo.steps[selectedRow - 1])
                    }
                    return .handled
                }
            }
        }

        private func rowFocus(_ row: Int) -> some View {
            FocusRing(
                shape: RoundedRectangle(cornerRadius: Theme.Size.stepCheckboxRadius.value),
                focused: checklistFocused && row == selectedRow, surface: .butter)
        }

        private var choicesCard: some View {
            galleryCard(spacing: GalleryMetrics.rowGap) {
                heading(
                    AppL10n.text("Switches and choices"),
                    AppL10n.text("The knob and the highlight slide; nothing jumps."))
                HStack(spacing: GalleryMetrics.rowGap) {
                    Text(AppL10n.text("Heads-up before a block ends")).perchFont(.body)
                    Spacer(minLength: .zero)
                    PerchSwitch(title: "Heads-up before a block ends", isOn: $demo.headsUp)
                }
                HStack(spacing: GalleryMetrics.rowGap) {
                    Text(AppL10n.text("Minutes to set aside")).perchFont(.body)
                    Spacer(minLength: .zero)
                    PerchSegmented(
                        title: "Minutes to set aside",
                        items: [15, 25, 45, 60].map { (value: $0, label: String($0)) },
                        selection: Binding(get: { demo.minutes }, set: { demo.selectMinutes($0) }))
                }
            }
        }

        private var timeCard: some View {
            galleryCard(.blush) {
                HStack(spacing: Theme.Size.windowPadding.value) {
                    // TODO: use the time-card lane's shared ring when that component is extracted.
                    ZStack {
                        Circle().stroke(Theme.edge(.blush), lineWidth: GalleryMetrics.ringStroke)
                        Circle().trim(from: .zero, to: demo.progress)
                            .stroke(
                                Theme.brandFill,
                                style: StrokeStyle(lineWidth: GalleryMetrics.ringStroke, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .designMotion(.time, value: demo.progress)
                        VStack(spacing: .zero) {
                            Text(demo.timeText).perchFont(.timer)
                            detail(AppL10n.text("left"))
                        }
                    }
                    .padding(GalleryMetrics.ringInset)
                    .frame(width: GalleryMetrics.ringSize, height: GalleryMetrics.ringSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AppL10n.format("%d minutes left of %d", (demo.seconds + 59) / 60, demo.minutes))
                    VStack(alignment: .leading, spacing: GalleryMetrics.labelGap) {
                        heading(
                            AppL10n.text("Time"),
                            AppL10n.text("The ring eases to its new length, so added time reads as a gift, not a jolt.")
                        )
                        HStack(spacing: SurfaceMetrics.gap) {
                            PerchButton("+5 min", surface: .blush) { demo.addTime() }
                            PerchButton("Back to 24:10", kind: .soft, surface: .blush) { demo.resetTime() }
                        }
                    }
                }
            }
        }

        private var motionCard: some View {
            galleryCard(spacing: GalleryMetrics.labelGap) {
                Text(AppL10n.text("Motion rules")).perchFont(.stripTitle)
                Grid(
                    alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Size.cardGap.value,
                    verticalSpacing: SurfaceMetrics.gap
                ) {
                    motionRow(
                        AppL10n.text("Press"), token: .press,
                        description: AppL10n.text("Sinks at once, so a click feels heard."))
                    motionRow(
                        AppL10n.text("Hover, color"), token: .hover, description: AppL10n.text("Ease out, no bounce."))
                    motionRow(
                        AppL10n.text("Pop, slide"), token: .pop,
                        description: AppL10n.text("One small overshoot for ticks, knobs and highlights."))
                    motionRow(
                        AppL10n.text("Time"), token: .time,
                        description: AppL10n.text("Slow and smooth for the ring and progress."))
                }
                divider
                detail(
                    AppL10n.text(
                        "Nothing loops or moves by itself. With Reduce Motion on, every change becomes a quick fade."))
            }
        }

        private func motionRow(_ title: String, token: DesignTokens.MotionToken, description: String) -> some View {
            GridRow {
                Text(AppL10n.text(title)).perchFont(.button)
                    .frame(width: GalleryMetrics.motionNameWidth, alignment: .leading)
                Text(AppL10n.format(token == .pop ? "%d ms spring" : "%d ms", Int((token.duration * 1000).rounded())))
                    .perchFont(.body).frame(width: GalleryMetrics.motionTimeWidth, alignment: .leading)
                detail(description)
            }
        }

        private var iconsCard: some View {
            galleryCard(spacing: GalleryMetrics.rowGap) {
                heading(
                    AppL10n.text("Icons"),
                    AppL10n.text("A 24 point grid and round strokes, to sit well beside the letters."))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: SurfaceMetrics.gap), count: 6),
                    spacing: GalleryMetrics.rowGap
                ) {
                    ForEach(GalleryMetrics.icons, id: \.0) { title, symbol in
                        VStack(spacing: SurfaceMetrics.compactGap) {
                            GalleryIcon(symbol: symbol)
                                .stroke(
                                    Theme.ink,
                                    style: StrokeStyle(
                                        lineWidth: Theme.Size.checkboxStroke.value, lineCap: .round, lineJoin: .round)
                                )
                                .frame(width: Theme.Size.switchHeight.value, height: Theme.Size.switchHeight.value)
                                .accessibilityHidden(true)
                            detail(title)
                        }
                    }
                }
            }
        }

        private func heading(_ title: String, _ subtitle: String) -> some View {
            VStack(alignment: .leading, spacing: .zero) {
                Text(AppL10n.text(title)).perchFont(.stripTitle)
                detail(subtitle)
            }
        }

        private func sectionLabel(_ title: String) -> some View {
            Text(AppL10n.text(title)).perchFont(.detailStrong).foregroundStyle(Theme.ink3)
        }

        private func detail(_ text: String, ink: DesignTokens.ColorToken = .ink2) -> some View {
            Text(AppL10n.text(text)).perchFont(.detail).foregroundStyle(Color.token(ink))
                .fixedSize(horizontal: false, vertical: true)
        }

        private var divider: some View {
            Rectangle().fill(Theme.edge(.paper)).frame(height: Theme.Size.cardEdge.value).accessibilityHidden(true)
        }

        private func galleryCard<Content: View>(
            _ surface: PerchSurface = .paper, spacing: CGFloat = SurfaceMetrics.gap,
            @ViewBuilder content: () -> Content
        ) -> some View {
            Card(surface) {
                VStack(alignment: .leading, spacing: spacing, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, GalleryMetrics.cardHorizontalInset)
                    .padding(.vertical, GalleryMetrics.cardVerticalInset)
            }
        }
    }

    /// Unit coordinates describe the glyphs; their rendered size and strokes use tokens.
    private struct GalleryIcon: Shape {
        let symbol: String

        func path(in rect: CGRect) -> Path {
            var path = Path()
            func line(_ points: [CGPoint], closed: Bool = false) {
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                if closed { path.closeSubpath() }
            }
            switch symbol {
            case "plus":
                line([CGPoint(x: 12, y: 5), CGPoint(x: 12, y: 19)])
                line([CGPoint(x: 5, y: 12), CGPoint(x: 19, y: 12)])
            case "checkmark.circle":
                path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
                line([CGPoint(x: 8, y: 12.4), CGPoint(x: 10.8, y: 15.2), CGPoint(x: 16, y: 9.6)])
            case "play":
                line([CGPoint(x: 8, y: 5.5), CGPoint(x: 8, y: 18.5), CGPoint(x: 18.5, y: 12)], closed: true)
            case "pause":
                line([CGPoint(x: 9, y: 5), CGPoint(x: 9, y: 19)])
                line([CGPoint(x: 15, y: 5), CGPoint(x: 15, y: 19)])
            case "clock":
                path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
                line([CGPoint(x: 12, y: 7), CGPoint(x: 12, y: 12), CGPoint(x: 15.5, y: 14)])
            case "bell":
                path.move(to: CGPoint(x: 6, y: 16))
                path.addLine(to: CGPoint(x: 6, y: 11))
                path.addCurve(to: CGPoint(x: 18, y: 11), control1: CGPoint(x: 6, y: 3), control2: CGPoint(x: 18, y: 3))
                for point in [
                    CGPoint(x: 18, y: 16), CGPoint(x: 19.5, y: 18), CGPoint(x: 4.5, y: 18), CGPoint(x: 6, y: 16),
                ] {
                    path.addLine(to: point)
                }
                line([CGPoint(x: 10, y: 21), CGPoint(x: 14, y: 21)])
            case "repeat":
                path.move(to: CGPoint(x: 4, y: 11))
                path.addLine(to: CGPoint(x: 4, y: 9))
                path.addQuadCurve(to: CGPoint(x: 7, y: 6), control: CGPoint(x: 4, y: 6))
                path.addLine(to: CGPoint(x: 19, y: 6))
                line([CGPoint(x: 16, y: 3), CGPoint(x: 19, y: 6), CGPoint(x: 16, y: 9)])
                path.move(to: CGPoint(x: 20, y: 13))
                path.addLine(to: CGPoint(x: 20, y: 15))
                path.addQuadCurve(to: CGPoint(x: 17, y: 18), control: CGPoint(x: 20, y: 18))
                path.addLine(to: CGPoint(x: 5, y: 18))
                line([CGPoint(x: 8, y: 15), CGPoint(x: 5, y: 18), CGPoint(x: 8, y: 21)])
            case "calendar":
                path.addRoundedRect(
                    in: CGRect(x: 4, y: 5, width: 16, height: 15), cornerSize: CGSize(width: 3, height: 3))
                line([CGPoint(x: 4, y: 10), CGPoint(x: 20, y: 10)])
                line([CGPoint(x: 8.5, y: 3), CGPoint(x: 8.5, y: 7)])
                line([CGPoint(x: 15.5, y: 3), CGPoint(x: 15.5, y: 7)])
            case "flag":
                line([
                    CGPoint(x: 6, y: 21), CGPoint(x: 6, y: 4), CGPoint(x: 17, y: 4), CGPoint(x: 14.5, y: 8.5),
                    CGPoint(x: 17, y: 13), CGPoint(x: 6, y: 13),
                ])
            case "list.bullet":
                for y: CGFloat in [7, 12, 17] {
                    line([CGPoint(x: 5, y: y), CGPoint(x: 8, y: y)])
                    line([CGPoint(x: 12, y: y), CGPoint(x: 19, y: y)])
                }
            case "parkingsign.square":
                path.addRoundedRect(
                    in: CGRect(x: 4, y: 4, width: 16, height: 16), cornerSize: CGSize(width: 4, height: 4))
                line([CGPoint(x: 10, y: 16), CGPoint(x: 10, y: 8), CGPoint(x: 13, y: 8)])
                path.addCurve(
                    to: CGPoint(x: 13, y: 13), control1: CGPoint(x: 16.3, y: 8), control2: CGPoint(x: 16.3, y: 13))
                path.addLine(to: CGPoint(x: 10, y: 13))
            case "mic":
                path.addRoundedRect(
                    in: CGRect(x: 9, y: 3, width: 6, height: 11), cornerSize: CGSize(width: 3, height: 3))
                path.move(to: CGPoint(x: 5.5, y: 11))
                path.addCurve(
                    to: CGPoint(x: 18.5, y: 11), control1: CGPoint(x: 5.5, y: 19.7), control2: CGPoint(x: 18.5, y: 19.7)
                )
                line([CGPoint(x: 12, y: 17.5), CGPoint(x: 12, y: 21)])
            default: break
            }
            let grid = Theme.Size.switchHeight.value
            return path.applying(CGAffineTransform(scaleX: rect.width / grid, y: rect.height / grid))
                .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        }
    }

    /// Gallery composition uses the same scale as the controls it demonstrates.
    private enum GalleryMetrics {
        static let columnGap = Theme.Size.switchHeight.value
        static let stackGap = Theme.Size.cardPadding.value
        static let outerInset = Theme.Size.minimumTarget.value - Theme.Size.windowPadding.value
        static let rowGap = Theme.Size.windowPadding.value - SurfaceMetrics.gap
        static let labelGap = Theme.Size.segmentRadius.value
        static let smallGap = Theme.Size.focusGap.value * 2
        static let cardHorizontalInset =
            Theme.Size.windowPadding.value - Theme.Size.cardPadding.value + Theme.Size.cardEdge.value
        static let cardVerticalInset = Theme.Size.checkboxStroke.value + Theme.Size.cardEdge.value
        static let typeColumn = Theme.Size.minimumTarget.value * 7 - SurfaceMetrics.compactGap
        static let textureHeight = Theme.Size.switchWidth.value * 2
        static let specimenSize = Theme.Size.cardPadding.value + Theme.Size.checkboxStroke.value / 2
        static let swatchPadding = Theme.Size.buttonSidePadding.value / 2
        static let ringSize = Theme.Size.addFieldHeight.value * 3
        static let ringStroke = DesignTokens.TypeRole.detail.spec.size
        static let ringInset = Theme.Size.pillMinHeight.value / 2
        static let motionNameWidth = Theme.Size.cardPadding.value * 6
        static let motionTimeWidth =
            Theme.Size.buttonHeight.value + Theme.Size.smallButtonHeight.value + Theme.Size.buttonHeight.value
        static let icons = [
            (AppL10n.text("Add"), "plus"), (AppL10n.text("Done"), "checkmark.circle"), (AppL10n.text("Start"), "play"),
            (AppL10n.text("Pause"), "pause"),
            (AppL10n.text("Time"), "clock"), (AppL10n.text("Remind"), "bell"), (AppL10n.text("Repeat"), "repeat"),
            (AppL10n.text("Day"), "calendar"),
            (AppL10n.text("Priority"), "flag"), (AppL10n.text("Steps"), "list.bullet"),
            (AppL10n.text("Park"), "parkingsign.square"), (AppL10n.text("Dictate"), "mic"),
        ]

        static func contrast(_ foreground: UInt32, _ background: UInt32) -> Double {
            func luminance(_ rgb: UInt32) -> Double {
                let channels = [16, 8, 0].map { shift -> Double in
                    let component = Double((rgb >> shift) & 255) / 255
                    return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
                }
                return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
            }
            let first = luminance(foreground)
            let second = luminance(background)
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }
    }
#endif
