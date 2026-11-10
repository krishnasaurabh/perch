import AppKit

/// Clipboard I/O is replaceable; tests need neither the shared clipboard nor desktop permissions.
enum PasteboardValue { case file(URL), text(String), image(Data) }

@MainActor
protocol PasteboardAccess {
    var changeCount: Int { get }
    var declaredTypes: [String] { get }
    var fileURLs: [URL] { get }
    var imageData: Data? { get }
    var plainText: String? { get }
    func replace(with value: PasteboardValue)
}

extension NSPasteboard: PasteboardAccess {
    var declaredTypes: [String] { (types ?? []).map(\.rawValue) }
    var fileURLs: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    var imageData: Data? { data(forType: .png) ?? data(forType: .tiff) }
    var plainText: String? { string(forType: .string) }
    func replace(with value: PasteboardValue) {
        clearContents()
        let succeeded: Bool
        let kind: String
        switch value {
        case .file(let url):
            succeeded = writeObjects([url as NSURL]); kind = "file"
        case .text(let text):
            succeeded = setString(text, forType: .string); kind = "text"
        case .image(let data):
            succeeded = setData(data, forType: .png); kind = "image"
        }
        PlatformLog.pasteboard.debug(
            "replace kind=\(kind, privacy: .public) succeeded=\(succeeded, privacy: .public) changeCount=\(self.changeCount, privacy: .public)"
        )
    }
}
