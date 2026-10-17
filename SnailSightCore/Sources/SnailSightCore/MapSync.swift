import Foundation

// SnailSight 11.2: living-map sync (live shared-map plan §8 / M4, API §5.13). Pure logic, tested on Linux CI.
//  - The rev WebSocket subscribe carries `held` = {"<variant>:<key>": "<usdz hash>"} (the tiles loaded right now); the
//    server then puts in each `rev` message a `sync` block with ONLY the held tiles that changed (kind rev | rollback |
//    checkpoint | held = the answer to a (re)subscribe: whatever changed while the phone was away).
//  - TileStreamer applies `changed` in place: the key's hash and blob URI switch to the new content, the old entity
//    stays on screen until the new one is loaded (no hole), `removed` tiles are released.
//  - EditQueue: entity edits that could not be delivered (offline, server down) are kept on disk in order, each with an
//    Idempotency-Key, and resent until the server answers; a replayed key is applied once by the server. A 409 (stale
//    base_revision) is re-read and re-applied once; if the same entity changed on the server since the edit was made,
//    it is reported as a conflict (mine is kept, the log + toast say so).

public struct TileSyncChange: Codable, Equatable {
    public var layer: String
    public var key: String
    public var hash: String
    public var bytes: Int?
    public var lod: Int?
    public init(layer: String, key: String, hash: String, bytes: Int? = nil, lod: Int? = nil) {
        self.layer = layer; self.key = key; self.hash = hash; self.bytes = bytes; self.lod = lod
    }
}

public struct TileSyncRemoved: Codable, Equatable {
    public var layer: String
    public var key: String
}

/// The `sync` block of a `rev` message.
public struct TileSyncEvent: Codable, Equatable {
    public var kind: String
    public var rev: Int?
    public var prevRev: Int?
    public var changed: [TileSyncChange]
    public var removed: [TileSyncRemoved]
    public var changedTotal: Int?

    enum CodingKeys: String, CodingKey {
        case kind, rev, changed, removed
        case prevRev = "prev_rev", changedTotal = "changed_total"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "rev"
        rev = try? c.decodeIfPresent(Int.self, forKey: .rev)
        prevRev = try? c.decodeIfPresent(Int.self, forKey: .prevRev)
        changed = (try? c.decode([TileSyncChange].self, forKey: .changed)) ?? []
        removed = (try? c.decode([TileSyncRemoved].self, forKey: .removed)) ?? []
        changedTotal = try? c.decodeIfPresent(Int.self, forKey: .changedTotal)
    }

    public init(kind: String, rev: Int?, changed: [TileSyncChange], removed: [TileSyncRemoved] = []) {
        self.kind = kind; self.rev = rev; self.changed = changed; self.removed = removed
    }

    /// The `sync` block of a WS message (nil when the message has none: an older server, or not a `rev`).
    public static func decode(message data: Data) -> TileSyncEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "rev", let s = obj["sync"],
              let d = try? JSONSerialization.data(withJSONObject: s) else { return nil }
        return try? JSONDecoder().decode(TileSyncEvent.self, from: d)
    }

    /// Changes for one variant, keyed by tile key.
    public func changes(variant: String) -> [String: TileSyncChange] {
        Dictionary(changed.filter { $0.layer == variant }.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
    }

    public func removedKeys(variant: String) -> Set<String> {
        Set(removed.filter { $0.layer == variant }.map { $0.key })
    }
}

public enum TileSync {
    /// {"structure:1/0/-1": hash} for the loaded tiles of one variant.
    public static func held(variant: String, hashes: [String: String]) -> [String: String] {
        Dictionary(hashes.map { ("\(variant):\($0.key)", $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// The rev-socket subscribe (with the held tiles: the server answers with what changed since).
    public static func subscribeJSON(mapID: String, held: [String: String]) -> String {
        let obj: [String: Any] = ["type": "subscribe", "map_id": mapID, "layers": ["rev"], "held": held]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return #"{"type":"subscribe","map_id":"\#(mapID)","layers":["rev"]}"#
        }
        return String(decoding: d, as: UTF8.self)
    }

    /// A held update (replace = the full held set).
    public static func heldJSON(_ held: [String: String]) -> String {
        let obj: [String: Any] = ["type": "held", "held": held, "replace": true]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: offline edit queue

public struct EditOp: Codable, Equatable, Sendable {
    public var key: String               // Idempotency-Key (stable across resends and app restarts)
    public var method: String
    public var path: String
    public var body: Data?
    public var entityID: String?
    /// The entity's server `updated` when the edit was made (nil = unknown / new): a 409 re-read compares it.
    public var seenUpdated: Double?
    public var created: Double
    public var attempts: Int = 0
    /// Coalescing: a newer op with the same coalesce key replaces a queued older one (a bulk "whole set" save).
    public var coalesce: String?

    public init(key: String, method: String, path: String, body: Data?, entityID: String? = nil,
                seenUpdated: Double? = nil, created: Double, coalesce: String? = nil) {
        self.key = key; self.method = method; self.path = path; self.body = body; self.entityID = entityID
        self.seenUpdated = seenUpdated; self.created = created; self.coalesce = coalesce
    }
}

public struct EditQueue: Codable, Equatable, Sendable {
    public private(set) var ops: [EditOp] = []
    public static let maxOps = 200

    public init() {}

    public var isEmpty: Bool { ops.isEmpty }
    public var count: Int { ops.count }
    public var next: EditOp? { ops.first }

    /// Queue an edit (in order). A coalescing op replaces the queued one with the same coalesce key (same place in
    /// the order). The oldest are dropped past maxOps (returned, so the caller can log them).
    @discardableResult
    public mutating func enqueue(_ op: EditOp) -> [EditOp] {
        if let c = op.coalesce, let i = ops.firstIndex(where: { $0.coalesce == c }) {
            ops[i] = op
            return []
        }
        ops.append(op)
        guard ops.count > Self.maxOps else { return [] }
        let drop = Array(ops.prefix(ops.count - Self.maxOps))
        ops.removeFirst(drop.count)
        return drop
    }

    public enum Outcome: Equatable, Sendable {
        case done                       // 2xx (or a replayed key): remove
        case retryLater                 // offline / 5xx / timeout: keep, try again
        case stale                      // 409: re-read, then `rebased`
        case drop(String)               // 4xx other than 409 (bad request, 410 deleted): remove, log
    }

    public static func outcome(status: Int?) -> Outcome {
        guard let s = status else { return .retryLater }
        switch s {
        case 200..<300: return .done
        case 409: return .stale
        case 408, 425, 429, 500...599, 0: return .retryLater
        default: return .drop("HTTP \(s)")
        }
    }

    public mutating func complete(_ key: String) { ops.removeAll { $0.key == key } }

    public mutating func bumpAttempt(_ key: String) {
        if let i = ops.firstIndex(where: { $0.key == key }) { ops[i].attempts += 1 }
    }

    /// After a 409 + re-read: is this a CONFLICT (the entity changed on the server since the edit was made)?
    public static func isConflict(_ op: EditOp, serverUpdated: Double?) -> Bool {
        guard let seen = op.seenUpdated, let now = serverUpdated else { return false }
        return now > seen + 1e-3
    }

    /// The op re-based on the server's current revision (same key: still applied at most once).
    public static func rebased(_ op: EditOp, revision: Int) -> EditOp {
        var o = op
        if let b = op.body, var obj = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] {
            obj["base_revision"] = revision
            o.body = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        }
        return o
    }

    public mutating func replace(_ op: EditOp) {
        if let i = ops.firstIndex(where: { $0.key == op.key }) { ops[i] = op }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ d: Data?) -> EditQueue { d.flatMap { try? JSONDecoder().decode(EditQueue.self, from: $0) } ?? EditQueue() }
}
