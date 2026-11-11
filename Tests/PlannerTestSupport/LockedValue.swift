import Foundation

/// Synchronous fault-injection state shared with I/O queues. The value never escapes unlocked.
public final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    public init(_ value: Value) { storage = value }
    public var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    @discardableResult
    public func update<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&storage) }
    }
}
