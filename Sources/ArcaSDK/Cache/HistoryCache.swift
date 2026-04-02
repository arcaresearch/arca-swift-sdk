import Foundation

/// Configuration for the SDK's in-memory history cache.
public struct CacheConfig: Sendable {
    /// Maximum number of cached responses. Default 50. Set to 0 to disable caching.
    public let maxEntries: Int

    public init(maxEntries: Int = 50) {
        self.maxEntries = maxEntries
    }

    /// A disabled cache that stores nothing.
    public static let disabled = CacheConfig(maxEntries: 0)
}

/// Thread-safe LRU cache for historical data responses (equity history, PnL history, candles).
///
/// Uses NSLock for safe concurrent access and a doubly-linked list + dictionary
/// for O(1) LRU operations. Synchronous (no actor hop) so parallel callers
/// don't serialize through an actor mailbox.
public final class HistoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var dict: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let maxEntries: Int

    public init(config: CacheConfig = CacheConfig()) {
        self.maxEntries = config.maxEntries
    }

    public func get<T>(_ key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard maxEntries > 0, let node = dict[key] else { return nil }
        moveToHead(node)
        return node.value as? T
    }

    public func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let node = dict[key] else { return }
        removeNode(node)
        dict.removeValue(forKey: key)
    }

    public func set(_ key: String, value: Any) {
        lock.lock()
        defer { lock.unlock() }
        guard maxEntries > 0 else { return }

        if let existing = dict[key] {
            existing.value = value
            moveToHead(existing)
            return
        }

        let node = Node(key: key, value: value)
        dict[key] = node
        addToHead(node)

        while dict.count > maxEntries {
            if let evicted = removeTail() {
                dict.removeValue(forKey: evicted.key)
            }
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        dict.removeAll()
        head = nil
        tail = nil
    }

    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return dict.count
    }

    // MARK: - Linked list operations (caller must hold lock)

    private func addToHead(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if head === node { head = next }
        if tail === node { tail = prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        addToHead(node)
    }

    private func removeTail() -> Node? {
        guard let t = tail else { return nil }
        removeNode(t)
        return t
    }
}

private final class Node {
    let key: String
    var value: Any
    var prev: Node?
    var next: Node?

    init(key: String, value: Any) {
        self.key = key
        self.value = value
    }
}

/// Build a deterministic cache key from a method name and sorted parameters.
public func buildCacheKey(_ method: String, _ params: [String: String?]) -> String {
    let parts = params.keys.sorted().compactMap { key -> String? in
        guard let value = params[key], let unwrapped = value else { return nil }
        return "\(key)=\(unwrapped)"
    }
    return "\(method):\(parts.joined(separator: "&"))"
}
