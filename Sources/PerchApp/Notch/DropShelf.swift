import AppKit
import PlannerCore
import PerchUI
import SwiftUI

/// A drag-only surface; presentation lifetime is owned by the shared strip queue.
struct DropShelf: View {
    @ObservedObject var clips: ClipsService
    var body: some View { ClipsBody(clips: clips) }
}

#if DEBUG || PERCH_TESTING
    @MainActor
    enum DropShelfPreview {
        static let windowID = "drop-shelf-preview"
        static func show(app: AppDelegate, empty: Bool = false) {
            let root = app.store.file.url.deletingLastPathComponent().appendingPathComponent("shelf-preview-\(UUID())")
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
            let clips = ClipsService(store: store, monitoring: false)
            if !empty {
                clips.add(.link(URL(string: "https://example.com/design-board")!), source: "dropped")
                let file = root.appendingPathComponent("release-notes.pdf")
                if let context = CGContext(file as CFURL, mediaBox: nil, nil) {
                    context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
                    clips.add(.file(file), source: "dropped")
                }
                if let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.tiffRepresentation {
                    clips.add(.image(image), source: "dropped")
                }
            }
            let band = app.model.geometry?.screen.menuBarHeight ?? NSStatusBar.system.thickness
            let content = VStack(spacing: .zero) {
                Theme.band.frame(height: band)
                DropShelf(clips: clips)
            }
            .frame(width: DropShelfLayout.width).fixedSize(horizontal: false, vertical: true)
            .environmentObject(store).previewEnvironment()
            .environment(\.colorScheme, PreviewAppearance.scheme ?? .light)
            let height = NSHostingView(rootView: content).fittingSize.height
            WindowHost.show(windowID, title: "Perch", size: CGSize(width: DropShelfLayout.width, height: height)) {
                content
            }
        }
    }
#endif
