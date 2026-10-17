import Foundation

// SnailSight 11.0: the tile caches' policies (plan §3.2). Pure, so the app's file / entity code stays thin.
//  - TileDiskLRU: per-tile USDZ blobs on disk (Caches/tiles/<sha256>.usdz), content addressed (valid forever), capped
//    at 2 GB by bytes, least recently used first; blobs in use (loaded / downloading) are pinned.
//  - TileMemLedger: what is loaded into RealityKit (key → hash + mem estimate), the in-memory budget's books.

public struct TileDiskLRU: Equatable {
    public static let defaultCap = 2 * 1024 * 1024 * 1024          // 2 GB
    public let capBytes: Int
    public private(set) var entries: [String: Entry] = [:]
    public private(set) var totalBytes = 0

    public struct Entry: Equatable {
        public var bytes: Int
        public var lastUse: Double
    }

    public init(capBytes: Int = TileDiskLRU.defaultCap) { self.capBytes = capBytes }

    public func contains(_ hash: String) -> Bool { entries[hash] != nil }

    /// A blob found on disk at start-up (bytes + modification time).
    public mutating func seed(_ hash: String, bytes: Int, lastUse: Double) {
        if let old = entries[hash] { totalBytes -= old.bytes }
        entries[hash] = Entry(bytes: bytes, lastUse: lastUse)
        totalBytes += bytes
    }

    /// The blob was used (read from disk or loaded).
    public mutating func touch(_ hash: String, now: Double) {
        entries[hash]?.lastUse = now
    }

    /// A blob was written. Returns the hashes to delete (oldest first) so the cache fits its cap; never a pinned one
    /// nor the one just written.
    @discardableResult
    public mutating func insert(_ hash: String, bytes: Int, now: Double, pinned: Set<String> = []) -> [String] {
        seed(hash, bytes: bytes, lastUse: now)
        return evict(pinned: pinned.union([hash]))
    }

    /// Remove least-recently-used entries until the cache fits (pinned ones are skipped).
    public mutating func evict(pinned: Set<String> = []) -> [String] {
        guard totalBytes > capBytes else { return [] }
        var out: [String] = []
        for (h, e) in entries.sorted(by: { $0.value.lastUse != $1.value.lastUse ? $0.value.lastUse < $1.value.lastUse
                                                                                 : $0.key < $1.key }) {
            if totalBytes <= capBytes { break }
            if pinned.contains(h) { continue }
            totalBytes -= e.bytes
            entries[h] = nil
            out.append(h)
        }
        return out
    }

    public mutating func remove(_ hash: String) {
        if let e = entries.removeValue(forKey: hash) { totalBytes -= e.bytes }
    }
}

/// The tiles loaded into the scene: key → (content hash, mem estimate, band). The streamer asks it what to evict.
public struct TileMemLedger: Equatable {
    public struct Item: Equatable {
        public var hash: String
        public var mem: Int
        public var near: Bool
        public init(hash: String, mem: Int, near: Bool) { self.hash = hash; self.mem = mem; self.near = near }
    }

    public private(set) var items: [String: Item] = [:]
    public private(set) var totalMem = 0

    public init() {}

    public mutating func add(_ key: String, _ item: Item) {
        remove(key)
        items[key] = item
        totalMem += item.mem
    }

    @discardableResult
    public mutating func remove(_ key: String) -> Item? {
        guard let it = items.removeValue(forKey: key) else { return nil }
        totalMem -= it.mem
        return it
    }

    public mutating func removeAll() { items.removeAll(); totalMem = 0 }

    /// Keys loaded with the CURRENT content of the tileset (a key whose hash changed in a new rev is not "loaded":
    /// its new content must be fetched; the old entity may stay drawn meanwhile).
    public func current(hashes: [String: String]) -> Set<String> {
        Set(items.compactMap { k, it in hashes[k] == it.hash ? k : nil })
    }

    public var nearMem: Int { items.values.filter(\.near).reduce(0) { $0 + $1.mem } }
    public var midMem: Int { totalMem - nearMem }
    public var hashes: Set<String> { Set(items.values.map(\.hash)) }
}
