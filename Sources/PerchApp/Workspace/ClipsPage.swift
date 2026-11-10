import AppKit
import PerchUI
import SwiftUI
import UniformTypeIdentifiers

/// Clips: a clothesline of screenshots, recordings and copied things.
struct ClipsPage: View {
    @EnvironmentObject var services: Services
    var body: some View { ClipsBody(clips: services.clips) }
}

private struct ClipsBody: View {
    @ObservedObject var clips: ClipsService
    @EnvironmentObject var store: PlannerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading("Clips", symbol: "paperclip")
                Spacer()
                Toggle(
                    "Catch screenshots",
                    isOn: Binding(
                        get: { store.prefs.catchScreenshots },
                        set: { v in store.updatePrefs { $0.catchScreenshots = v } })
                )
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                Toggle(
                    "Catch copies",
                    isOn: Binding(
                        get: { store.prefs.catchCopies }, set: { v in store.updatePrefs { $0.catchCopies = v } })
                )
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                Button("Let go of all") { clips.sweep() }.buttonStyle(PillStyle())
                    .opacity(clips.clips.contains(where: { !$0.pinned }) ? 1 : 0)
                    .disabled(!clips.clips.contains(where: { !$0.pinned }))
                    .accessibilityHidden(!clips.clips.contains(where: { !$0.pinned }))
                    .help("Remove unpinned clips. Undo is available for 5 seconds.")
            }
            ZStack(alignment: .top) {
                // Keep the bounded rope geometry; its stroke uses the shared accessibility token below.
                ClipsRope()
                Group {
                    if clips.clips.isEmpty {
                        // Sits just under the rope's lowest point, as if hanging from it.
                        EmptyStateView("Drop something here to keep it close.", symbol: "paperclip")
                            .padding(.top, ClipsLineLayout.emptyMessageTop)
                            .transition(.opacity)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(clips.clips.enumerated()), id: \.element.id) { i, c in
                                    ClipCard(clip: c, clips: clips).rotationEffect(
                                        .degrees(i.isMultiple(of: 2) ? -2 : 2), anchor: .top
                                    )
                                    .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 16).padding(.top, 16)
                            .motion(Motion.row, value: clips.clips.map(\.id))
                        }.scrollIndicators(.never)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                if let banner = clips.letGoBanner {
                    LetGoToast(banner: banner) { clips.undoLetGo() }
                        .transition(.opacity)
                        .padding(.bottom, 4)
                }
            }
            HStack(spacing: 6) {
                if ClipsLineLayout.showsGestureHints(clipCount: clips.clips.count) {
                    Text("Click: copy · Double-click: open · Drag: move or share").font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                FolderWatchStatus(state: clips.folderWatch)
            }
        }
        // Populated <-> empty crossfades in place, with the page-switch timing (Reduce Motion aware).
        .motion(Motion.page, value: clips.clips.isEmpty)
        .card()
    }
}

/// The line clips hang on. Its width comes from the space it is given (the card's content box), inset at both ends.
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
                // Dedicated boundary ink: do not attenuate a text token a second time.
                .stroke(Theme.rope, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(height: ClipsLineLayout.bandHeight)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "Let go of 2 clips · Undo", with the 5-second window draining underneath.
private struct LetGoToast: View {
    let banner: ClipsService.LetGoBanner
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(banner.count == 1 ? "Let go of 1 clip" : "Let go of \(banner.count) clips")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
            Button("Undo", action: undo).buttonStyle(PillStyle(prominent: true))
                .accessibilityHint("Puts the clips back on the line")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(Color(white: 0.16)))
        .overlay(Capsule().strokeBorder(Theme.cardStroke))
        .overlay(alignment: .bottom) {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let left = max(0, banner.deadline.timeIntervalSince(ctx.date)) / LetGoLedger<ClipsService.Clip>.window
                GeometryReader { g in
                    Capsule().fill(Theme.accent.opacity(0.7)).frame(width: g.size.width * left, height: 2)
                }
                .frame(height: 2).padding(.horizontal, 16).padding(.bottom, 3)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .id(banner.token)
    }
}

/// Whether the screenshot folder itself is watched, or only Spotlight is catching screenshots.
private struct FolderWatchStatus: View {
    let state: ClipsService.FolderWatch

    var body: some View {
        switch state {
        case .off:
            EmptyView()
        case .watching(let url):
            Label("Watching \(url.lastPathComponent)", systemImage: "eye")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                .help("New screenshots in \(url.path) hang here right away.")
        case .unreadable(let url):
            Button {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
            } label: {
                Label(
                    "Can't read \(url.lastPathComponent): using Spotlight only", systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(
                "Allow Perch to access \(url.path) in Privacy & Security › Files and Folders, so screenshots appear instantly."
            )
        }
    }
}

private struct ClipCard: View {
    let clip: ClipsService.Clip
    let clips: ClipsService
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Clothespin.
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 8, height: 18).offset(y: 6).zIndex(1)
            VStack(alignment: .leading, spacing: 5) {
                ClipPreview(content: clip.content, thumbnail: clip.thumbnail)
                HStack(spacing: 4) {
                    Text(copied ? "Copied" : clip.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                        .foregroundStyle(copied ? Theme.accent : .black.opacity(0.7))
                    Spacer(minLength: 0)
                    if clip.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.black.opacity(0.6))
                    }
                }
                .frame(width: 132, alignment: .leading)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 4)
        }
        .onTapGesture(count: 2) { clips.open(clip) }
        .onTapGesture {
            clips.copy(clip)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .onDrag {
            switch clip.content {
            case .file(let u): return NSItemProvider(contentsOf: u) ?? NSItemProvider()
            case .text(let s): return NSItemProvider(object: s as NSString)
            case .image(let d): return NSItemProvider(item: d as NSData, typeIdentifier: UTType.png.identifier)
            }
        }
        .contextMenu {
            Button(clip.pinned ? "Unpin" : "Keep this clip when the shelf fills up") { clips.togglePin(clip.id) }
            Button("Copy") { clips.copy(clip) }
            if clips.clipURL(clip) != nil {
                Button("Open") { clips.open(clip) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clips.clipURL(clip)!]) }
            }
            Divider()
            Button("Let go", role: .destructive) { clips.letGo(clip.id) }
        }
    }
}
