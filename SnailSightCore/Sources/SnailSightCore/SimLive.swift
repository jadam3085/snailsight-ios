import Foundation

// SnailSight 12.9 live models: EVERY sim model (animals, objects, thumbnails, the RC car's toy car, the low-poly
// RobosnailBob and drone) is served by the map server's ONE catalog (GET /v1/sim/content) and fetched at runtime, so a
// model change needs no app build. The app bundles only a minimal fallback (one animal; RobosnailBob and the drone are
// code-drawn boxes). Everything here is pure (tested in SimLiveTests); SimContentStore does the I/O.

// MARK: served low-poly models (RobosnailBob, drone)

/// One part of a served low-poly model (`agents.<key>.parts[]`).
public struct SimPartSpec: Codable, Equatable {
    public var name: String
    public var shape: String                 // "box" | "cylinderZ" | "cylinderY"
    public var corner: Double?
    public var center: [Double]
    public var size: [Double]
    public var material: String?             // "body" | "dark" | "light" | "grey"
    public var color: [Double]?              // r g b 0…1 (wins over material)

    public init(name: String, shape: String, corner: Double? = nil, center: [Double], size: [Double],
                material: String? = nil, color: [Double]? = nil) {
        self.name = name; self.shape = shape; self.corner = corner; self.center = center; self.size = size
        self.material = material; self.color = color
    }

    public init(_ p: BodyPart) {
        let sh: String, corner: Double?
        switch p.shape {
        case .box(let r): sh = "box"; corner = r
        case .cylinderZ: sh = "cylinderZ"; corner = nil
        case .cylinderY: sh = "cylinderY"; corner = nil
        }
        self.init(name: p.name, shape: sh, corner: corner, center: [p.center.x, p.center.y, p.center.z],
                  size: [p.size.x, p.size.y, p.size.z], material: p.material.rawValue)
    }

    /// nil = malformed (wrong shape name, 3-vectors missing, non-finite or non-positive size).
    public var bodyPart: BodyPart? {
        guard center.count == 3, size.count == 3, (center + size).allSatisfy({ $0.isFinite }), size.allSatisfy({ $0 > 0 }) else { return nil }
        let sh: PartShape
        switch shape {
        case "box": sh = .box(cornerRadius: corner ?? 0)
        case "cylinderZ": sh = .cylinderZ
        case "cylinderY": sh = .cylinderY
        default: return nil
        }
        return BodyPart(name, sh, center: SIMD3(center[0], center[1], center[2]), size: SIMD3(size[0], size[1], size[2]),
                        PartMaterial(rawValue: material ?? "body") ?? .body)
    }

    /// r g b of an explicit `color`, else nil.
    public var rgb: SIMD3<Double>? {
        guard let c = color, c.count == 3, c.allSatisfy({ $0.isFinite }) else { return nil }
        return SIMD3(c[0], c[1], c[2])
    }
}

public struct SimAgentModel: Codable, Equatable {
    public var frame: String?                // "model" (x fwd, y up, z right) | "map" (x fwd, y left, z up)
    public var parts: [SimPartSpec]
    public init(frame: String? = nil, parts: [SimPartSpec]) { self.frame = frame; self.parts = parts }

    /// The parts as BodyParts, nil when any part is malformed or there are none.
    public var bodyParts: [BodyPart]? {
        let b = parts.compactMap(\.bodyPart)
        return !parts.isEmpty && b.count == parts.count ? b : nil
    }
}

public enum SimAgents {
    public static let robotKey = "robot"
    public static let droneKey = "drone"
    /// Names the robot rig needs (wheels spin, the lidar yaws with the turret); a served robot without them is refused.
    public static let robotRequired: Set<String> = ["hull", "wheel.left", "wheel.right"]

    /// Served RobosnailBob parts, or nil = use RobotModel.parts().
    public static func robotParts(_ agents: [String: SimAgentModel]?) -> [BodyPart]? {
        guard let m = agents?[robotKey], let b = m.bodyParts, robotRequired.isSubset(of: Set(b.map(\.name))) else { return nil }
        return b
    }

    /// Served drone parts (map frame), or nil = the compiled-in boxes.
    public static func droneParts(_ agents: [String: SimAgentModel]?) -> [SimPartSpec]? {
        guard let m = agents?[droneKey], !m.parts.isEmpty, m.bodyParts != nil else { return nil }
        return m.parts
    }

    /// Keys whose served model differs (added, removed or changed).
    public static func changed(_ old: [String: SimAgentModel]?, _ new: [String: SimAgentModel]?) -> [String] {
        let o = old ?? [:], n = new ?? [:]
        return Set(o.keys).union(n.keys).filter { o[$0] != n[$0] }.sorted()
    }
}

// MARK: catalog diff

/// What makes a model look or behave differently: a change in any of these re-draws the bodies of that kind.
public struct SimItemFingerprint: Equatable {
    var label: String, group: String, symbol: String, category: SimCatalogItem.Category
    var files: [String: String], blobs: [String: SimBlobRef], thumb: String?
    var sizeM: [Double]?, physics: SimPhysicsSpec?, behaviour: SimBehaviourSpec?, clipInfo: [String: SimClipInfo]?
    var nominal: SimNominal?

    public init(_ i: SimCatalogItem) {
        label = i.label; group = i.group; symbol = i.symbol; category = i.category
        files = i.files ?? [:]; blobs = i.blobs ?? [:]; thumb = i.thumb
        sizeM = i.sizeM; physics = i.physics; behaviour = i.behaviour; clipInfo = i.clipInfo; nominal = i.nominal
    }
}

public struct SimContentDiff: Equatable {
    public var added: [String] = []
    public var removed: [String] = []
    public var changed: [String] = []
    public var agents: [String] = []
    public init(added: [String] = [], removed: [String] = [], changed: [String] = [], agents: [String] = []) {
        self.added = added; self.removed = removed; self.changed = changed; self.agents = agents
    }
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && agents.isEmpty }
    /// Kinds whose open bodies must be re-drawn (changed + added: a box placeholder may now have a model).
    public var redraw: Set<String> { Set(changed + added + agents) }
    public var count: Int { added.count + removed.count + changed.count + agents.count }

    public static func diff(old: [SimCatalogItem], new: [SimCatalogItem], oldAgents: [String: SimAgentModel]? = nil,
                            newAgents: [String: SimAgentModel]? = nil) -> SimContentDiff {
        let o = Dictionary(old.map { ($0.key, SimItemFingerprint($0)) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(new.map { ($0.key, SimItemFingerprint($0)) }, uniquingKeysWith: { a, _ in a })
        return SimContentDiff(added: n.keys.filter { o[$0] == nil }.sorted(), removed: o.keys.filter { n[$0] == nil }.sorted(),
                              changed: n.keys.filter { o[$0] != nil && o[$0] != n[$0] }.sorted(),
                              agents: SimAgents.changed(oldAgents, newAgents))
    }
}

// MARK: catalog WS event

/// `{"type":"catalog","rev",…,"changed":[…],"removed":[…]}` (and the hello's `catalog_rev`): the server's catalog moved.
public struct SimCatalogEvent: Equatable {
    public var rev: String
    public var items: Int?
    public var changed: [String]
    public var removed: [String]
    public var fromHello: Bool

    struct Raw: Decodable {
        var type: String?
        var rev: String?
        var catalog_rev: String?
        var items: Int?
        var changed: [String]?
        var removed: [String]?
    }

    public static func parse(_ data: Data) -> SimCatalogEvent? {
        guard let r = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        if r.type == "catalog", let rev = r.rev {
            return SimCatalogEvent(rev: rev, items: r.items, changed: r.changed ?? [], removed: r.removed ?? [], fromHello: false)
        }
        if r.type == "hello", let rev = r.catalog_rev {
            return SimCatalogEvent(rev: rev, items: nil, changed: [], removed: [], fromHello: true)
        }
        return nil
    }

    /// Worth a fetch: the server's rev is not the one the app holds.
    public func isNews(known: String?) -> Bool { rev != known }
}

// MARK: blob cache policy

public struct SimBlobEntry: Equatable {
    public var name: String
    public var bytes: Int
    public var lastUse: Double
    public init(name: String, bytes: Int, lastUse: Double) { self.name = name; self.bytes = bytes; self.lastUse = lastUse }
}

public enum SimBlobCache {
    public static let defaultBudget = 600 * 1024 * 1024

    /// Blobs to delete now. `inUse` = everything the exposed items and the current document reference (so previous-rev
    /// blobs nothing references any more are freed); `protected` = blobs of spawned bodies and recents (never evicted
    /// for the budget). Over `budget`: least recently used unprotected in-use blobs go first.
    public static func evict(entries: [SimBlobEntry], inUse: Set<String>, protected: Set<String>, budget: Int) -> [String] {
        var out = entries.filter { !inUse.contains($0.name) && !protected.contains($0.name) }.map(\.name)
        let drop = Set(out)
        var total = entries.filter { !drop.contains($0.name) }.reduce(0) { $0 + $1.bytes }
        for e in entries.filter({ !drop.contains($0.name) && !protected.contains($0.name) }).sorted(by: { $0.lastUse < $1.lastUse }) {
            guard total > budget else { break }
            out.append(e.name)
            total -= e.bytes
        }
        return out
    }

    /// Missing blobs in fetch order — items of spawned bodies, then changed/new items, then recents, then the rest in
    /// catalog order — dropping what would not fit the budget next to what is already cached.
    public static func fetchPlan(items: [SimCatalogItem], have: Set<String>, haveBytes: Int, spawned: Set<String>,
                                 changed: Set<String>, recents: [String], budget: Int) -> [(blob: String, ref: SimBlobRef, key: String)] {
        let rank: (SimCatalogItem) -> Int = { i in
            if spawned.contains(i.key) { return 0 }
            if changed.contains(i.key) { return 1 }
            if recents.contains(i.key) { return 2 }
            return 3
        }
        let order = items.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if ra == 2 { return (recents.firstIndex(of: a.element.key) ?? 0) < (recents.firstIndex(of: b.element.key) ?? 0) }
            return a.offset < b.offset
        }.map(\.element)
        var seen = Set<String>(), out: [(String, SimBlobRef, String)] = []
        var total = haveBytes
        for it in order {
            let files = SimContent.phoneFiles(it) ?? []
            let need = files.filter { !have.contains($0.blob) && !seen.contains($0.blob) }
            let add = need.reduce(0) { $0 + ($1.ref.bytes ?? 0) }
            if rank(it) >= 2, total + add > budget { continue }          // an item is all-or-nothing: never a partial download
            for f in need where seen.insert(f.blob).inserted { out.append((f.blob, f.ref, it.key)) }
            total += add
        }
        return out
    }
}

// MARK: fallback

public enum SimFileSource: Equatable {
    case runtime(String)          // blob name in the cache
    case bundled(String)          // file name in the app bundle
    case none
}

public extension SimContent {
    /// Where a catalog file comes from: a verified cached blob wins, else the minimal bundle, else nowhere.
    static func source(for file: String, runtimeItems: [SimCatalogItem], have: Set<String>, bundledFiles: Set<String>) -> SimFileSource {
        if let b = blob(for: file, in: runtimeItems), have.contains(b) { return .runtime(b) }
        if bundledFiles.contains(file) { return .bundled(file) }
        return .none
    }

    /// What the minimal bundle exposes offline: its items whose every phone file is bundled.
    static func fallbackCatalog(bundled: SimCatalog, bundledFiles: Set<String>) -> SimCatalog {
        let items = bundled.items.filter { it in
            let f = it.files ?? [:]
            return !f.isEmpty && f.values.allSatisfy { bundledFiles.contains($0) }
        }
        return SimCatalog(version: bundled.version, items: items)
    }

    /// The runtime items to expose after a new document: an item whose files are ALL on disk is taken from the document;
    /// otherwise the previously exposed version stays (while its files are still on disk); items the document no longer
    /// lists are dropped.
    static func reconcile(previous: [SimCatalogItem], doc: [SimCatalogItem], have: Set<String>) -> [SimCatalogItem] {
        let prev = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [SimCatalogItem] = []
        for it in doc {
            if let fs = phoneFiles(it), fs.allSatisfy({ have.contains($0.blob) }) { out.append(it) }
            else if let p = prev[it.key], let fs = phoneFiles(p), fs.allSatisfy({ have.contains($0.blob) }) { out.append(p) }
        }
        return out
    }

    /// Blob names referenced by these items.
    static func referenced(items: [SimCatalogItem]) -> Set<String> {
        var s = Set<String>()
        for it in items { for f in phoneFiles(it) ?? [] { s.insert(f.blob) } }
        return s
    }
}
