import Foundation
import PerchUI

import Darwin

/// Watches one folder with a vnode `DispatchSource` on an `O_EVTONLY` descriptor.
final class FolderWatcher {
    enum Event { case contents, folderMoved, recheck }
    static let captureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    static let recordingAttribute = "com.apple.metadata:kMDItemIsScreenRecording"

    let url: URL
    private let queue: DispatchQueue
    private let handler: (Event) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, queue: DispatchQueue, handler: @escaping (Event) -> Void) {
        self.url = url; self.queue = queue; self.handler = handler
    }

    deinit { stop() }

    /// False when the folder can't be opened (missing, or no permission yet for Desktop/Documents/Downloads).
    func start() -> Bool {
        guard source == nil else { return true }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)
        let handler = handler
        s.setEventHandler { [weak s] in
            guard let s else { return }
            handler(s.data.contains(.delete) || s.data.contains(.rename) ? .folderMoved : .contents)
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        return true
    }

    func stop() { source?.cancel(); source = nil }

    static func hasScreenCaptureFlag(_ url: URL) -> Bool {
        let path = url.path
        for name in [captureAttribute, recordingAttribute] where getxattr(path, name, nil, 0, 0, 0) >= 0 {
            return true
        }
        return false
    }

    /// The folder's direct children, hidden ones included (screencapture writes a dot-file, then renames it).
    static func entries(in dir: URL) -> [FolderScan.Entry] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .isHiddenKey, .isRegularFileKey]
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys))
        else { return [] }
        return items.compactMap { u in
            let v = try? u.resourceValues(forKeys: keys)
            guard v?.isRegularFile == true else { return nil }
            return FolderScan.Entry(
                name: u.lastPathComponent, created: v?.creationDate ?? .distantPast,
                hidden: v?.isHidden ?? false, captureFlag: hasScreenCaptureFlag(u))
        }
    }
}
