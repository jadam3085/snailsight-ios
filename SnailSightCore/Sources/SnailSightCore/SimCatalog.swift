import Foundation

// SnailSight 9.8 spawn catalog (owner: "add a lot more options for animals and objects"). The data lives in
// Resources/SimModels/catalog.json, written by tools/ilidar_build/verify_sim_assets.py from the source spec
// tools/ilidar_build/sim_assets.json after the Blender conversion: every item carries its MEASURED size (pxr, skinning
// baked) so the selection box, collision footprint and support probes match what is drawn (the 9.3.65 "double size"
// audit, now enforced by SimCatalogTests against the real file). All sizes are 100 %; the Sim scale shrinks them.

public struct SimPhysicsSpec: Codable, Equatable {
    public enum Shape: String, Codable, Equatable { case box, sphere, cylinder, convex }
    public var shape: Shape
    public var massKg: Double
    public var friction: Double
    public var restitution: Double
    public var rolls: Bool?
    public var linearDamping: Double?

    enum CodingKeys: String, CodingKey {
        case shape, friction, restitution, rolls
        case massKg = "mass_kg", linearDamping = "linear_damping"
    }

    public init(shape: Shape, massKg: Double, friction: Double, restitution: Double, rolls: Bool? = nil,
                linearDamping: Double? = nil) {
        self.shape = shape; self.massKg = massKg; self.friction = friction; self.restitution = restitution
        self.rolls = rolls; self.linearDamping = linearDamping
    }
}

public struct SimBehaviourSpec: Codable, Equatable {
    public var calm: String
    public var walkSpeed: Double
    public var fleeSpeed: Double
    public var scarePerson: Double
    public var scareRobot: Double
    public var fleeDist: Double
    public var runAbove: Double

    enum CodingKeys: String, CodingKey {
        case calm
        case walkSpeed = "walk_speed", fleeSpeed = "flee_speed", scarePerson = "scare_person"
        case scareRobot = "scare_robot", fleeDist = "flee_dist", runAbove = "run_above"
    }

    public init(calm: String, walkSpeed: Double, fleeSpeed: Double, scarePerson: Double, scareRobot: Double,
                fleeDist: Double, runAbove: Double) {
        self.calm = calm; self.walkSpeed = walkSpeed; self.fleeSpeed = fleeSpeed; self.scarePerson = scarePerson
        self.scareRobot = scareRobot; self.fleeDist = fleeDist; self.runAbove = runAbove
    }
}

public struct SimNominal: Codable, Equatable {
    public var lengthM: Double?
    public var heightM: Double?
    enum CodingKeys: String, CodingKey { case lengthM = "length_m", heightM = "height_m" }
    public init(lengthM: Double? = nil, heightM: Double? = nil) { self.lengthM = lengthM; self.heightM = heightM }
}

public struct SimSource: Codable, Equatable {
    public var pack: String
    public var url: String?
    public var license: String
    public var author: String?
    public init(pack: String, url: String? = nil, license: String, author: String? = nil) {
        self.pack = pack; self.url = url; self.license = license; self.author = author
    }
}

public struct SimCatalogItem: Codable, Equatable, Identifiable {
    public enum Category: String, Codable, Equatable { case animal, object }
    public var key: String
    public var label: String
    public var category: Category
    public var group: String
    public var symbol: String
    public var nominal: SimNominal?
    /// clip ("idle", "walk", "run", "eat", "static") → bundled USDZ file name
    public var files: [String: String]?
    /// [length along +X, height, width] in metres at 100 %, measured from the exported USDZ
    public var sizeM: [Double]?
    public var physics: SimPhysicsSpec?
    public var behaviour: SimBehaviourSpec?
    public var spawnCount: Int?
    public var thumb: String?
    public var tris: Int?
    public var source: SimSource?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, category, group, symbol, nominal, files, physics, behaviour, thumb, tris, source
        case sizeM = "size_m", spawnCount = "spawn_count"
    }

    public init(key: String, label: String, category: Category, group: String, symbol: String, sizeM: [Double],
                files: [String: String]? = nil, physics: SimPhysicsSpec? = nil, behaviour: SimBehaviourSpec? = nil,
                spawnCount: Int? = nil, thumb: String? = nil, nominal: SimNominal? = nil, source: SimSource? = nil) {
        self.key = key; self.label = label; self.category = category; self.group = group; self.symbol = symbol
        self.sizeM = sizeM; self.files = files; self.physics = physics; self.behaviour = behaviour
        self.spawnCount = spawnCount; self.thumb = thumb; self.nominal = nominal; self.source = source
    }

    /// Body size (length along heading, height, width) at 100 %.
    public var size: SIMD3<Double> {
        guard let s = sizeM, s.count == 3 else { return SIMD3(0.3, 0.3, 0.3) }
        return SIMD3(s[0], s[1], s[2])
    }

    public var isAnimal: Bool { category == .animal }

    /// Clip names this item has a file for.
    public var clips: Set<String> { Set((files ?? [:]).keys) }

    public func file(clip: String) -> String? { files?[clip] }

    /// Physics for an object (animals have none; a sane default keeps a bad catalog row usable).
    public var physicsOrDefault: SimPhysicsSpec {
        physics ?? SimPhysicsSpec(shape: .box, massKg: 0.5, friction: 0.6, restitution: 0.1)
    }

    /// Rough body mass for pushing (kg at 100 %): objects from the catalog, animals ~60 kg/m³ of their box
    /// (deer 1.5 × 1.4 × 0.45 m → 57 kg, rabbit → 1.3 kg).
    public var massKg: Double {
        if let p = physics { return p.massKg }
        let s = size
        return max(0.2, 60 * s.x * s.y * s.z)
    }
}

public struct SimCatalog: Codable, Equatable {
    public var version: Int
    public var items: [SimCatalogItem]

    public init(version: Int = 1, items: [SimCatalogItem]) { self.version = version; self.items = items }

    public static func decode(_ data: Data) throws -> SimCatalog {
        try JSONDecoder().decode(SimCatalog.self, from: data)
    }

    public func item(_ key: String) -> SimCatalogItem? { items.first { $0.key == key } }
    public var animals: [SimCatalogItem] { items.filter { $0.category == .animal } }
    public var objects: [SimCatalogItem] { items.filter { $0.category == .object } }

    /// Picker sections in catalog order: (group, items) for one category.
    public func groups(_ c: SimCatalogItem.Category) -> [(String, [SimCatalogItem])] {
        var order: [String] = []
        var by: [String: [SimCatalogItem]] = [:]
        for it in items where it.category == c {
            if by[it.group] == nil { order.append(it.group) }
            by[it.group, default: []].append(it)
        }
        return order.map { ($0, by[$0]!) }
    }

    /// Search by label, key or group (case/diacritic-insensitive prefix of any word, or substring of 3+ chars).
    public func search(_ q: String) -> [SimCatalogItem] {
        let n = SimCatalog.norm(q)
        guard !n.isEmpty else { return items }
        return items.filter { it in
            let hay = [it.label, it.key, it.group].map(SimCatalog.norm)
            return hay.contains { h in
                h.split(separator: " ").contains { $0.hasPrefix(n) } || (n.count >= 3 && h.contains(n))
            }
        }
    }

    static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Used when catalog.json is missing (an old bundle): the three 9.7 animals with their 9.7 sizes.
    public static let builtIn = SimCatalog(items: [
        SimCatalogItem(key: "deer", label: "Deer", category: .animal, group: "Wild", symbol: "hare.fill",
                       sizeM: [1.5, 1.4, 0.45], files: ["idle": "deer_idle.usdz", "walk": "deer_walk.usdz", "run": "deer_run.usdz",
                                                         "eat": "deer_eat.usdz"]),
        SimCatalogItem(key: "fox", label: "Fox", category: .animal, group: "Wild", symbol: "pawprint.fill",
                       sizeM: [0.8, 0.45, 0.25], files: ["idle": "fox_idle.usdz", "walk": "fox_walk.usdz", "run": "fox_run.usdz"]),
        SimCatalogItem(key: "rabbit", label: "Rabbit", category: .animal, group: "Pets", symbol: "hare",
                       sizeM: [0.35, 0.3, 0.2], files: ["idle": "rabbit_idle.usdz", "walk": "rabbit_walk.usdz",
                                                         "run": "rabbit_run.usdz", "eat": "rabbit_eat.usdz"]),
    ])
}

/// "Recent" row of the spawn picker: most recent first, no duplicates, capped.
public struct SimRecents: Equatable {
    public private(set) var keys: [String]
    public let cap: Int
    public init(keys: [String] = [], cap: Int = 6) {
        self.cap = cap
        var seen = Set<String>()
        self.keys = Array(keys.filter { seen.insert($0).inserted }.prefix(cap))
    }
    public mutating func used(_ key: String) {
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        if keys.count > cap { keys.removeLast(keys.count - cap) }
    }
}

extension SpeciesProfile {
    /// Behaviour profile for a catalog animal at 100 %. The three 9.7 species keep their tuned profiles; new ones get
    /// the catalog's numbers with a radius from the measured body (deer 0.35 m, rabbit 0.15 m).
    public static func from(_ item: SimCatalogItem) -> SpeciesProfile {
        if let p = SpeciesProfile.all.first(where: { $0.name == item.key }) { return p }
        let s = item.size
        let b = item.behaviour ?? SimBehaviourSpec(calm: "graze", walkSpeed: 0.4, fleeSpeed: 1.8, scarePerson: 1.0,
                                                   scareRobot: 1.4, fleeDist: 2.0, runAbove: 1.0)
        var p = SpeciesProfile(name: item.key, radius: max(0.06, 0.5 * s.z, 0.23 * s.x),
                               calm: b.calm == "stopgo" ? .stopgo : .graze, walkSpeed: b.walkSpeed,
                               scareRobot: b.scareRobot, scarePerson: b.scarePerson, fleeSpeed: b.fleeSpeed,
                               fleeDist: b.fleeDist, fleeJitter: b.fleeDist * 0.25, runAbove: b.runAbove)
        p.lookahead = max(0.25, 0.4 * s.x)
        if s.x < 0.5 { p.dwell = 4...10; p.moveTime = 1...3; p.turnSigmaDeg = 80 }
        return p
    }
}
