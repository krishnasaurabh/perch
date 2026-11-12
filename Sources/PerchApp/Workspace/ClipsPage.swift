import AppKit
import PerchUI
import SwiftUI
import UniformTypeIdentifiers

struct ClipsPage: View {
    @EnvironmentObject var services: Services
    var body: some View { ClipsBody(clips: services.clips) }
}

private struct ClipsBody: View {
    @ObservedObject var clips: ClipsService
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    CardHeading(AppL10n.text("Clips"), symbol: "paperclip")
                    Spacer(minLength: Theme.gutter)
                    captureControls
                    removeUnpinned
                }
                VStack(alignment: .leading, spacing: Theme.gutter) {
                    HStack {
                        CardHeading(AppL10n.text("Clips"), symbol: "paperclip"); Spacer(); removeUnpinned
                    }
                    captureControls
                }
            }
            ZStack(alignment: .top) {
                ClipsRope()
                Group {
                    if clips.clips.isEmpty {
                        EmptyStateView("Drop something here to keep it close.", symbol: "paperclip")
                            .padding(.top, ClipsLineLayout.emptyMessageTop)
                            .transition(.opacity)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(clips.clips.enumerated()), id: \.element.id) { i, c in
                                    ClipCard(clip: c, clips: clips).rotationEffect(
                                        .degrees(i.isMultiple(of: 2) ? -2 : 2), anchor: .top
                                    )
                                    .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, Theme.gutter)
                            .motion(Motion.row, value: clips.clips.map(\.id))
                        }.scrollIndicators(.automatic)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Reserve space rather than covering clips or their action targets.
            if let banner = clips.letGoBanner {
                LetGoToast(banner: banner) { clips.undoLetGo() }
                    .transition(.opacity)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.gutter) {
                    hints; Spacer(minLength: Theme.gutter); FolderWatchStatus(state: clips.folderWatch)
                }
                VStack(alignment: .leading, spacing: Theme.gutter) {
                    hints; FolderWatchStatus(state: clips.folderWatch)
                }
            }
        }
        .motion(Motion.page, value: clips.clips.isEmpty)
        .card()
    }

    private var captureControls: some View {
        HStack(spacing: Theme.gutter) {
            Toggle(
                "Add screenshots",
                isOn: Binding(
                    get: { store.prefs.catchScreenshots },
                    set: { value in store.updatePrefs { $0.catchScreenshots = value } }))
            Toggle(
                "Add copied items",
                isOn: Binding(
                    get: { store.prefs.catchCopies }, set: { value in store.updatePrefs { $0.catchCopies = value } }))
        }
        .toggleStyle(.switch).controlSize(.small).font(Theme.meta)
        .frame(minHeight: Theme.minimumTarget)
    }

    private var removeUnpinned: some View {
        Button("Remove unpinned") { clips.sweep() }
            .buttonStyle(PillStyle(disabledReason: "There are no unpinned clips to remove."))
            .disabled(!clips.clips.contains(where: { !$0.pinned }))
            .help("Remove unpinned clips. Undo is available for 5 seconds. Original files are not deleted.")
    }

    @ViewBuilder private var hints: some View {
        if ClipsLineLayout.showsGestureHints(clipCount: clips.clips.count) {
            Text("Click to copy · Drag to share · More for clip actions")
                .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
    }
}

private struct ClipsRope: View {
    var body: some View {
        GeometryReader { g in
            if let rope = ClipsLineLayout.rope(width: g.size.width) {
                Path { p in
                    p.move(to: CGPoint(x: rope.start.x, y: rope.start.y))
                    p.addQuadCurve(
                        to: CGPoint(x: rope.end.x, y: rope.end.y),
                        control: CGPoint(x: rope.control.x, y: rope.control.y))
                }
                .stroke(Theme.rope, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(height: ClipsLineLayout.bandHeight)
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct LetGoToast: View {
    let banner: ClipsService.LetGoBanner
    let undo: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: Theme.gutter) {
                Text(AppL10n.format("Removed %lld clips", banner.count))
                    .font(Theme.meta).foregroundStyle(Theme.text)
                Spacer(minLength: Theme.gutter)
                Button("Undo", action: undo).buttonStyle(PillStyle(prominent: true))
                    .accessibilityHint("Restore the removed clips")
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let left = max(0, banner.deadline.timeIntervalSince(ctx.date)) / LetGoLedger<ClipsService.Clip>.window
                GeometryReader { g in
                    Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, left), height: 2)
                }.frame(height: 2).accessibilityHidden(true)
            }
        }
        .padding(Theme.gutter)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.cardStroke))
        .id(banner.token)
    }
}

private struct FolderWatchStatus: View {
    let state: ClipsService.FolderWatch

    var body: some View {
        switch state {
        case .off:
            EmptyView()
        case .watching(let url):
            Label(AppL10n.format("Watching %@", url.lastPathComponent), systemImage: "eye")
                .font(Theme.meta).foregroundStyle(Theme.secondary)
                .help(AppL10n.format("New screenshots in %@ appear here.", url.path))
        case .unreadable(let url):
            Button {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
            } label: {
                Label("Folder access unavailable · Settings…", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(PillStyle())
            .help(
                AppL10n.format(
                    "Allow Perch to access %@ in Privacy & Security › Files and Folders. Only Spotlight is active until then.",
                    url.path)
            )
        }
    }
}

private struct ClipCard: View {
    let clip: ClipsService.Clip
    let clips: ClipsService
    @State private var copied = false
    @FocusState private var copyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 8, height: 18).offset(y: 6).zIndex(1)
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    clips.copy(clip)
                    copied = true
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        ClipPreview(content: clip.content, thumbnail: clip.thumbnail)
                        Text(clip.displayTitle(copied: copied)).font(Theme.meta).lineLimit(1)
                            .foregroundStyle(Theme.text).frame(width: 132, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($copyFocused)
                .focusEffectDisabled()
                .overlay(
                    ControlFocusRing(shape: RoundedRectangle(cornerRadius: Theme.controlRadius), focused: copyFocused)
                )
                .accessibilityLabel(AppL10n.format("Copy %@", clip.title))
                HStack {
                    if clip.pinned {
                        Label("Pinned", systemImage: "pin.fill").font(Theme.meta).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        clipActions
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .font(Theme.meta).frame(minHeight: Theme.minimumTarget)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(AppL10n.format("Actions for %@", clip.title))
                }.frame(width: 132)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.cardStroke))
            // These are intentionally paper tiles even in the dark notch, not dark-mode text on white.
            .environment(\.colorScheme, .light)
            .environment(\.controlSurface, Theme.fill)
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
            if !Task.isCancelled { copied = false }
        }
        .onDrag {
            switch clip.content {
            case .file(let u): return NSItemProvider(contentsOf: u) ?? NSItemProvider()
            case .text(let s): return NSItemProvider(object: s as NSString)
            case .image(let d): return NSItemProvider(item: d as NSData, typeIdentifier: UTType.png.identifier)
            }
        }
        .contextMenu { clipActions }
    }

    @ViewBuilder private var clipActions: some View {
        Button(AppL10n.text(clip.pinned ? "Unpin" : "Pin")) { clips.togglePin(clip.id) }
        Button("Copy") { clips.copy(clip) }
        if let url = clips.clipURL(clip) {
            Button("Open") { clips.open(clip) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Remove", role: .destructive) { clips.letGo(clip.id) }
    }
}
