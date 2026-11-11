import Foundation
import PerchUI

import Darwin
import os

/// Watches one folder with a vnode `DispatchSource` on an `O_EVTONLY` descriptor.
final class FolderWatcher: Sendable {
    enum Event { case contents, folderMoved, recheck }
    static let captureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    static let recordingAttribute = "com.apple.metadata:kMDItemIsScreenRecording"

    let url: URL
    private let queue: DispatchQueue
    private let handler: @Sendable (Event) -> Void
    private struct State {
        var source: DispatchSourceFileSystemObject?
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) {
        self.url = url; self.queue = queue; self.handler = handler
    }

    deinit { stop() }

    /// False when the folder can't be opened (missing, or no permission yet for Desktop/Documents/Downloads).
    func start() -> Bool {
        if state.withLock({ $0.source != nil }) { return true }
        guard !state.withLock({ $0.stopped }) else { return false }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            PlatformLog.folders.error("start failed errno=\(errno, privacy: .public)")
            return false
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)
        let handler = handler
        s.setEventHandler { [weak s] in
            guard let s else { return }
            handler(s.data.contains(.delete) || s.data.contains(.rename) ? .folderMoved : .contents)
        }
        s.setCancelHandler { close(fd) }
        // Opening a protected folder happens outside the lock, so stop never waits for a permission prompt.
        // Publish and resume together: teardown can never see an unresumed source.
        return state.withLock { state in
            guard !state.stopped, state.source == nil else {
                s.resume()
                s.cancel()
                return !state.stopped
            }
            state.source = s
            s.resume()
            PlatformLog.folders.debug("watch started")
            return true
        }
    }

    func stop() {
        state.withLock { state in
            state.stopped = true
            if state.source != nil { PlatformLog.folders.debug("watch stopped") }
            state.source?.cancel()
            state.source = nil
        }
    }

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
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys))
            return items.compactMap { u in
                let v = try? u.resourceValues(forKeys: keys)
                guard v?.isRegularFile == true else { return nil }
                return FolderScan.Entry(
                    name: u.lastPathComponent, created: v?.creationDate ?? .distantPast,
                    hidden: v?.isHidden ?? false, captureFlag: hasScreenCaptureFlag(u))
            }
        } catch {
            PlatformLog.folders.error("entries failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            return []
        }
    }
}
