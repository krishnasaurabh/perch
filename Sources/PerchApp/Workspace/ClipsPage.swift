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
    @Environment(\.isEnabled) private var enabled

    private func copyClip() { clips.copy(clip); copied = true }

    var body: some View {
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
    }
}
