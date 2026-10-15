import Foundation
import simd

// 9.8 Scans labeling (owner 2026-10-13: "I may also need a way to label rooms and objects"). Pure model + logic:
// - Rooms: the server's versioned rooms doc (`GET/PUT /v1/scenes/{scene}/rooms`, API §8.4 — the same doc the web
//   viewer edits, so both stay in sync; 409 on a stale base_revision), HA area names (`GET /v1/ha/areas`), polygon
//   editing on the floor plan (tap corners, drag, insert on an edge, delete), validation as the server does it.
// - Objects: the P4 objects doc (`GET/PUT /v1/scenes/{scene}/objects`, §8.6). A phone label is an object with
//   `source: "manual"` pinned at the mesh hit point in the MAP frame (Z-up metres). Corrections of detected objects
//   (rename / re-class, delete, merge) go through the P4 endpoints when the server has them; otherwise they are the
//   pure list edits below, recorded in `attributes.phone_corrections` (§8.6a).
// - Map labels: rooms + objects as points in the map frame for AR (the localization lane draws them with T_ar_map).

/// Any JSON value (object attributes are free-form and must round-trip untouched).
public enum ScanJSON: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([ScanJSON]), object([String: ScanJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([ScanJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: ScanJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [ScanJSON]? { if case .array(let a) = self { return a }; return nil }
}

// MARK: rooms

public struct RoomRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var haAreaID: String?
    public var polygon: [[Double]]            // map frame [x, y], CCW (the server stores CCW)
    public var floorZ: Double?
    public var height: Double?
    public var color: String?
    public var areaM2: Double?
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case id, name, polygon, height, color, notes
        case haAreaID = "ha_area_id", floorZ = "floor_z", areaM2 = "area_m2"
    }

    public init(id: String, name: String, polygon: [[Double]], floorZ: Double?, height: Double? = 2.4,
                color: String? = nil, haAreaID: String? = nil, notes: String? = nil) {
        self.id = id; self.name = name; self.polygon = polygon; self.floorZ = floorZ; self.height = height
        self.color = color; self.haAreaID = haAreaID; self.notes = notes
    }

    public var points: [SIMD2<Double>] { polygon.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil } }

    /// Does this room contain a map-frame point (x, y in the polygon, z within its floor … ceiling ± 0.5 m)?
    public func contains(mapPoint p: SIMD3<Double>) -> Bool {
        guard Polygon2D.contains(points, SIMD2(p.x, p.y)) else { return false }
        guard let fz = floorZ else { return true }
        return p.z >= fz - 0.5 && p.z <= fz + (height ?? 2.4) + 0.5
    }
}

public struct RoomsDoc: Codable, Equatable {
    public var scene: String?
    public var revision: Int
    public var updated: Double?
    public var frame: String?
    public var rooms: [RoomRecord]

    public init(scene: String? = nil, revision: Int = 0, rooms: [RoomRecord] = []) {
        self.scene = scene; self.revision = revision; self.rooms = rooms
    }

    public static func decode(_ d: Data) throws -> RoomsDoc { try JSONDecoder().decode(RoomsDoc.self, from: d) }

    /// `PUT` body: `{"base_revision": N, "rooms": [...]}`.
    public func putBody() throws -> Data {
        struct Body: Encodable { let base_revision: Int; let rooms: [RoomRecord] }
        return try JSONEncoder().encode(Body(base_revision: revision, rooms: rooms))
    }

    /// The room a map-frame point is in (last drawn wins, as the web viewer).
    public func room(containing p: SIMD3<Double>) -> RoomRecord? { rooms.last { $0.contains(mapPoint: p) } }

    /// A fresh id that the server accepts (`^[A-Za-z0-9_-]+$`, unique).
    public func newRoomID() -> String {
        var i = rooms.count + 1
        while rooms.contains(where: { $0.id == "r\(i)" }) { i += 1 }
        return "r\(i)"
    }

    /// The web viewer's palette (rooms.js PALETTE / scenes.py ROOM_COLORS).
    public static let palette = ["#4363d8", "#3cb44b", "#f58231", "#911eb4", "#42d4f4", "#f032e6", "#bfef45", "#469990",
                                 "#e6194b", "#9a6324"]
    public func nextColor() -> String { Self.palette[rooms.count % Self.palette.count] }
}

/// `GET /v1/ha/areas` → `{"ok": true, "areas": [{area_id, name, floor_id, floor}]}` (read-only; nothing is written to HA).
public struct HAArea: Codable, Equatable, Identifiable {
    public var areaID: String
    public var name: String
    public var floorID: String?
    public var floor: String?
    public var id: String { areaID }
    enum CodingKeys: String, CodingKey { case name, floor, areaID = "area_id", floorID = "floor_id" }
    public init(areaID: String, name: String, floor: String? = nil) { self.areaID = areaID; self.name = name; self.floor = floor }

    public static func decodeList(_ d: Data) -> [HAArea] {
        struct R: Decodable { let areas: [HAArea]? }
        let a = (try? JSONDecoder().decode(R.self, from: d))?.areas ?? []
        return a.sorted { ($0.floor ?? "", $0.name.lowercased()) < ($1.floor ?? "", $1.name.lowercased()) }
    }

    /// Areas not used by another room yet first (the one already on this room stays offered).
    public static func suggestions(_ areas: [HAArea], rooms: [RoomRecord], editing: String?) -> [HAArea] {
        let used = Set(rooms.filter { $0.id != editing }.compactMap(\.haAreaID))
        return areas.filter { !used.contains($0.areaID) } + areas.filter { used.contains($0.areaID) }
    }
}

// MARK: polygons

public enum Polygon2D {
    /// Signed area (CCW positive), shoelace.
    public static func signedArea(_ p: [SIMD2<Double>]) -> Double {
        guard p.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<p.count {
            let q = p[i], r = p[(i + 1) % p.count]
            a += q.x * r.y - r.x * q.y
        }
        return a / 2
    }

    public static func area(_ p: [SIMD2<Double>]) -> Double { abs(signedArea(p)) }

    public static func ccw(_ p: [SIMD2<Double>]) -> [SIMD2<Double>] { signedArea(p) < 0 ? Array(p.reversed()) : p }

    /// Even-odd point in polygon.
    public static func contains(_ p: [SIMD2<Double>], _ q: SIMD2<Double>) -> Bool {
        guard p.count >= 3 else { return false }
        var inside = false
        var j = p.count - 1
        for i in 0..<p.count {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y) && q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Area-weighted centroid (vertex mean for degenerate polygons).
    public static func centroid(_ p: [SIMD2<Double>]) -> SIMD2<Double> {
        guard !p.isEmpty else { return .zero }
        let a = signedArea(p)
        guard abs(a) > 1e-9 else { return p.reduce(.zero, +) / Double(p.count) }
        var c = SIMD2<Double>.zero
        for i in 0..<p.count {
            let q = p[i], r = p[(i + 1) % p.count]
            let k = q.x * r.y - r.x * q.y
            c += (q + r) * k
        }
        return c / (6 * a)
    }

    static func segmentsCross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
        func o(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let d1 = o(c, d, a), d2 = o(c, d, b), d3 = o(a, b, c), d4 = o(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Any two non-adjacent edges cross (a bow-tie room).
    public static func selfIntersects(_ p: [SIMD2<Double>]) -> Bool {
        let n = p.count
        guard n >= 4 else { return false }
        for i in 0..<n {
            for j in (i + 1)..<n {
                if j == i + 1 || (i == 0 && j == n - 1) { continue }
                if segmentsCross(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]) { return true }
            }
        }
        return false
    }

    /// Closest point on segment ab to q and its parameter t.
    public static func closestOnSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ q: SIMD2<Double>) -> (SIMD2<Double>, Double) {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        guard l2 > 1e-18 else { return (a, 0) }
        let t = max(0, min(1, simd_dot(q - a, ab) / l2))
        return (a + ab * t, t)
    }
}

/// Room outline editing on the floor plan, in map metres. Draw: tap corners, tap the first corner (or Close) to close.
/// Edit: tap a corner to select it and drag it; tap near an edge to insert a corner there; delete the selected corner.
public struct RoomPolygonEditor: Equatable {
    public var points: [SIMD2<Double>]
    public var closed: Bool
    public var selected: Int?

    public enum Result: Equatable { case added, closed, selected(Int), inserted(Int), deselected, none }

    public init(points: [SIMD2<Double>] = [], closed: Bool = false) { self.points = points; self.closed = closed }
    public init(room: RoomRecord) { self.init(points: room.points, closed: true) }

    /// `snap` = touch tolerance in metres (the view converts ~22 pt to metres at its zoom).
    public mutating func tap(_ p: SIMD2<Double>, snap: Double) -> Result {
        if let i = nearestVertex(p, within: snap) {
            if !closed && i == 0 && points.count >= 3 { closed = true; selected = nil; return .closed }
            if closed || i == points.count - 1 { selected = i; return .selected(i) }
        }
        if !closed {
            points.append(p)
            selected = nil
            return .added
        }
        if let (i, q) = nearestEdge(p, within: snap) {
            points.insert(q, at: i + 1)
            selected = i + 1
            return .inserted(i + 1)
        }
        if selected != nil { selected = nil; return .deselected }
        return .none
    }

    public mutating func close() -> Bool {
        guard !closed, points.count >= 3 else { return false }
        closed = true
        return true
    }

    public mutating func move(_ i: Int, to p: SIMD2<Double>) {
        guard points.indices.contains(i) else { return }
        points[i] = p
    }

    /// Remove a corner; a closed room keeps at least 3.
    @discardableResult
    public mutating func delete(_ i: Int) -> Bool {
        guard points.indices.contains(i), !closed || points.count > 3 else { return false }
        points.remove(at: i)
        selected = nil
        return true
    }

    public mutating func undoLast() {
        guard !closed, !points.isEmpty else { return }
        points.removeLast()
    }

    public func nearestVertex(_ p: SIMD2<Double>, within r: Double) -> Int? {
        var best: Int? = nil, bd = r
        for (i, q) in points.enumerated() {
            let d = simd_distance(p, q)
            if d <= bd { bd = d; best = i }
        }
        return best
    }

    /// Edge i = points[i] → points[i+1] (the closing edge only when closed).
    public func nearestEdge(_ p: SIMD2<Double>, within r: Double) -> (Int, SIMD2<Double>)? {
        let n = points.count
        guard n >= 2 else { return nil }
        var best: (Int, SIMD2<Double>)? = nil, bd = r
        for i in 0..<(closed ? n : n - 1) {
            let (q, t) = Polygon2D.closestOnSegment(points[i], points[(i + 1) % n], p)
            guard t > 0.05, t < 0.95 else { continue }
            let d = simd_distance(q, p)
            if d <= bd { bd = d; best = (i, q) }
        }
        return best
    }

    /// nil = valid; else the reason (the server's rules: ≥ 3 points, ≥ 0.05 m²; plus no crossing edges).
    public func problem() -> String? {
        if points.count < 3 { return "A room needs at least 3 corners" }
        if !closed { return "Close the outline (tap the first corner)" }
        if Polygon2D.selfIntersects(points) { return "The outline crosses itself" }
        if Polygon2D.area(points) < 0.05 { return "The outline is too small" }
        return nil
    }

    /// Server form: CCW [[x, y]], rounded to mm.
    public func polygon() -> [[Double]] {
        Polygon2D.ccw(points).map { [($0.x * 1000).rounded() / 1000, ($0.y * 1000).rounded() / 1000] }
    }
}

// MARK: objects (P4 layer) and phone labels

public enum ObjectCategory: String, CaseIterable, Codable {
    case furniture, fixture, appliance, movable, other
    public var isStatic: Bool { self == .furniture || self == .fixture || self == .appliance }
}

public struct SceneObjectBox: Codable, Equatable {
    public var center: [Double]
    public var size: [Double]
    public var yaw: Double?
    public init(center: [Double], size: [Double], yaw: Double? = 0) { self.center = center; self.size = size; self.yaw = yaw }
}

public struct SceneObject: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String                  // class ("chair"); P4 lower-cases owner renames of it
    public var detLabel: String?              // P4: the detector's class before an owner rename
    public var name: String?                  // P4: the owner's name ("Mom's chair")
    public var category: String
    public var isStatic: Bool?
    public var roomID: String?
    public var haAreaID: String?
    public var centroid: [Double]             // map frame x, y, z
    public var box: SceneObjectBox?
    public var confidence: Double?
    public var firstSeen: ScanJSON?
    public var lastSeen: ScanJSON?
    public var observations: Int?
    public var state: String?
    public var sessionIDs: [String]?
    public var source: String?
    public var attributes: [String: ScanJSON]?
    public var corrections: [String]?         // P4: ids of the owner corrections applied to it

    enum CodingKeys: String, CodingKey {
        case id, label, name, category, centroid, box, confidence, observations, state, source, attributes, corrections
        case isStatic = "static", roomID = "room_id", haAreaID = "ha_area_id", firstSeen = "first_seen",
             lastSeen = "last_seen", sessionIDs = "session_ids", detLabel = "det_label"
    }

    public init(id: String, label: String, category: String, centroid: [Double], source: String? = "manual") {
        self.id = id; self.label = label; self.category = category; self.centroid = centroid; self.source = source
    }

    public var isManual: Bool { (source ?? "manual") == "manual" }
    /// What to show: the owner's name, else the class.
    public var displayName: String {
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return label
    }
    /// `attributes.note` (P4's note correction writes it); `notes` from early phone labels.
    public var notes: String { attributes?["note"]?.stringValue ?? attributes?["notes"]?.stringValue ?? "" }
    public var photoThumbBase64: String? { attributes?["photo_jpeg_b64"]?.stringValue }
    public var mapPoint: SIMD3<Double>? {
        centroid.count == 3 ? SIMD3(centroid[0], centroid[1], centroid[2]) : nil
    }
    /// Where the pin / billboard sits (map frame): the top of the box when there is one, else the centroid.
    public var pinPoint: SIMD3<Double>? {
        if let b = box, b.center.count == 3, b.size.count == 3, !isManual { return SIMD3(b.center[0], b.center[1], b.center[2] + b.size[2] / 2) }
        return mapPoint
    }
}

public struct ObjectsDoc: Codable, Equatable {
    public var scene: String?
    public var revision: Int
    public var updated: Double?
    public var detector: String?
    public var frame: String?
    public var objects: [SceneObject]

    public init(scene: String? = nil, revision: Int = 0, objects: [SceneObject] = []) {
        self.scene = scene; self.revision = revision; self.objects = objects
    }

    public static func decode(_ d: Data) throws -> ObjectsDoc { try JSONDecoder().decode(ObjectsDoc.self, from: d) }

    /// `PUT` body. `detector` is left out so the server keeps the current one (a phone edit is not a detector run).
    public func putBody() throws -> Data {
        struct Body: Encodable { let base_revision: Int; let objects: [SceneObject] }
        return try JSONEncoder().encode(Body(base_revision: revision, objects: objects))
    }
}

/// A correction made on the phone, kept in the object's `attributes.corrections` (§8.6a) so a later detector run (P4)
/// can honour it, and as the body of the P4 corrections endpoint when the server advertises `object_corrections`.
public struct ObjectCorrection: Codable, Equatable {
    public var op: String                     // rename | delete | merge | label
    public var ids: [String]
    public var into: String?
    public var label: String?
    public var category: String?
    public var by: String
    public var at: Double
    public init(op: String, ids: [String], into: String? = nil, label: String? = nil, category: String? = nil, by: String, at: Double) {
        self.op = op; self.ids = ids; self.into = into; self.label = label; self.category = category; self.by = by; self.at = at
    }

    var json: ScanJSON {
        var o: [String: ScanJSON] = ["op": .string(op), "ids": .array(ids.map { .string($0) }), "by": .string(by), "at": .number(at)]
        if let into { o["into"] = .string(into) }
        if let label { o["label"] = .string(label) }
        if let category { o["category"] = .string(category) }
        return .object(o)
    }
}

public enum ObjectEdits {
    /// A new phone label (`source: "manual"`) pinned at a map-frame point; small box around it so the web viewer's
    /// Objects layer draws it too.
    public static func newLabel(id: String, name: String, category: ObjectCategory, notes: String, at p: SIMD3<Double>,
                                roomID: String?, haAreaID: String?, photoThumbBase64: String?, by: String, now: Double) -> SceneObject {
        var o = SceneObject(id: id, label: String(name.prefix(60)), category: category.rawValue,
                            centroid: [p.x, p.y, p.z].map(round4), source: "manual")
        o.name = String(name.prefix(80))
        o.isStatic = category.isStatic
        o.roomID = roomID
        o.haAreaID = haAreaID
        o.box = SceneObjectBox(center: o.centroid, size: [0.2, 0.2, 0.2], yaw: 0)
        o.confidence = 1
        o.firstSeen = .number(now); o.lastSeen = .number(now)
        o.observations = 1
        o.state = "present"
        var a: [String: ScanJSON] = ["labeled_by": .string(by)]
        if !notes.isEmpty { a["note"] = .string(String(notes.prefix(500))) }
        if let photoThumbBase64 { a["photo_jpeg_b64"] = .string(photoThumbBase64) }
        o.attributes = a
        return o
    }

    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

    static func record(_ o: inout SceneObject, _ c: ObjectCorrection) {
        var a = o.attributes ?? [:]
        var list = a["phone_corrections"]?.arrayValue ?? []
        list.append(c.json)
        a["phone_corrections"] = .array(Array(list.suffix(20)))
        o.attributes = a
    }

    /// Rename (owner name and / or class) / re-class / edit the note. `static` follows a category change. `name` ""
    /// clears the owner name; a phone label keeps label == name.
    public static func edit(_ objs: [SceneObject], id: String, name: String? = nil, label: String?, category: ObjectCategory?,
                            notes: String?, by: String, now: Double) -> [SceneObject] {
        objs.map { o in
            guard o.id == id else { return o }
            var n = o
            if let name {
                let t = name.trimmingCharacters(in: .whitespaces)
                n.name = t.isEmpty ? nil : String(t.prefix(80))
                if o.isManual, !t.isEmpty { n.label = String(t.prefix(60)) }
            }
            if let label, !label.isEmpty { n.label = String(label.prefix(60)) }
            if let category, category.rawValue != o.category { n.category = category.rawValue; n.isStatic = category.isStatic }
            if let notes {
                var a = n.attributes ?? [:]
                a["notes"] = nil
                a["note"] = notes.isEmpty ? nil : .string(String(notes.prefix(500)))
                n.attributes = a
            }
            if !o.isManual, n.label != o.label || n.category != o.category || n.name != o.name {
                record(&n, ObjectCorrection(op: "rename", ids: [id], label: n.label, category: n.category, by: by, at: now))
            }
            return n
        }
    }

    public static func delete(_ objs: [SceneObject], ids: Set<String>) -> [SceneObject] { objs.filter { !ids.contains($0.id) } }

    /// Merge `ids` into `into` (duplicates of one thing): the box grows to cover all (axis-aligned),
    /// centroid = observation-weighted mean, observations summed, sessions united, confidence = max,
    /// first/last seen = min/max. The others are removed. `into` keeps its id and label.
    public static func merge(_ objs: [SceneObject], ids: [String], into: String, by: String, now: Double) -> [SceneObject] {
        guard let ti = objs.firstIndex(where: { $0.id == into }) else { return objs }
        let others = Set(ids).subtracting([into])
        let group = objs.filter { $0.id == into || others.contains($0.id) }
        guard group.count >= 2 else { return objs }
        var t = objs[ti]
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var wsum = 0.0, csum = SIMD3<Double>.zero
        for o in group {
            let w = Double(max(1, o.observations ?? 1))
            if let p = o.mapPoint { csum += p * w; wsum += w }
            if let b = o.box, b.center.count == 3, b.size.count == 3 {
                let c = SIMD3(b.center[0], b.center[1], b.center[2]), s = SIMD3(b.size[0], b.size[1], b.size[2]) / 2
                // a yawed box's footprint fits in its circumscribed square
                let yaw = b.yaw ?? 0
                let r = abs(yaw) > 1e-6 ? SIMD3(hypot(s.x, s.y), hypot(s.x, s.y), s.z) : s
                lo = simd_min(lo, c - r); hi = simd_max(hi, c + r)
            } else if let p = o.mapPoint {
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        if wsum > 0 { t.centroid = Array([csum.x, csum.y, csum.z].map { round4($0 / wsum) }) }
        if lo.x.isFinite {
            let c = (lo + hi) / 2, s = simd_max(hi - lo, SIMD3(repeating: 0.05))
            // axis-aligned union (a yawed member contributes its circumscribed square)
            t.box = SceneObjectBox(center: [c.x, c.y, c.z].map(round4), size: [s.x, s.y, s.z].map(round4), yaw: 0)
        }
        t.observations = group.reduce(0) { $0 + max(1, $1.observations ?? 1) }
        t.confidence = group.compactMap(\.confidence).max() ?? t.confidence
        var sids: [String] = []
        for o in group { for s in o.sessionIDs ?? [] where !sids.contains(s) { sids.append(s) } }
        t.sessionIDs = sids.isEmpty ? t.sessionIDs : sids
        let firsts = group.compactMap { if case .number(let n)? = $0.firstSeen { return n } else { return nil } }
        let lasts = group.compactMap { if case .number(let n)? = $0.lastSeen { return n } else { return nil } }
        if let f = firsts.min() { t.firstSeen = .number(f) }
        if let l = lasts.max() { t.lastSeen = .number(l) }
        var a = t.attributes ?? [:]
        var mf = a["merged_from"]?.arrayValue ?? []
        for o in group where o.id != into { mf.append(.string(o.id)) }
        a["merged_from"] = .array(mf)
        t.attributes = a
        record(&t, ObjectCorrection(op: "merge", ids: group.map(\.id), into: into, by: by, at: now))
        var out: [SceneObject] = []
        for o in objs {
            if o.id == into { out.append(t) } else if !others.contains(o.id) { out.append(o) }
        }
        return out
    }

    /// Room of every object from the rooms doc (labels placed before a room was drawn get one later).
    public static func assignRooms(_ objs: [SceneObject], rooms: RoomsDoc) -> [SceneObject] {
        objs.map { o in
            guard o.roomID == nil, let p = o.mapPoint, let r = rooms.room(containing: p) else { return o }
            var n = o
            n.roomID = r.id
            if n.haAreaID == nil { n.haAreaID = r.haAreaID }
            return n
        }
    }

    /// "m-" + 8 hex characters, unique in the list.
    public static func newID(_ objs: [SceneObject], random: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) -> String {
        while true {
            let id = "m-" + String(format: "%08x", random())
            if !objs.contains(where: { $0.id == id }) { return id }
        }
    }
}

/// Label list: search + filter.
public enum LabelSearch {
    public enum Source: String, CaseIterable { case all = "All", manual = "Mine", detected = "Detected" }

    public static func filter(_ objs: [SceneObject], query: String, category: ObjectCategory?, source: Source,
                              rooms: [RoomRecord] = []) -> [SceneObject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let roomName = Dictionary(rooms.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { a, _ in a })
        return objs.filter { o in
            if let category, o.category != category.rawValue { return false }
            if source == .manual && !o.isManual { return false }
            if source == .detected && o.isManual { return false }
            guard !q.isEmpty else { return true }
            let hay = [o.label.lowercased(), (o.name ?? "").lowercased(), o.category, o.notes.lowercased(),
                       o.roomID.flatMap { roomName[$0] } ?? ""]
            return hay.contains { $0.contains(q) }
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: map labels (for the Scans view and, later, AR via the localization lane)

public struct MapLabel: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: String                   // room | object
    public var name: String
    public var category: String?
    public var position: [Double]             // map frame (Z-up metres)
    public var roomID: String?
    enum CodingKeys: String, CodingKey { case id, kind, name, category, position, roomID = "room_id" }
    public init(id: String, kind: String, name: String, category: String?, position: [Double], roomID: String?) {
        self.id = id; self.kind = kind; self.name = name; self.category = category; self.position = position; self.roomID = roomID
    }

    public var mapPoint: SIMD3<Double> { position.count == 3 ? SIMD3(position[0], position[1], position[2]) : .zero }
    /// Viewer frame (Y-up) position.
    public var yUp: SIMD3<Float> { ScanFrames.mapToYUp(SIMD3<Float>(Float(mapPoint.x), Float(mapPoint.y), Float(mapPoint.z))) }
}

public struct MapLabelSet: Codable, Equatable {
    public var scene: String
    public var frame: String                  // "map (Z-up, metres)"
    public var roomsRevision: Int
    public var objectsRevision: Int
    public var labels: [MapLabel]
    enum CodingKeys: String, CodingKey {
        case scene, frame, labels
        case roomsRevision = "rooms_revision", objectsRevision = "objects_revision"
    }
}

public enum MapLabels {
    /// Rooms (name at the polygon centroid, 1.2 m above its floor) + objects (pin point). Deleted / missing objects
    /// are left out.
    public static func build(scene: String, rooms: RoomsDoc, objects: ObjectsDoc, defaultFloorZ: Double?) -> MapLabelSet {
        var out: [MapLabel] = []
        for r in rooms.rooms {
            let c = Polygon2D.centroid(r.points)
            out.append(MapLabel(id: "room:" + r.id, kind: "room", name: r.name, category: nil,
                                position: [c.x, c.y, (r.floorZ ?? defaultFloorZ ?? 0) + 1.2], roomID: r.id))
        }
        for o in objects.objects where o.state != "missing" {
            guard let p = o.pinPoint else { continue }
            out.append(MapLabel(id: "object:" + o.id, kind: "object", name: o.displayName, category: o.category,
                                position: [p.x, p.y, p.z], roomID: o.roomID))
        }
        return MapLabelSet(scene: scene, frame: "map (Z-up, metres)", roomsRevision: rooms.revision,
                           objectsRevision: objects.revision, labels: out)
    }

    /// Labels in another frame: `T` = 4×4 from the map frame to that frame (e.g. ARKit world ← map, from the
    /// localization lane's T_ar_map; columns as simd).
    public static func transform(_ labels: [MapLabel], by T: simd_double4x4) -> [SIMD3<Double>] {
        labels.map { l in
            let p = T * SIMD4<Double>(l.mapPoint, 1)
            return SIMD3(p.x, p.y, p.z)
        }
    }

    /// Viewer-frame (Y-up float) hit point → map frame (Z-up double), as stored in labels and rooms.
    public static func mapPoint(fromYUp p: SIMD3<Float>) -> SIMD3<Double> {
        let m = ScanFrames.yUpToMap(p)
        return SIMD3(Double(m.x), Double(m.y), Double(m.z))
    }
}
