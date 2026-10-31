import Foundation

// SnailSight 12.22 islands in the app (server live 0.10, API §6b.13; design docs/SNAILSIGHT-ISLANDS-2026-10-31.md).
// A walk the server cannot place in the house becomes an ISLAND: its own live map `<base>~isl-<hex6>` in its own
// frame (the founder's odometry, z up), joined to the house / other islands later by geometry only. The world is a
// pose graph of frames; a client places an island's tiles with `placement.T_house_frame` (exact when joined to the
// house by geometry, approximate when only GPS places it).
//
// Pure part (Linux-tested): the world state from REST / WS / ack, the pill's wording, AR placement of an island's
// tiles (own frame / chained through the island you are in / house frame), outlines on the 2D Map at their lat/lon,
// and which island feeds the memory budget allows.

public struct IslandPlacement: Equatable {
    public var known: Bool
    public var exact: Bool
    public var approx: Bool
    public var T_house_frame: Mat4?
    public var sigmaM: Double?
    public var sigmaYawDeg: Double?
    public var component: String?
    public var componentSize: Int?
    public var via: String?
    public var lat: Double?
    public var lon: Double?
    public var geoSigmaM: Double?
    /// This frame's datum (frame -> WGS84), when its component is georeferenced.
    public var datum: GeoDatum?

    public init(known: Bool = false, exact: Bool = false, approx: Bool = false, T_house_frame: Mat4? = nil,
                sigmaM: Double? = nil, sigmaYawDeg: Double? = nil, component: String? = nil, componentSize: Int? = nil,
                via: String? = nil, lat: Double? = nil, lon: Double? = nil, geoSigmaM: Double? = nil, datum: GeoDatum? = nil) {
        self.known = known; self.exact = exact; self.approx = approx; self.T_house_frame = T_house_frame
        self.sigmaM = sigmaM; self.sigmaYawDeg = sigmaYawDeg; self.component = component; self.componentSize = componentSize
        self.via = via; self.lat = lat; self.lon = lon; self.geoSigmaM = geoSigmaM; self.datum = datum
    }

    public init(json o: [String: Any]?) {
        let o = o ?? [:]
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        let T = (o["T_house_frame"] as? [NSNumber]).map { $0.map(\.doubleValue) }
        let geo = o["geo"] as? [String: Any]
        self.init(known: (o["known"] as? Bool) ?? false, exact: (o["exact"] as? Bool) ?? false,
                  approx: (o["approx"] as? Bool) ?? false,
                  T_house_frame: T.flatMap { $0.count == 16 && $0.allSatisfy(\.isFinite) ? Mat4($0) : nil },
                  sigmaM: d("sigma_m"), sigmaYawDeg: d("sigma_yaw_deg"), component: o["component"] as? String,
                  componentSize: (o["component_size"] as? NSNumber)?.intValue, via: o["via"] as? String,
                  lat: (geo?["lat"] as? NSNumber)?.doubleValue, lon: (geo?["lon"] as? NSNumber)?.doubleValue,
                  geoSigmaM: (geo?["sigma_m"] as? NSNumber)?.doubleValue,
                  datum: GeoDatum(json: o["datum"] as? [String: Any]))
    }

    /// The ± metres the pill / outline label shows: 0 when exact, the placement sigma, else the geo sigma.
    public var plusMinusM: Double? { exact ? 0 : (sigmaM ?? geoSigmaM) }
}

public struct IslandInfo: Equatable {
    public var id: String
    public var mapID: String
    public var state: String
    public var keyframes: Int
    /// Camera positions' box in the island frame: [[x, y, z], [x, y, z]].
    public var bbox: [[Double]]?
    public var placement: IslandPlacement
    /// The island's path in its frame (GET /v1/live/islands/{id}, <= 500 points), when fetched.
    public var path: [[Double]]?

    public init(id: String, mapID: String, state: String = "provisional", keyframes: Int = 0, bbox: [[Double]]? = nil,
                placement: IslandPlacement = IslandPlacement(), path: [[Double]]? = nil) {
        self.id = id; self.mapID = mapID; self.state = state; self.keyframes = keyframes; self.bbox = bbox
        self.placement = placement; self.path = path
    }

    public init?(json o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        let bb = (o["bbox"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) }
        self.init(id: id, mapID: (o["map_id"] as? String) ?? id, state: (o["state"] as? String) ?? "provisional",
                  keyframes: (o["keyframes"] as? NSNumber)?.intValue ?? 0,
                  bbox: bb.flatMap { $0.count == 2 && $0.allSatisfy { $0.count >= 2 } ? $0 : nil },
                  placement: IslandPlacement(json: o["placement"] as? [String: Any]))
    }

    /// "ab12cd" from "isl-ab12cd" (the pill's short name).
    public var shortName: String { id.hasPrefix("isl-") ? String(id.dropFirst(4)) : id }
    public var live: Bool { state != "retired" }
}

/// One `ack.islands` entry: an island this phone's stream feeds.
public struct IslandAck: Equatable {
    public var island: String
    public var mapID: String
    public var placed: Bool
    public var exact: Bool?
    public var approx: Bool?
    public var worldRev: Int?

    public init(island: String, mapID: String, placed: Bool, exact: Bool? = nil, approx: Bool? = nil, worldRev: Int? = nil) {
        self.island = island; self.mapID = mapID; self.placed = placed; self.exact = exact; self.approx = approx
        self.worldRev = worldRev
    }

    public static func parse(_ ack: [String: Any]) -> [IslandAck] {
        guard let l = ack["islands"] as? [[String: Any]] else { return [] }
        return l.compactMap { o in
            guard let i = o["island"] as? String else { return nil }
            return IslandAck(island: i, mapID: (o["map_id"] as? String) ?? i, placed: (o["placed"] as? Bool) ?? false,
                             exact: o["exact"] as? Bool, approx: o["approx"] as? Bool,
                             worldRev: (o["world_rev"] as? NSNumber)?.intValue)
        }
    }
}

/// What the localization pill says about islands (nil = nothing to say).
public struct IslandPillNote: Equatable {
    public enum Kind: Equatable {
        case founding           // island id known, this stream not placed in it yet ("joining")
        case mapping            // placed in the island
        case farFromHouse       // no island yet, but GPS says we are far from the house: a new area is being mapped
    }
    public var kind: Kind
    public var name: String?
    public var exact: Bool
    public var plusMinusM: Double?
    public var distanceM: Double?
    public var keyframes: Int?

    public init(kind: Kind, name: String? = nil, exact: Bool = false, plusMinusM: Double? = nil, distanceM: Double? = nil,
                keyframes: Int? = nil) {
        self.kind = kind; self.name = name; self.exact = exact; self.plusMinusM = plusMinusM; self.distanceM = distanceM
        self.keyframes = keyframes
    }

    public static func metres(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        if m >= 100 { return String(format: "%.0f m", (m / 10).rounded() * 10) }
        return String(format: "%.0f m", max(1, m.rounded(.up)))
    }

    /// The pill's one line (title case after the caps head, as the other pill states).
    public var text: String {
        switch kind {
        case .farFromHouse:
            var where_ = "away from the house"
            if let d = distanceM { where_ = "~" + Self.metres(d) + " from the house" }
            return "NEW AREA · " + where_ + " · mapping"
        case .founding:
            return "NEW AREA · joining island ‹\(name ?? "?")›"
        case .mapping:
            var t = "NEW AREA · island ‹\(name ?? "?")›"
            if exact { t += " · joined to the house" }
            else if let p = plusMinusM { t += " · approx ±" + Self.metres(p) }
            else { t += " · location unknown" }
            return t
        }
    }

    public var rows: [String] {
        var r: [String]
        switch kind {
        case .farFromHouse:
            r = ["This walk is outside the mapped house: the server maps it as a new area (an island) after ~30 s",
                 "Nothing is wrong: localization against the house keeps trying in the background"]
        case .founding:
            r = ["This walk matched island ‹\(name ?? "?")›: the server places it after agreeing matches",
                 "It joins that island's map; nothing is lost meanwhile"]
        case .mapping:
            let nm = name ?? "?"
            var head = "Mapping a new area: island ‹" + nm + "›"
            if let k = keyframes { head += ", \(k) keyframes" }
            r = [head]
            if exact { r.append("Joined to the house by geometry: drawn where it really is") }
            else if let p = plusMinusM { r.append("Approximate location from GPS (±\(Self.metres(p))): never fused into the map") }
            else { r.append("No GPS fix yet: the island has its own frame until a walk joins it") }
        }
        r.append("A later walk that overlaps joins the areas automatically")
        return r
    }
}

/// An island outline in the HOUSE frame (2D Map): a closed polygon, dashed when approximate.
public struct IslandOutline: Equatable {
    public var id: String
    public var name: String
    public var points: [[Double]]          // house-frame x, y (closed: first point not repeated)
    public var path: [[Double]]            // house-frame path, when fetched
    public var dashed: Bool
    public var plusMinusM: Double?
    public var mine: Bool
    public var centre: [Double] {
        guard !points.isEmpty else { return [0, 0] }
        let n = Double(points.count)
        var sx = 0.0, sy = 0.0
        for p in points { sx += p[0]; sy += p[1] }
        return [sx / n, sy / n]
    }
    public var label: String {
        var t = "island " + name
        if dashed {
            if let p = plusMinusM { t += " · ±" + IslandPillNote.metres(p) } else { t += " · approx" }
        }
        return t
    }
}

public struct IslandWorld: Equatable {
    public private(set) var base: String?
    public private(set) var rev = -1
    public private(set) var houseDatum: GeoDatum?
    public private(set) var islands: [String: IslandInfo] = [:]
    public private(set) var joins = 0
    /// The islands this phone's stream feeds (the newest ack).
    public private(set) var mine: [IslandAck] = []

    public init() {}

    /// Ordered ids (stable for UI / logs).
    public var ids: [String] { islands.keys.sorted() }

    /// GET /v1/live/islands?map_id=… (the full doc, house datum included). Older revisions are ignored.
    @discardableResult
    public mutating func applyDoc(_ o: [String: Any]) -> Bool {
        guard let r = (o["rev"] as? NSNumber)?.intValue else { return false }
        let hd = GeoDatum(json: (o["house"] as? [String: Any])?["datum"] as? [String: Any])
        if r < rev { return false }
        let changed = r != rev || hd != houseDatum
        if hd != nil { houseDatum = hd }
        return replace(o, rev: r) || changed
    }

    /// The WS `{"type": "islands"}` world revision (base map feed and every island feed). Same rev = no-op.
    @discardableResult
    public mutating func applyMessage(_ o: [String: Any]) -> Bool {
        guard (o["type"] as? String) == "islands", let r = (o["rev"] as? NSNumber)?.intValue, r > rev else { return false }
        return replace(o, rev: r)
    }

    private mutating func replace(_ o: [String: Any], rev r: Int) -> Bool {
        if let b = o["base"] as? String { base = b }
        var next: [String: IslandInfo] = [:]
        for x in (o["islands"] as? [[String: Any]]) ?? [] {
            guard var i = IslandInfo(json: x) else { continue }
            i.path = islands[i.id]?.path            // keep a fetched path across revisions
            next[i.id] = i
        }
        let j = ((o["joins"] as? [[String: Any]]) ?? []).filter { ($0["state"] as? String ?? "active") != "rolled_back" }.count
        let changed = next != islands || r != rev || j != joins
        islands = next
        joins = j
        rev = r
        return changed
    }

    public mutating func setPath(_ id: String, _ path: [[Double]]) { islands[id]?.path = path }

    /// The uplink ack (every ack): `changed` = the island list of this stream changed; `fetch` = the ack names a newer
    /// world revision or an island we do not know (read the REST doc).
    public mutating func applyAck(_ ack: [String: Any]) -> (changed: Bool, fetch: Bool) {
        let a = IslandAck.parse(ack)
        let changed = a != mine
        mine = a
        let fetch = a.contains { ($0.worldRev ?? -1) > rev || islands[$0.island] == nil }
        return (changed, fetch)
    }

    /// A new stream / Live map off: this phone feeds no island now.
    public mutating func clearMine() { mine = [] }

    /// The island this phone is in: placed first, then the newest-named.
    public var current: IslandAck? { mine.first { $0.placed } ?? mine.first }

    /// The pill's note. `farFromHouseM` = GPS distance from the house when no island exists yet (nil = unknown / near).
    public func pillNote(farFromHouseM: Double? = nil) -> IslandPillNote? {
        if let c = current {
            let info = islands[c.island]
            let name = info?.shortName ?? (c.island.hasPrefix("isl-") ? String(c.island.dropFirst(4)) : c.island)
            guard c.placed else { return IslandPillNote(kind: .founding, name: name) }
            let exact = info?.placement.exact ?? c.exact ?? false
            return IslandPillNote(kind: .mapping, name: name, exact: exact,
                                  plusMinusM: exact ? 0 : info?.placement.plusMinusM, keyframes: info?.keyframes)
        }
        if let d = farFromHouseM { return IslandPillNote(kind: .farFromHouse, distanceM: d) }
        return nil
    }

    // MARK: placement

    /// T_a_b (frame b -> frame a) for two islands of the SAME component that both carry T_house_frame (the server
    /// derives both from the same component root, so the relative transform is exact even when the component itself
    /// is only approximately placed).
    public func relative(_ a: String, _ b: String) -> Mat4? {
        if a == b { return .identity }
        guard let pa = islands[a]?.placement, let pb = islands[b]?.placement, let ca = pa.component, ca == pb.component,
              let Ta = pa.T_house_frame, let Tb = pb.T_house_frame else { return nil }
        return Ta.inverse * Tb
    }

    /// Where island `id`'s tiles go in AR: T_arkit_island, or nil (not drawn in AR).
    /// - `islandArkit`: T_island_arkit of the islands this phone is placed in (their live feed's correction for our
    ///   stream). The phone draws such an island in its OWN frame.
    /// - otherwise chained through an island the phone is in (same component);
    /// - otherwise, with the house lock (`houseArkit` = T_house_arkit), an EXACT island through T_house_frame.
    ///   Approximate islands are never drawn in AR (metres off).
    public func arPlacement(_ id: String, islandArkit: [String: Mat4], houseArkit: Mat4?) -> Mat4? {
        guard islands[id]?.live ?? true else { return nil }
        if let T = islandArkit[id] { return T.inverse }
        for (c, T) in islandArkit.sorted(by: { $0.key < $1.key }) {
            if let Tci = relative(c, id) { return T.inverse * Tci }
        }
        if let H = houseArkit, let p = islands[id]?.placement, p.exact, let Th = p.T_house_frame {
            return H.inverse * Th
        }
        return nil
    }

    /// Map 3D: T_house_island for every island with a placement (exact first), with its approx flag.
    public func map3DPlacements() -> [(id: String, T: Mat4, approx: Bool)] {
        islands.values.filter(\.live).compactMap { i -> (id: String, T: Mat4, approx: Bool)? in
            guard let T = i.placement.T_house_frame else { return nil }
            return (i.id, T, !i.placement.exact)
        }.sorted { a, b in
            if a.approx != b.approx { return !a.approx }
            return a.id < b.id
        }
    }

    // MARK: 2D Map outlines

    /// The island's box corners (its frame) as a polygon.
    static func corners(_ bb: [[Double]]?, pad: Double = 1) -> [[Double]]? {
        guard let bb, bb.count == 2 else { return nil }
        let x0 = bb[0][0] - pad, y0 = bb[0][1] - pad, x1 = bb[1][0] + pad, y1 = bb[1][1] + pad
        return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]
    }

    /// Frame points of island `id` in the house frame: through lat/lon for an approximate island when both datums are
    /// known (the outline sits at its GPS lat/lon), else through T_house_frame.
    public func toHouse(_ id: String, _ pts: [[Double]]) -> [[Double]]? {
        guard let p = islands[id]?.placement else { return nil }
        if !p.exact, let d = p.datum, let h = houseDatum {
            return pts.map { q in
                let ll = d.toLatLon(x: q[0], y: q[1])
                let m = h.fromLatLon(lat: ll.lat, lon: ll.lon)
                return [m.x, m.y]
            }
        }
        guard let T = p.T_house_frame else { return nil }
        return pts.map { q in let r = T.apply([q[0], q[1], q.count > 2 ? q[2] : 0]); return [r[0], r[1]] }
    }

    public func outlines() -> [IslandOutline] {
        let mineIDs = Set(mine.map(\.island))
        return ids.compactMap { id -> IslandOutline? in
            guard let i = islands[id], i.live, let c = Self.corners(i.bbox), let pts = toHouse(id, c) else { return nil }
            let path = i.path.flatMap { toHouse(id, $0) } ?? []
            return IslandOutline(id: id, name: i.shortName, points: pts, path: path, dashed: !i.placement.exact,
                                 plusMinusM: i.placement.plusMinusM, mine: mineIDs.contains(id))
        }
    }

    /// GPS distance (m) of a fix from the house, via the house datum (its centroid when the datum has one, else the
    /// frame origin); nil without a house datum.
    public func distanceFromHouse(lat: Double, lon: Double) -> Double? {
        guard let h = houseDatum else { return nil }
        let p = h.fromLatLon(lat: lat, lon: lon)
        let c = h.centroidMap ?? [0, 0]
        return hypot(p.x - c[0], p.y - (c.count > 1 ? c[1] : 0))
    }

    // MARK: feeds (memory budget)

    /// Which island live feeds to hold, in priority order, within `maxMaps`:
    /// 1. the islands this phone feeds (placed first);
    /// 2. with the house lock, EXACT islands whose box comes within `radiusM` of the camera (house frame);
    /// 3. while Map 3D / the Map is open, placed islands nearest the camera (exact before approximate).
    public func feedPlan(maxMaps: Int, camHouse: [Double]?, radiusM: Double, mapOpen: Bool) -> [String] {
        guard maxMaps > 0 else { return [] }
        var out: [String] = []
        func add(_ id: String) {
            let live = islands[id]?.live ?? true
            if live && !out.contains(id) { out.append(id) }
        }
        let placedFirst = mine.sorted { a, b in
            if a.placed != b.placed { return a.placed }
            return a.island < b.island
        }
        for a in placedFirst { add(a.island) }
        var dists: [String: Double] = [:]
        for (id, i) in islands {
            var d = Double.infinity
            if let c = camHouse, let box = Self.corners(i.bbox, pad: 0), let pts = toHouse(id, box) {
                var x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
                for p in pts { x0 = min(x0, p[0]); x1 = max(x1, p[0]); y0 = min(y0, p[1]); y1 = max(y1, p[1]) }
                let dx = max(x0 - c[0], 0, c[0] - x1), dy = max(y0 - c[1], 0, c[1] - y1)
                d = hypot(dx, dy)
            }
            dists[id] = d
        }
        func closer(_ a: IslandInfo, _ b: IslandInfo) -> Bool {
            let da = dists[a.id] ?? .infinity, db = dists[b.id] ?? .infinity
            if da != db { return da < db }
            return a.id < b.id
        }
        let placed = islands.values.filter { $0.live && $0.placement.T_house_frame != nil }
        if camHouse != nil {
            for i in placed.filter({ $0.placement.exact }).sorted(by: closer) where (dists[i.id] ?? .infinity) <= radiusM {
                add(i.id)
            }
        }
        if mapOpen {
            let ordered = placed.sorted { a, b in
                if a.placement.exact != b.placement.exact { return a.placement.exact }
                return closer(a, b)
            }
            for i in ordered { add(i.id) }
        }
        return Array(out.prefix(maxMaps))
    }
}
