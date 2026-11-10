import AppKit
import Combine
import PlannerCore
import PerchUI
import SwiftUI

/// The workspace pages, in picker order. Insights is a page of its own so Today stays clean (tenet 1).
enum NotchPage: String, CaseIterable, Identifiable {
    case home, week, clips, insights
    var id: String { rawValue }
    var title: String { ["home": "Today", "week": "Week", "clips": "Clips", "insights": "Insights"][rawValue]! }
    var symbol: String {
        ["home": "sun.max", "week": "calendar", "clips": "paperclip", "insights": "chart.bar"][rawValue]!
    }
}

/// UI state shared by every notch on every screen. Only the active screen (`screenID`) opens or shows activity.
@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var page: NotchPage = .home
    @Published var activity: PresentedNotchActivity?
    /// The screen whose notch is open or showing activity.
    @Published var screenID: CGDirectDisplayID = 0
    /// Geometry of the active screen.
    @Published var geometry: NotchGeometry?
    @Published var now = Date()
    /// Opened with the keyboard: stay open until Esc or a click outside.
    @Published var pinned = false
    @Published var editingTaskID: UUID?
    @Published var detailsTaskID: UUID?
    /// Explicit opening intent, not passive hover/drag. A new ID also refocuses an already-open page.
    @Published var captureFocusRequest: UUID?

    /// Nil in production (live system preference); deterministic override for in-process probes.
    let motionPolicyOverride: MotionPolicy?
    var motionPolicy: MotionPolicy { motionPolicyOverride ?? .system }
    init(motionPolicy: MotionPolicy? = nil) { self.motionPolicyOverride = motionPolicy }

    func open(page: NotchPage? = nil, pinned: Bool = false) {
        if let page { self.page = page }
        self.pinned = pinned || self.pinned
        Motion.animate(Motion.open, policy: motionPolicy) { expanded = true }
    }

    func close() {
        pinned = false
        detailsTaskID = nil
        captureFocusRequest = nil
        Motion.animate(Motion.close, policy: motionPolicy) { expanded = false }
    }

    func show(_ a: PresentedNotchActivity, for seconds: Double? = nil) {
        Motion.animate(Motion.activity, policy: motionPolicy) { activity = a }
        if let s = seconds {
            let id = a.id
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
                if self?.activity?.id == id { self?.dismissActivity() }
            }
        }
    }

    func dismissActivity() {
        Motion.animate(Motion.activityDismiss, policy: motionPolicy) { activity = nil }
    }

    /// The side the closed notch shows a running timer on, or nil (no timer, or hidden): only then does it grow a pill.
    static func timerShowing(_ store: PlannerStore) -> NotchTimerPlacement? {
        guard let f = store.planner.focus, f.state != .finished else { return nil }
        let side = store.prefs.notchTimerPlacement
        return side == .hidden ? nil : side
    }
}

/// Per-screen state the root view of that screen's window observes.
@MainActor
final class NotchScreenState: ObservableObject {
    let id: CGDirectDisplayID
    @Published var geometry: NotchGeometry
    @Published var fullScreen = false
    init(id: CGDirectDisplayID, geometry: NotchGeometry) { self.id = id; self.geometry = geometry }
}

/// Owns one notch window per screen: rebuilds them on screen changes, routes the mouse so only the visible shape
/// takes clicks, opens on hover, ⌥N or a drag, and hides each screen's notch while a full-screen app covers it.
@MainActor
final class NotchController {
    let store: PlannerStore
    let model: NotchModel
    let services: Services

    private struct Slot { let panel: NotchPanel; let state: NotchScreenState }
    private var slots: [CGDirectDisplayID: Slot] = [:]
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var tick: Timer?
    private var pointerTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var hotKey: GlobalHotKey?
    /// Drag pasteboard change count while no button is held; a different count with the button down means a drag.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var openedForDrop = false

    init(store: PlannerStore, model: NotchModel, services: Services) {
        self.store = store; self.model = model; self.services = services
    }

    func start() {
        updateScreens()
        model.$page.removeDuplicates().sink { [weak store] page in
            guard let store else { return }
            let count = page == .week ? 7 : 1
            store.materializeRepeats(on: (0..<count).map { store.today.adding(days: $0) })
        }.store(in: &cancellables)

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        monitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
                Task { @MainActor in self?.handle(e) }
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                Task { @MainActor in self?.handle(e) }
                return e
            } as Any)
        // Event monitors miss moves inside other apps' drag sessions; a light poll keeps routing and drop detection exact.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackPointer() }
        }

        hotKey = GlobalHotKey(keyCode: 45 /* N */, modifiers: .option) { [weak self] in
            guard let self else { return }
            if self.model.expanded {
                self.model.close()
            } else {
                self.open(on: self.slotUnderPointer() ?? self.preferredID(), pinned: true, activate: true)
            }
        }

        model.$expanded.removeDuplicates().sink { [weak self] open in
            guard let self else { return }
            if !open {
                self.openedForDrop = false
                for s in self.slots.values { s.panel.resignKey() }
            }
            // Routing reads the new state on the next run-loop pass, after @Published has stored it.
            DispatchQueue.main.async {
                self.updateMouseRouting(); self.applyFullScreen()
            }
        }.store(in: &cancellables)
        model.$activity.sink { [weak self] _ in DispatchQueue.main.async { self?.updateMouseRouting() } }.store(
            in: &cancellables)
        store.$planner.map(\.preferences.showOnDisplay).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateScreens() }
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateScreens() }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.checkFullScreenSoon() }
            }
        }
        NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main) {
            [weak self] n in
            Task { @MainActor in
                guard let self else { return }
                self.open(
                    on: self.slotUnderPointer() ?? self.preferredID(), page: n.object as? NotchPage, pinned: true,
                    activate: true)
            }
        }

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }

        // `--dump-layout <path>`: write every screen's live frames as JSON (CI artifact, real-Mac checks).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dump-layout"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self,
                    let data = try? JSONSerialization.data(
                        withJSONObject: self.layoutDump(), options: [.prettyPrinted, .sortedKeys])
                else { return }
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        // `--snapshot <dir>`: render each notch window's own content to PNG (no Screen Recording permission needed).
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.snapshot(into: dir) }
        }
    }

    /// Debug render: grey backdrop, the screen's menu-bar band in a lighter grey, the window's content, and the camera
    /// housing outlined in red, so a reviewer can see whether the wings sit beside the real housing and whether the open
    /// shell clears the menu bar (its top corners/shoulders show against the band). Pixel scale follows the screen.
    func snapshot(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for slot in slots.values {
            guard let view = slot.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                let out = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let ctx = NSGraphicsContext(bitmapImageRep: out)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let size = view.bounds.size
            ctx.cgContext.scaleBy(x: CGFloat(out.pixelsWide) / size.width, y: CGFloat(out.pixelsHigh) / size.height)
            NSColor(calibratedRed: 0.47, green: 0.49, blue: 0.53, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let w = slot.panel.frame, sf = slot.state.geometry.screenFrame
            let bar =
                slot.state.geometry.screen.menuBarHeight > 0
                ? slot.state.geometry.screen.menuBarHeight : NotchLayout.fallbackMenuBarHeight
            NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
            NSRect(x: sf.minX, y: sf.maxY - bar, width: sf.width, height: bar).offsetBy(dx: -w.minX, dy: -w.minY).fill()
            rep.draw(
                in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
            if let cam = slot.state.geometry.camera {
                NSColor.systemRed.setStroke()
                let path = NSBezierPath(rect: cam.offsetBy(dx: -w.minX, dy: -w.minY).insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = out.representation(using: .png, properties: [:]) else { continue }
            try? png.write(
                to: dir.appendingPathComponent("notch-\(slot.state.id)-\(model.expanded ? "open" : "closed").png"))
        }
    }

    // MARK: Screens

    /// Screens that get a notch window, honoring "Show Perch on".
    private func eligibleScreens() -> [NSScreen] {
        let all = NSScreen.screens
        switch store.prefs.showOnDisplay {
        case nil: return all
        case "builtIn":
            let b = all.filter(\.isBuiltIn)
            return b.isEmpty ? all : b
        case let name?:
            let m = all.filter { $0.localizedName == name }
            return m.isEmpty ? all : m
        }
    }

    /// One window per screen: add windows for new screens, drop them for removed ones, re-lay out the rest.
    func updateScreens() {
        let screens = eligibleScreens()
        let ids = Set(screens.map(\.displayID))
        for (id, slot) in slots where !ids.contains(id) {
            slot.panel.orderOut(nil)
            slot.panel.close()
            slots[id] = nil
        }
        for screen in screens {
            let g = NotchGeometry(screen: screen)
            if let slot = slots[screen.displayID] {
                if slot.state.geometry != g { slot.state.geometry = g }
                if slot.panel.frame != g.window { slot.panel.setFrame(g.window, display: true) }
            } else {
                slots[screen.displayID] = makeSlot(id: screen.displayID, geometry: g)
            }
        }
        if slots[model.screenID] == nil {
            if model.expanded { model.close() }
            model.screenID = preferredID()
        }
        model.geometry = slots[model.screenID]?.state.geometry
        applyFullScreen()
        updateMouseRouting()
    }

    private func makeSlot(id: CGDirectDisplayID, geometry g: NotchGeometry) -> Slot {
        let state = NotchScreenState(id: id, geometry: g)
        let panel = NotchPanel(frame: g.window)
        let root = NotchRootView()
            .modifier(MotionScript.PolicyProbe())
            .environment(\.motionPolicyOverride, model.motionPolicyOverride)
            .environmentObject(store).environmentObject(model).environmentObject(services).environmentObject(state)
        let host = NotchHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: g.window.size)
        host.autoresizingMask = [.width, .height]
        // The window covers the camera housing; never let SwiftUI inset or shift content for that "unsafe" area.
        host.safeAreaRegions = []
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.model.close() }
        panel.onUndo = { [weak self] redo in redo ? self?.store.redo() : self?.store.undo() }
        panel.setFrame(g.window, display: false)
        panel.orderFrontRegardless()
        return Slot(panel: panel, state: state)
    }

    /// Where ⌥N, the menu and `--preview-open` open when the pointer isn't on a notch screen.
    func preferredID() -> CGDirectDisplayID {
        let screens = eligibleScreens()
        let pick =
            screens.first(where: { $0.isBuiltIn && NotchLayout.camera(screen: .init($0)) != nil })
            ?? screens.first(where: { $0 == NSScreen.main }) ?? screens.first
        return pick?.displayID ?? 0
    }

    private func slotUnderPointer() -> CGDirectDisplayID? {
        let ordered = Array(slots.keys)
        let i = NotchLayout.screenIndex(at: NSEvent.mouseLocation, in: ordered.map { slots[$0]!.state.geometry.screen })
        return i.map { ordered[$0] }
    }

    private func open(on id: CGDirectDisplayID, page: NotchPage? = nil, pinned: Bool = false, activate: Bool = false) {
        guard let slot = slots[id] else { return }
        if model.screenID != id {
            if model.expanded { model.close() }
            model.screenID = id
            model.geometry = slot.state.geometry
        }
        slot.panel.orderFrontRegardless()
        model.open(page: page, pinned: pinned)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            slot.panel.makeKey()
            model.captureFocusRequest = UUID()
        }
    }

    // MARK: Visibility

    private func timerShowing() -> NotchTimerPlacement? { NotchModel.timerShowing(store) }

    /// The drawn notch is hidden on screens without a housing when the external-display preference is off, unless it is open there.
    private func drawn(_ slot: Slot) -> Bool {
        if slot.state.fullScreen && !(model.expanded && model.screenID == slot.state.id) { return false }
        if NotchLayout.closedNotchVisible(screen: slot.state.geometry.screen, enabled: store.prefs.notchOnMonitors) {
            return true
        }
        return model.screenID == slot.state.id && (model.expanded || model.activity != nil)
    }

    func checkFullScreenSoon() {
        applyFullScreen()
        // Spaces animate; the window list settles a moment later.
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.applyFullScreen() }
        }
    }

    /// Per screen: a full-screen app hides that screen's notch only.
    private func applyFullScreen() {
        let windows = WindowList.current()
        let primary = NSScreen.screens.first?.frame.height ?? 0
        for slot in slots.values {
            let fs = NotchLayout.isFullScreen(
                screen: slot.state.geometry.screen, windows: windows, primaryHeight: primary)
            if slot.state.fullScreen != fs { slot.state.fullScreen = fs }
            let keep = !fs || (model.expanded && model.screenID == slot.state.id)
            if keep && !slot.panel.isVisible { slot.panel.orderFrontRegardless() }
            if !keep && slot.panel.isVisible { slot.panel.orderOut(nil) }
        }
    }

    // MARK: Mouse routing

    /// Click-through everywhere except the visible shape: the open workspace, or the closed silhouette (with its activity strip).
    private func updateMouseRouting(at p: NSPoint = NSEvent.mouseLocation) {
        for slot in slots.values {
            let interactive = drawn(slot) && isOnShape(p, slot)
            if slot.panel.ignoresMouseEvents == interactive { slot.panel.ignoresMouseEvents = !interactive }
        }
    }

    /// Exactly the drawn outline: the open workspace (rounded corners and shoulders excluded), or the closed silhouette.
    private func isOnShape(_ p: NSPoint, _ slot: Slot) -> Bool {
        let active = model.screenID == slot.state.id
        return slot.state.geometry.shapeContains(
            p, expanded: active && model.expanded, timer: timerShowing(),
            activity: active && model.activity != nil)
    }

    private func hoverRect(_ slot: Slot) -> NSRect {
        let active = model.screenID == slot.state.id
        return slot.state.geometry.hover(
            expanded: active && model.expanded, timer: timerShowing(), activity: active && model.activity != nil)
    }

    // MARK: Pointer

    private func trackPointer() {
        let p = NSEvent.mouseLocation
        updateMouseRouting(at: p)
        watchForDrop(at: p)
    }

    /// A file, link or text dragged onto a notch opens that screen's workspace on Clips, ready for the drop.
    private func watchForDrop(at p: NSPoint) {
        let pb = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else { dragBaseline = pb.changeCount; return }
        guard pb.changeCount != dragBaseline, !(model.expanded && openedForDrop),
            let id = slotUnderPointer(), let slot = slots[id], !slot.state.fullScreen,
            NotchLayout.contains(hoverRect(slot), pointer: p)
                || (model.expanded && model.screenID == id && isOnShape(p, slot)),
            let types = pb.types, types.contains(where: { [.fileURL, .URL, .string].contains($0) })
        else { return }
        openedForDrop = true
        open(on: id, page: .clips)
        updateMouseRouting(at: p)
    }

    private func handle(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        updateMouseRouting(at: p)
        let prefs = store.prefs

        if e.type == .leftMouseDown {
            if model.expanded {
                // Same test as mouse routing: a click that went through to another app (menu bar, a corner) closes.
                let inside = slots[model.screenID].map { isOnShape(p, $0) } ?? false
                if !inside && !anySheetOrPopoverOpen() { model.close() }
            } else if let id = slotUnderPointer(), let slot = slots[id], drawn(slot),
                NotchLayout.contains(hoverRect(slot), pointer: p)
            {
                if prefs.notchOpenTrigger == .click || (prefs.notchOpenTrigger == .doubleClick && e.clickCount >= 2) {
                    open(on: id, activate: true)
                }
            }
            return
        }
        if e.type == .leftMouseDragged { watchForDrop(at: p) }

        if !model.expanded {
            guard prefs.notchOpenTrigger == .hover, e.type == .mouseMoved,
                let id = slotUnderPointer(), let slot = slots[id], drawn(slot),
                NotchLayout.contains(hoverRect(slot), pointer: p)
            else { openWork?.cancel(); openWork = nil; return }
            guard openWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.openWork = nil
                guard let slot = self.slots[id],
                    NotchLayout.contains(self.hoverRect(slot), pointer: NSEvent.mouseLocation)
                else { return }
                self.open(on: id)
            }
            openWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
            return
        }

        // Open: the hover area is exactly the workspace. Close after the pointer has been away a moment,
        // unless opened from the keyboard or a drag is still in flight.
        if pointerInWorkspace(p) || model.pinned || anySheetOrPopoverOpen() || e.type == .leftMouseDragged {
            closeWork?.cancel(); closeWork = nil
        } else if closeWork == nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.closeWork = nil
                if !self.pointerInWorkspace(NSEvent.mouseLocation) && !self.model.pinned
                    && NSEvent.pressedMouseButtons & 1 == 0
                {
                    self.model.close()
                }
            }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
        }
    }

    /// Keeps it open: the workspace, plus (flat screen) the menu-bar strip the pointer crosses to reach it.
    private func pointerInWorkspace(_ p: NSPoint) -> Bool {
        guard let slot = slots[model.screenID] else { return false }
        if NotchLayout.contains(hoverRect(slot), pointer: p) { return true }
        guard model.expanded,
            let bridge = slot.state.geometry.openBridge(timer: timerShowing(), activity: model.activity != nil)
        else { return false }
        return NotchLayout.contains(bridge, pointer: p)
    }

    private func anySheetOrPopoverOpen() -> Bool {
        let ours = Set(slots.values.map { ObjectIdentifier($0.panel) })
        if slots.values.contains(where: { $0.panel.attachedSheet != nil }) { return true }
        return NSApp.windows.contains {
            $0.isVisible && !ours.contains(ObjectIdentifier($0)) && $0.className.contains("Popover")
        }
    }

    // MARK: Tick

    private var ticks = 0
    private func onTick() {
        model.now = Date()
        // A running timer is written through on every tick; the engine banks a checkpoint every
        // 30 s of running time, so a crash or kill -9 loses at most that much.
        if store.engine.planner.focus?.state == .running {
            if store.applyUntracked({ try $0.tick() }) == true { services.focusFinished() }
        }
        ticks += 1
        if ticks % 2 == 0 { applyFullScreen() }
    }

    /// Frames for the closed and open shapes on every screen, for `--dump-layout`.
    func layoutDump() -> [[String: Any]] {
        slots.values.sorted { $0.state.id < $1.state.id }.map { s in
            let g = s.state.geometry
            func r(_ x: NSRect) -> [String: Double] { ["x": x.minX, "y": x.minY, "w": x.width, "h": x.height] }
            var d: [String: Any] = [
                "displayID": Int(s.state.id),
                "name": NSScreen.screens.first { $0.displayID == s.state.id }?.localizedName ?? "",
                "safeAreaTop": g.screen.safeAreaTop, "frame": r(g.screenFrame), "notch": r(g.notchRect),
                "expanded": model.expanded && model.screenID == s.state.id, "ignoresMouse": s.panel.ignoresMouseEvents,
                "idle": r(g.idle(timer: timerShowing(), activity: false)), "workspace": r(g.workspace),
                "window": r(s.panel.frame), "hardwareNotch": g.hasHardwareNotch, "fullScreen": s.state.fullScreen,
                "menuBarHeight": g.screen.menuBarHeight, "workspaceAttached": g.workspaceAttached,
                "visible": s.panel.isVisible,
            ]
            if let c = g.camera { d["camera"] = r(c) }
            // Mouse-routing probes: the decision `updateMouseRouting` makes at each point, from the live code path.
            let expanded = model.expanded && model.screenID == s.state.id
            let shape = expanded ? g.workspace : g.idle(timer: timerShowing(), activity: false)
            let capsule = !expanded && model.activity == nil ? timerShowing().map { g.pill(side: $0) } : nil
            // A detached capsule leaves the union's top midpoint/corners empty. Sample the individual components,
            // retaining the original outline probes unchanged for the expanded workspace and timer-free notch.
            let topOutside =
                capsule.map { NSPoint(x: $0.midX, y: $0.maxY + 1) }
                ?? NSPoint(x: shape.minX + 1.5, y: shape.maxY - 2)
            let topInside =
                capsule.map { _ in NSPoint(x: g.tuckedNotch.midX, y: g.tuckedNotch.maxY - 2) }
                ?? NSPoint(x: shape.midX, y: shape.maxY - 2)
            var probes: [(String, NSPoint)] = [
                ("notchCenterTopEdge", NSPoint(x: g.notchRect.midX, y: g.screenFrame.maxY)),
                ("leftWing", NSPoint(x: shape.minX + 14, y: shape.maxY - 10)),
                ("shoulderCorner", NSPoint(x: shape.minX + 0.5, y: shape.minY + 1)),
                ("justBelowShape", NSPoint(x: shape.midX, y: shape.minY - 2)),
                ("leftOfShape", NSPoint(x: shape.minX - 3, y: shape.maxY - 5)),
                ("workspaceCenter", NSPoint(x: g.workspace.midX, y: g.workspace.midY)),
                ("windowCornerOutsideShape", NSPoint(x: s.panel.frame.minX + 2, y: s.panel.frame.minY + 2)),
                // Where the clock and status items sit: must always click through to the menu bar.
                ("menuBarRight", NSPoint(x: g.screenFrame.maxX - 40, y: g.screenFrame.maxY - 4)),
                ("menuBarAboveWorkspaceEdge", NSPoint(x: g.workspace.maxX - 30, y: g.screenFrame.maxY - 4)),
                // Transparent outside the component and inside its top edge, including a detached capsule's empty surround.
                ("shapeTopCornerOutside", topOutside),
                ("shapeTopInside", topInside),
            ]
            if let capsule {
                let n = g.notchRect
                let gapX = capsule.midX < n.midX ? (capsule.maxX + n.minX) / 2 : (n.maxX + capsule.minX) / 2
                d["timerCapsule"] = r(capsule)
                probes += [
                    ("timerCapsuleCenter", NSPoint(x: capsule.midX, y: capsule.midY)),
                    ("timerGap", NSPoint(x: gapX, y: capsule.midY)),
                ]
            }
            d["routing"] = Dictionary(uniqueKeysWithValues: probes.map { ($0.0, drawn(s) && isOnShape($0.1, s)) })
            return d
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }
}
