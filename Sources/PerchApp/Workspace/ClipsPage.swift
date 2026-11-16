import AppKit
import PerchUI
import SwiftUI
import UniformTypeIdentifiers

/// Compatibility for saved deep links. Clips is no longer a workspace page.
struct ClipsPage: View {
    @EnvironmentObject private var model: NotchModel
    var body: some View { HomePage().onAppear { model.page = .home } }
}

/// Storage-backed content shown only in the drag shelf.
struct ClipsBody: View {
    @ObservedObject var clips: ClipsService
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: DropShelfLayout.gap) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DropShelfLayout.gap) {
                    heading; clear
                }
                VStack(alignment: .leading, spacing: DropShelfLayout.gap) {
                    heading; clear
                }
            }
            HStack(spacing: DropShelfLayout.gap) {
                if !clips.clips.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: DropShelfLayout.gap) {
                            ForEach(clips.clips) { clip in ShelfItemCard(clip: clip, clips: clips) }
                        }
                        .padding(Theme.Size.focusGap.value + Theme.Size.focusWidth.value)
                    }
                    .scrollIndicators(.automatic)
                    .frame(
                        height: DropShelfLayout.cardHeight + 2
                            * (Theme.Size.focusGap.value + Theme.Size.focusWidth.value))
                }
                dropSlot
            }
            if let banner = clips.letGoBanner {
                HStack(spacing: DropShelfLayout.gap) {
                    Text(AppL10n.format("Removed %lld clips", banner.count)).perchFont(.detail)
                    NotchStripButton(title: AppL10n.text("Undo"), surface: .apricot) { clips.undoLetGo() }
                        .accessibilityIdentifier("shelf.undo")
                }
            }
            if let error = store.lastError {
                Text(error.message).perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DropShelfLayout.inset)
        .padding(.vertical, Theme.Size.sheetPadding.value)
        .foregroundStyle(Theme.ink)
        .background(Theme.apricot)
        .onDrop(of: [.fileURL, .url, .plainText, .image], isTargeted: nil) { clips.acceptDrop($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppL10n.text("Drop shelf"))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
            Text("Drop it here to keep it handy").perchFont(.stripTitle)
            Text("The shelf shows up only while you drag. Drag an item back out to use it.")
                .perchFont(.detail).foregroundStyle(Theme.ink2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clear: some View {
        NotchStripButton(title: AppL10n.text("Clear"), kind: .quiet, surface: .apricot) { clips.clearShelf() }
            .disabled(clips.clips.isEmpty).accessibilityIdentifier("shelf.clear")
    }

    private var dropSlot: some View {
        Text("Drop here").perchFont(.detailStrong)
            .frame(width: clips.clips.isEmpty ? nil : DropShelfLayout.slotWidth)
            .frame(maxWidth: clips.clips.isEmpty ? .infinity : nil)
            .frame(height: DropShelfLayout.cardHeight)
            .background(
                RoundedRectangle(cornerRadius: DropShelfLayout.radius).strokeBorder(
                    Theme.ink2, style: StrokeStyle(lineWidth: Theme.Size.cardEdge.value, dash: [DropShelfLayout.dash]))
            )
            .accessibilityIdentifier("shelf.drop")
    }
}

private struct ShelfItemCard: View {
    let clip: ClipsService.Clip
    @ObservedObject var clips: ClipsService
    @State private var copied = false
    @FocusState private var copyFocused: Bool
    @FocusState private var menuFocused: Bool
    @State private var menuKeyboard = ClipsMenuKeyboardTarget()
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    private func copyClip() { clips.copy(clip); copied = true }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: copyClip) {
                VStack(alignment: .leading, spacing: DropShelfLayout.gap) {
                    ClipPreview(content: clip.content, thumbnail: clip.thumbnail).accessibilityHidden(true)
                    Text(clip.displayTitle(copied: copied)).perchFont(.detail).lineLimit(1).help(clip.title)
                }
                .padding(DropShelfLayout.gap)
                .frame(width: DropShelfLayout.cardWidth, height: DropShelfLayout.cardHeight, alignment: .leading)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: DropShelfLayout.radius))
                .overlay(
                    FocusRing(
                        shape: RoundedRectangle(cornerRadius: DropShelfLayout.radius), focused: copyFocused,
                        surface: .apricot)
                )
                .contentShape(RoundedRectangle(cornerRadius: DropShelfLayout.radius))
            }
            .buttonStyle(.plain)
            .focusable(enabled)
            .focused($copyFocused)
            .focusEffectDisabled()
            .onKeyPress(.space, phases: .down) { _ in
                guard enabled else { return .ignored }
                copyClip()
                return .handled
            }
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(DropShelfLayout.copyFeedbackDuration)) } catch { return }
                copied = false
            }
            .onDeleteCommand { clips.letGo(clip.id) }
            .onKeyPress(.return) {
                if clips.clipURL(clip) != nil { clips.open(clip); return .handled }; return .ignored
            }
            .accessibilityLabel(AppL10n.format("Copy %@", clip.title))
            .accessibilityIdentifier("shelf.item.\(clip.id)")
            .onDrag { clips.dragProvider(for: clip) }
            .contextMenu {
                Button("Copy", action: copyClip)
                if clips.clipURL(clip) != nil { Button("Open") { clips.open(clip) } }
                Button("Remove") { clips.letGo(clip.id) }
            }
            ClipsActionsMenu(clip: clip, clips: clips, keyboard: menuKeyboard)
                .frame(width: Theme.Size.minimumTarget.value, height: Theme.Size.minimumTarget.value)
                .focusable(enabled).focused($menuFocused).focusEffectDisabled()
                .onKeyPress(.space, phases: .down) { _ in
                    guard enabled && menuFocused else { return .ignored }
                    return menuKeyboard.open() ? .handled : .ignored
                }
                .overlay(
                    FocusRing(
                        shape: RoundedRectangle(cornerRadius: DropShelfLayout.radius), focused: menuFocused,
                        surface: .paper)
                )
                .opacity(hovered || menuFocused ? 1 : 0)
                .designMotion(.hover, value: hovered || menuFocused)
        }
        .onHover { hovered = $0 }
    }
}

/// Assign identity to the AppKit launcher itself. A SwiftUI Menu's outer
/// accessibility label does not label its native popup cell on macOS.
private struct ClipsActionsMenu: NSViewRepresentable {
    let clip: ClipsService.Clip
    let clips: ClipsService
    let keyboard: ClipsMenuKeyboardTarget
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        let cell = ClipsActionsCell(textCell: "", pullsDown: true)
        button.cell = cell
        cell.menuButton = button
        // Unlike fixed-height popup bezels, this bezel fills the real 32pt target.
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.font = .systemFont(ofSize: ThemeTokens.TypeSize.meta, weight: .medium)
        button.controlSize = .regular
        keyboard.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        keyboard.button = button
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: AppL10n.text("More"), action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menu.addItem(title)
        context.coordinator.actions = []
        @MainActor func add(_ title: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(Coordinator.performAction(_:)), keyEquivalent: "")
            item.target = context.coordinator
            item.tag = context.coordinator.actions.count
            item.isEnabled = isEnabled
            context.coordinator.actions.append(action)
            menu.addItem(item)
        }
        add(AppL10n.text(clip.pinned ? "Unpin" : "Pin")) { clips.togglePin(clip.id) }
        add(AppL10n.text("Copy")) { clips.copy(clip) }
        if let url = clips.clipURL(clip) {
            add(AppL10n.text("Open")) { clips.open(clip) }
            add(AppL10n.text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        menu.addItem(.separator())
        add(AppL10n.text("Remove")) { clips.letGo(clip.id) }
        button.menu = menu
        button.isEnabled = isEnabled
        let label = AppL10n.format("Actions for %@", clip.title)
        let identifier = "clips.actions.\(clip.id)"
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.cell?.setAccessibilityLabel(label)
        button.cell?.setAccessibilityIdentifier(identifier)
    }

    @MainActor final class Coordinator: NSObject {
        var actions: [() -> Void] = []
        @objc func performAction(_ sender: NSMenuItem) {
            guard sender.isEnabled, actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}

/// Forward the cell's accessibility actions to the same native popup tracking
/// used for pointer activation. No menu item is selected merely by opening it.
@MainActor
private final class ClipsActionsCell: NSPopUpButtonCell {
    weak var menuButton: NSPopUpButton?

    override func accessibilityPerformPress() -> Bool { showActions() }
    override func accessibilityPerformShowMenu() -> Bool { showActions() }

    private func showActions() -> Bool {
        guard let button = menuButton, button.cell === self, button.window != nil,
            button.isEnabled, button.bounds.width > 0, button.bounds.height > 0,
            let menu = button.menu, menu.items.contains(where: { $0.isEnabled && $0.action != nil })
        else { return false }
        performClick(withFrame: button.bounds, in: button)
        return true
    }
}

/// The SwiftUI Tab stop and ring belong to the launcher; Space forwards to
/// its existing native menu rather than creating a second action surface.
@MainActor
private final class ClipsMenuKeyboardTarget {
    weak var button: NSPopUpButton?

    func open() -> Bool {
        guard let button, button.window != nil, button.isEnabled,
            !button.isHiddenOrHasHiddenAncestor,
            button.bounds.width > 0, button.bounds.height > 0,
            let menu = button.menu, menu.items.contains(where: { $0.isEnabled && $0.action != nil })
        else { return false }
        button.performClick(nil)
        return true
    }
}
