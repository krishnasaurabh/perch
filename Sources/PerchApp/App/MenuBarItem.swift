import AppKit
import Combine
import PlannerCore
import PerchUI

/// Owns the real status item, its system menu and the saved-preference subscription.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let store: PlannerStore
    private let statusBar: NSStatusBar
    private let navigate: (MenuBarModel.Action) -> Void
    private let shortcut: () -> ShortcutKey
    private let clock: () -> Date
    private var observations = Set<AnyCancellable>()
    private var ticking: AnyCancellable?
    private var menuOpen = false
    private var stopped = false
    private var snapshot: Planner
    private(set) var presentation: MenuBarModel
    let menu = MenuBarSystemMenu()
    private(set) var runningView: MenuBarRunningView?

    @MainActor
    private final class Lifetime {
        let bar: NSStatusBar
        var item: NSStatusItem?
        init(_ bar: NSStatusBar) { self.bar = bar }
    }
    private let lifetime: MainActorLifetime<Lifetime>
    var statusItem: NSStatusItem? { lifetime.state.item }

    init(
        store: PlannerStore, statusBar: NSStatusBar = .system,
        shortcut: @escaping () -> ShortcutKey = { ShortcutStore.load() }, clock: (() -> Date)? = nil,
        navigate: @escaping (MenuBarModel.Action) -> Void = { _ in }
    ) {
        self.store = store
        self.statusBar = statusBar
        self.navigate = navigate
        self.shortcut = shortcut
        self.clock = clock ?? { store.engine.now() }
        snapshot = store.planner
        presentation = MenuBarModel(
            planner: store.planner, today: store.today, now: self.clock(), addShortcut: shortcut())
        lifetime = MainActorLifetime(Lifetime(statusBar)) { state in
            if let item = state.item { state.bar.removeStatusItem(item) }
        }
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        // Published emits before the store property changes. Always project the incoming value.
        store.$planner.sink { [weak self] planner in self?.refresh(planner) }.store(in: &observations)
        store.$today.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.refresh(self.store.planner)
        }.store(in: &observations)
        Publishers.Merge(
            NotificationCenter.default.publisher(for: ShortcutStore.didChange),
            NotificationCenter.default.publisher(for: ShortcutStore.didFail)
        ).sink { [weak self] _ in
            guard let self else { return }
            self.refresh(self.store.planner)
        }.store(in: &observations)
    }

    func stop() {
        stopped = true
        ticking = nil
        observations.removeAll()
        menu.cancelTracking()
        removeItem()
    }

    private func removeItem() {
        guard let item = statusItem else { return }
        item.isVisible = false
        statusBar.removeStatusItem(item)
        lifetime.state.item = nil
    }

    private func refresh(_ planner: Planner) {
        guard !stopped else { return }
        snapshot = planner
        let engine = PlannerEngine(planner: planner, now: clock)
        presentation = MenuBarModel(planner: planner, today: engine.today, now: clock(), addShortcut: shortcut())
        if presentation.item.isVisible {
            let item: NSStatusItem
            if let existing = statusItem {
                item = existing
            } else {
                item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
                item.menu = menu
                lifetime.state.item = item
            }
            let image = MenuBarArtwork.image(for: presentation.item)
            item.length = presentation.item.isPill ? image.size.width : NSStatusItem.squareLength
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.title = ""
            item.button?.toolTip = presentation.item.accessibilityLabel
            item.button?.setAccessibilityLabel(presentation.item.accessibilityLabel)
            item.button?.setAccessibilityIdentifier("menubar.item")
        } else {
            if menuOpen { menu.cancelTracking() }
            removeItem()
        }
        updateMenu()
        updateClock()
    }

    private func updateMenu() {
        let identifiers = presentation.entries.map { entry in
            entry == .runningBlock ? "menubar.runningBlock" : entry.action.map { "menubar.\($0.rawValue)" }
        }
        if menu.items.filter({ !$0.isHidden }).map({ $0.identifier?.rawValue }) != identifiers {
            if menuOpen { menu.cancelTracking() }
            menu.removeAllItems()
            runningView = nil
            for entry in presentation.entries {
                switch entry {
                case .separator: menu.addItem(.separator())
                case .runningBlock:
                    let item = NSMenuItem()
                    item.identifier = NSUserInterfaceItemIdentifier("menubar.runningBlock")
                    item.representedObject = MenuBarModel.Action.pauseOrContinue.rawValue
                    item.target = self
                    item.action = #selector(selectItem(_:))
                    let view = MenuBarRunningView { [weak self] in self?.perform($0) }
                    runningView = view
                    item.view = view
                    menu.addItem(item)
                default:
                    guard let action = entry.action else { continue }
                    let item = NSMenuItem(title: action.title, action: #selector(selectItem(_:)), keyEquivalent: "")
                    item.identifier = NSUserInterfaceItemIdentifier("menubar.\(action.rawValue)")
                    item.representedObject = action.rawValue
                    item.target = self
                    menu.addItem(item)
                }
            }
            if presentation.block != nil {
                // A custom view cannot receive key events. Keep +5 min's native equivalent
                // on a hidden item, rather than adding a duplicate visible menu row.
                let key = NSMenuItem(
                    title: MenuBarModel.Action.addFiveMinutes.title, action: #selector(selectItem(_:)),
                    keyEquivalent: "+")
                key.representedObject = MenuBarModel.Action.addFiveMinutes.rawValue
                key.target = self
                key.isHidden = true
                key.allowsKeyEquivalentWhenHidden = true
                menu.addItem(key)
            }
        }
        for item in menu.items {
            guard let raw = item.representedObject as? String, let action = MenuBarModel.Action(rawValue: raw) else {
                continue
            }
            item.isEnabled = presentation.isEnabled(action)
            item.state = action == .privacy && presentation.privacyEnabled ? .on : .off
            let key = presentation.shortcut(for: action)
            item.keyEquivalent = key?.key ?? ""
            item.keyEquivalentModifierMask = key?.modifiers.menuFlags ?? []
        }
        if let block = presentation.block {
            runningView?.update(block: block, canExtend: presentation.isEnabled(.addFiveMinutes))
        }
        menu.items.first { $0.identifier?.rawValue == "menubar.runningBlock" }?.title = presentation.block?.title ?? ""
    }

    private func updateClock() {
        if presentation.needsClock(menuOpen: menuOpen) {
            guard ticking == nil else { return }
            ticking = Timer.publish(every: MenuBarTokens.clockInterval, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.refresh(self.snapshot)
                }
        } else {
            ticking = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh(store.planner)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        updateClock()
    }

    @objc private func selectItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MenuBarModel.Action(rawValue: raw) else {
            return
        }
        perform(action)
    }

    private func perform(_ action: MenuBarModel.Action) {
        guard !stopped, presentation.isEnabled(action) else { return }
        switch action {
        case .privacy:
            store.apply { try $0.updatePreference(.hideCountsAndTimes(!$0.planner.preferences.hideCountsAndTimes)) }
        case .pauseOrContinue, .addFiveMinutes:
            guard let expected = presentation.focus else { return }
            store.apply { commands in
                // Never apply a stale row's click to a replacement block loaded under the file lock.
                guard let current = commands.planner.focus, current.state != .finished,
                    current.taskID == expected.taskID, current.startedAt == expected.startedAt
                else { return }
                if action == .addFiveMinutes {
                    if current.limit != nil { try commands.extendTimer(minutes: 5) }
                } else if current.state == .running {
                    try commands.pauseTimer()
                } else {
                    try commands.resumeTimer()
                }
            }
        default:
            menu.cancelTracking()
            navigate(action)
        }
    }
}

/// Native tracking, arrow navigation, menu roles and cancellation remain owned by macOS.
/// The two controls in the custom row also have the Time group's keyboard equivalents.
@MainActor
final class MenuBarSystemMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.isARepeat else { return false }
        return super.performKeyEquivalent(with: event)
    }
}

private extension ShortcutModifiers {
    var menuFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

@MainActor
private enum MenuBarArtwork {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static func font(_ role: DesignTokens.TypeRole) -> NSFont {
        let spec = role.spec
        if LexendRegistration.shared.isAvailable,
            let font = NSFont(name: DesignTokens.FontResource.postScriptName(for: spec.weight), size: spec.size)
        {
            return font
        }
        return NSFont.monospacedDigitSystemFont(
            ofSize: spec.size, weight: spec.weight == .semibold ? .semibold : .medium)
    }

    static func image(for item: MenuBarModel.Item) -> NSImage {
        let font = font(.detailStrong)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color(item.isDimmed ? MenuBarTokens.pausedInk : MenuBarTokens.ink),
        ]
        let text = NSAttributedString(string: item.text ?? "", attributes: attributes)
        let width =
            item.isPill
            ? MenuBarTokens.padding * 2 + MenuBarTokens.markSize
                + (item.showsDot ? MenuBarTokens.gap + MenuBarTokens.dotDiameter : 0)
                + (item.text != nil ? MenuBarTokens.gap + ceil(text.size().width) : 0)
            : MenuBarTokens.markSize
        let image = NSImage(size: NSSize(width: width, height: MenuBarTokens.height))
        image.lockFocus()
        if item.isPill {
            color(MenuBarTokens.background).setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: image.size), xRadius: MenuBarTokens.height / 2,
                yRadius: MenuBarTokens.height / 2
            ).fill()
        }
        let x = item.isPill ? MenuBarTokens.padding : 0
        let ink = color(item.isPill ? MenuBarTokens.ink : MenuBarTokens.background)
        ink.setStroke()
        let baseline = (MenuBarTokens.height - MenuBarTokens.ringDiameter) / 2
        let ring = NSBezierPath(
            ovalIn: NSRect(
                x: x + (MenuBarTokens.markSize - MenuBarTokens.ringDiameter) / 2,
                y: baseline, width: MenuBarTokens.ringDiameter, height: MenuBarTokens.ringDiameter))
        ring.lineWidth = MenuBarTokens.markStroke
        ring.stroke()
        let perch = NSBezierPath()
        perch.lineWidth = MenuBarTokens.markStroke
        perch.lineCapStyle = .round
        perch.move(to: NSPoint(x: x + (MenuBarTokens.markSize - MenuBarTokens.perchWidth) / 2, y: baseline))
        perch.line(to: NSPoint(x: x + (MenuBarTokens.markSize + MenuBarTokens.perchWidth) / 2, y: baseline))
        perch.stroke()
        var nextX = x + MenuBarTokens.markSize + MenuBarTokens.gap
        if item.showsDot {
            color(MenuBarTokens.dot).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: nextX, y: (MenuBarTokens.height - MenuBarTokens.dotDiameter) / 2,
                    width: MenuBarTokens.dotDiameter, height: MenuBarTokens.dotDiameter)
            ).fill()
            nextX += MenuBarTokens.dotDiameter + MenuBarTokens.gap
        }
        if item.text != nil { text.draw(at: NSPoint(x: nextX, y: (MenuBarTokens.height - text.size().height) / 2)) }
        image.unlockFocus()
        image.isTemplate = !item.isPill
        image.accessibilityDescription = item.accessibilityLabel
        return image
    }
}

/// Only the running block is custom. The rest of the menu uses native NSMenuItems.
@MainActor
final class MenuBarRunningView: NSView {
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let pauseButton = NSButton(title: "", target: nil, action: nil)
    let extendButton = NSButton(title: MenuBarModel.Action.addFiveMinutes.title, target: nil, action: nil)
    private let action: (MenuBarModel.Action) -> Void
    private let stack = NSStackView()

    init(action: @escaping (MenuBarModel.Action) -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: MenuBarTokens.menuWidth, height: 0))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MenuBarTokens.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (label, role) in [(titleLabel, DesignTokens.TypeRole.currentTask), (detailLabel, .detail)] {
            label.font = MenuBarArtwork.font(role)
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = MenuBarTokens.menuWidth - DesignTokens.Size.cardPadding.value * 2
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            stack.addArrangedSubview(label)
        }
        let buttons = NSStackView(views: [pauseButton, extendButton])
        buttons.spacing = MenuBarTokens.gap
        for button in [pauseButton, extendButton] {
            button.bezelStyle = .rounded
            button.font = MenuBarArtwork.font(.button)
            button.target = self
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.Size.smallButtonHeight.value)
                .isActive = true
        }
        pauseButton.action = #selector(pause)
        extendButton.action = #selector(extend)
        pauseButton.setAccessibilityIdentifier("menubar.pause")
        extendButton.setAccessibilityIdentifier("menubar.extend")
        stack.addArrangedSubview(buttons)
        addSubview(stack)
        let inset = DesignTokens.Size.cardPadding.value
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func update(block: MenuBarModel.Block, canExtend: Bool) {
        titleLabel.stringValue = block.title
        detailLabel.stringValue = block.detail
        pauseButton.title = block.pauseTitle
        pauseButton.setAccessibilityLabel(block.pauseTitle)
        pauseButton.toolTip = "⌘P"
        extendButton.toolTip = "⌘+"
        extendButton.isEnabled = canExtend
        setFrameSize(NSSize(width: MenuBarTokens.menuWidth, height: fittingSize.height))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance: DesignTokens.Appearance =
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        MenuBarArtwork.color(DesignTokens.ColorToken.butter.hex(in: appearance)).setFill()
        let rect = bounds.insetBy(dx: MenuBarTokens.gap, dy: MenuBarTokens.gap)
        NSBezierPath(
            roundedRect: rect, xRadius: DesignTokens.Size.currentTaskRadius.value,
            yRadius: DesignTokens.Size.currentTaskRadius.value
        ).fill()
        titleLabel.textColor = MenuBarArtwork.color(DesignTokens.ColorToken.ink.hex(in: appearance))
        detailLabel.textColor = MenuBarArtwork.color(DesignTokens.ColorToken.ink2.hex(in: appearance))
        pauseButton.bezelColor = MenuBarArtwork.color(DesignTokens.ColorToken.brandFill.hex(in: appearance))
        pauseButton.contentTintColor = MenuBarArtwork.color(DesignTokens.ColorToken.onBrand.hex(in: appearance))
    }

    @objc private func pause() { action(.pauseOrContinue) }
    @objc private func extend() { action(.addFiveMinutes) }
}

#if DEBUG || PERCH_TESTING
    extension AppDelegate.PreviewTarget {
        @MainActor
        static func menuBar(_ mode: MenuBarDisplay, privacy: Bool = false, block: Bool = false) -> Self {
            .window("menubar-preview") { MenuBarPreview.show(mode, app: $0, privacy: privacy, block: block) }
        }
    }

    /// Captures the production status image, including a genuinely absent Hidden item.
    /// The block target additionally hosts the exact custom view used by NSMenu.
    @MainActor
    enum MenuBarPreview {
        static func show(_ mode: MenuBarDisplay, app: AppDelegate, privacy: Bool = false, block: Bool = false) {
            app.store.apply { commands in
                try commands.updatePreference(.menuBarDisplay(mode))
                try commands.updatePreference(.hideCountsAndTimes(privacy))
            }
            guard let item = app.menuBarItem else { return }
            let imageView = NSImageView()
            imageView.image = item.statusItem?.button?.image
            imageView.imageScaling = .scaleNone
            imageView.contentTintColor = imageView.image?.isTemplate == true ? .labelColor : nil
            let stack = NSStackView(views: [imageView])
            stack.orientation = .vertical
            stack.spacing = DesignTokens.Size.cardGap.value
            stack.edgeInsets = NSEdgeInsets(
                top: DesignTokens.Size.cardPadding.value, left: DesignTokens.Size.cardPadding.value,
                bottom: DesignTokens.Size.cardPadding.value, right: DesignTokens.Size.cardPadding.value)
            if block, let view = item.runningView, let state = item.presentation.block {
                let copy = MenuBarRunningView { _ in }
                copy.update(block: state, canExtend: item.presentation.isEnabled(.addFiveMinutes))
                copy.setFrameSize(view.frame.size)
                stack.addArrangedSubview(copy)
            }
            let height = block ? stack.fittingSize.height : MenuBarTokens.previewHeight
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: MenuBarTokens.previewWidth, height: height),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = AppL10n.text("Menu bar")
            window.isReleasedWhenClosed = false
            window.contentView = stack
            WindowHost.windows["menubar-preview"] = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }
#endif
