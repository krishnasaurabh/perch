import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A bounded, readable preview even while Quick Look is unavailable or returns blank paper.
struct ClipPreview: View {
    let content: ClipsService.Clip.Content
    let thumbnail: NSImage?
    @State private var fileText: String?

    var body: some View {
        Group {
            if let image = thumbnail, usableThumbnail(image) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let text = previewText {
                Text(text).font(.system(size: 10.5)).foregroundStyle(.black.opacity(0.8))
                    .lineLimit(6).padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: fileSymbol).font(.system(size: 22))
                    Text(filename).font(.system(size: 9.5, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.black.opacity(0.65)).padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 132, height: 92).clipped()
        .background(Color.white.opacity(0.92))
        .task(id: content) {
            fileText = nil
            guard case .file(let url) = content else { return }
            // File metadata and the bounded read stay off the UI thread (including slow external volumes).
            let text = await Task.detached(priority: .utility) { Self.readText(at: url) }.value
            guard !Task.isCancelled else { return }
            fileText = text
        }
    }

    private var previewText: String? {
        let text: String?
        switch content {
        case .text(let value): text = value
        case .file: text = fileText
        case .image: text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(4096))
    }

    private var filename: String {
        if case .file(let url) = content { return url.lastPathComponent }
        return "Empty clip"
    }

    private var fileSymbol: String {
        guard case .file(let url) = content, let type = UTType(filenameExtension: url.pathExtension) else {
            return "doc"
        }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .plainText) { return "doc.text" }
        return "doc"
    }

    /// Only ordinary plain-text files, at most 64 KiB, decoded strictly as UTF-8.
    /// Recheck the actual bounded read so a file growing after the metadata check cannot bypass the cap.
    nonisolated static func readText(at url: URL) -> String? {
        let limit = 64 * 1024
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= limit,
            values.contentType?.conforms(to: .plainText) == true,
            let file = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit,
            let text = String(data: data, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) })
        else { return nil }
        return String(text.prefix(4096))
    }

    private func usableThumbnail(_ image: NSImage) -> Bool {
        guard case .file = content else { return true }
        // Quick Look can return a white sheet with only a border/shadow. Inspect its interior,
        // not those edges, so it cannot suppress the text or intentional file placeholder.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let interior = cg.cropping(
                to: CGRect(
                    x: CGFloat(cg.width) * 0.15, y: CGFloat(cg.height) * 0.15,
                    width: CGFloat(cg.width) * 0.7, height: CGFloat(cg.height) * 0.7))
        else { return false }
        var pixels = [UInt8](repeating: 255, count: 16 * 16 * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                    bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            context.draw(interior, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return false }
        let luminance = stride(from: 0, to: pixels.count, by: 4).map { i in
            (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
        }
        return (luminance.max() ?? 0) - (luminance.min() ?? 0) > 24
    }
}
