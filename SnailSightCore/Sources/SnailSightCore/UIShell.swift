import Foundation

// SnailSight 12.0 UI shell (owner-approved concepts C + A2 + B2 + O1/O2, 2026-10-18): the pure parts.
// - SheetDetent: the ONE pull-up sheet (collapsed: search + 4 quick actions; half: near you + places; full: everything).
// - NearItem / NearList: the sheet's "Near you" rows (bodies, robot / drone, cameras, places, other agents), nearest
//   first, each with ONE primary action, and the search filter.
// - MapLayerKey: the layers button's toggles.
// - CommandRing: the B2 ring of commands around a selected body (layout clamped to the screen).
// - PlanTransform / PlanLevels: the A2 Map's view transform and storey switcher (B / 1 / 2 / Yard).
// Pure, Linux-tested (UIShellTests).

// MARK: sheet

public enum SheetDetent: Int, CaseIterable, Equatable {
    case collapsed = 0, half, full

    /// Visible sheet height (points) for a container of height `h`.
    public func height(container h: Double) -> Double {
        switch self {
        case .collapsed: return 178               // search + quick actions + the home-indicator inset
        case .half: return min(max(h * 0.52, 360), h - 120)
        case .full: return max(h - 64, 400)
        }
    }

    /// Where a drag ends: the nearest detent to the released height, pushed one step by a fling (|v| > 600 pt/s,
    /// v > 0 = downward).
    public static func settle(height: Double, velocity v: Double, container h: Double) -> SheetDetent {
        let all = SheetDetent.allCases
        var best = all[0]
        var bd = Double.infinity
        for d in all {
            let dd = abs(d.height(container: h) - height)
            if dd < bd { bd = dd; best = d }
        }
        if v > 600, best.rawValue > 0, height < best.height(container: h) + 40 {
            return SheetDetent(rawValue: best.rawValue - 1) ?? best
        }
        if v < -600, best.rawValue < all.count - 1, height > best.height(container: h) - 40 {
            return SheetDetent(rawValue: best.rawValue + 1) ?? best
        }
        return best
    }
}

/// The collapsed sheet's four quick actions (concept C1).
public enum QuickAction: String, CaseIterable, Equatable {
    case spawn, roomScan, liveMap, record

    public var title: String {
        switch self {
        case .spawn: return "Spawn"
        case .roomScan: return "Room scan"
        case .liveMap: return "Live map"
        case .record: return "Record"
        }
    }

    public var symbol: String {
        switch self {
        case .spawn: return "plus.circle"
        case .roomScan: return "square.split.bottomrightquarter"
        case .liveMap: return "dot.radiowaves.left.and.right"
        case .record: return "record.circle"
        }
    }

    /// VoiceOver label for the current state.
    public func accessibility(on: Bool) -> String {
        switch self {
        case .spawn: return on ? "End spawn mode" : "Spawn an animal or object"
        case .roomScan: return on ? "Stop room scan" : "Start a room scan"
        case .liveMap: return on ? "Stop the live map" : "Start the live map: your walk builds the shared mesh"
        case .record: return on ? "Stop recording" : "Record the room"
        }
    }
}

// MARK: near you

public struct NearItem: Equatable, Identifiable {
    public enum Kind: String, Equatable { case animal, robot, drone, object, camera, place, agent, room }
    public enum Primary: String, Equatable { case follow, goTo, select, live, locate, show }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var position: [Double]?           // map frame (x, y, z)
    public var level: Int?
    public var distance: Double?
    public var primary: Primary

    public init(id: String, kind: Kind, title: String, subtitle: String = "", position: [Double]? = nil, level: Int? = nil,
                distance: Double? = nil, primary: Primary? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.position = position
        self.level = level; self.distance = distance; self.primary = primary ?? NearItem.defaultPrimary(kind)
    }

    /// One primary action per row (C2): animals Follow, robots / drones Go to, cameras Live, places Locate, others Show.
    public static func defaultPrimary(_ k: Kind) -> Primary {
        switch k {
        case .animal: return .follow
        case .robot, .drone: return .goTo
        case .camera: return .live
        case .place: return .locate
        case .object, .room: return .show
        case .agent: return .show
        }
    }

    public var primaryTitle: String {
        switch primary {
        case .follow: return "Follow"
        case .goTo: return "Go to"
        case .select: return "Select"
        case .live: return "Live"
        case .locate: return "Locate"
        case .show: return "Show"
        }
    }

    /// The round badge letter (C2 rows): first letter of the title.
    public var badge: String { title.first.map { String($0).uppercased() } ?? "?" }

    public var symbol: String {
        switch kind {
        case .animal: return "pawprint.fill"
        case .robot: return "car.side.fill"
        case .drone: return "airplane"
        case .object: return "cube.fill"
        case .camera: return "video.fill"
        case .place: return "mappin.circle.fill"
        case .agent: return "iphone.radiowaves.left.and.right"
        case .room: return "square.split.bottomrightquarter"
        }
    }
}

public enum NearList {
    /// Distances from `me` (map xy + half the height difference, as the AR labels rank), nearest first; items without a
    /// position go last, by title. `limit` caps the list.
    public static func build(_ items: [NearItem], me: [Double]?, limit: Int = 12) -> [NearItem] {
        var out = items.map { it -> NearItem in
            var x = it
            if let m = me, m.count >= 3, let p = it.position, p.count >= 2 {
                let dz = p.count > 2 ? abs(p[2] - m[2]) * 0.5 : 0
                x.distance = hypot(p[0] - m[0], p[1] - m[1]) + dz
            }
            return x
        }
        out.sort { a, b in
            switch (a.distance, b.distance) {
            case let (x?, y?): return x == y ? a.title < b.title : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        return Array(out.prefix(limit))
    }

    /// Search: every word must appear in the title, subtitle or kind (case / diacritic insensitive).
    public static func filter(_ items: [NearItem], query: String) -> [NearItem] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { it in
            let hay = (it.title + " " + it.subtitle + " " + it.kind.rawValue).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                                                  locale: nil)
            return words.allSatisfy { hay.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        }
    }

    /// "3.2 m" / "12 m" / "" (unknown).
    public static func distanceText(_ d: Double?) -> String {
        guard let d, d.isFinite else { return "" }
        return d < 10 ? String(format: "%.1f m", d) : String(format: "%.0f m", d)
    }
}

// MARK: layers

/// The layers button's toggles (B1's rail, as a compact sheet).
public enum MapLayerKey: String, CaseIterable, Equatable {
    case meshLive, structure, xray, objects, terrain, cameras, paths, agents

    public var title: String {
        switch self {
        case .meshLive: return "Mesh (live)"
        case .structure: return "Structure"
        case .xray: return "X-ray"
        case .objects: return "Objects"
        case .terrain: return "Terrain"
        case .cameras: return "Cameras"
        case .paths: return "Paths"
        case .agents: return "Other agents"
        }
    }

    public var symbol: String {
        switch self {
        case .meshLive: return "cube.transparent"
        case .structure: return "square.split.2x2"
        case .xray: return "eye.circle"
        case .objects: return "shippingbox"
        case .terrain: return "square.grid.3x3.topleft.filled"
        case .cameras: return "video"
        case .paths: return "point.topleft.down.to.point.bottomright.curvepath"
        case .agents: return "person.2.wave.2"
        }
    }

    public var detail: String {
        switch self {
        case .meshLive: return "The shared mesh as it is built, by you and every other agent; fresh tiles glow"
        case .structure: return "Clean walls / floors (off = the raw scan mesh)"
        case .xray: return "See sim bodies through walls"
        case .objects: return "Detected objects in the house map"
        case .terrain: return "Where the robot can drive (slope, steps)"
        case .cameras: return "Security cameras and sensors"
        case .paths: return "Planned routes of the selected body"
        case .agents: return "Other phones, robots and drones"
        }
    }
}

// MARK: command ring (B2)

public enum RingCommand: String, CaseIterable, Equatable {
    case goTo, follow, flee, stay, roam, delete

    public var title: String {
        switch self {
        case .goTo: return "Go to"
        case .follow: return "Follow"
        case .flee: return "Flee"
        case .stay: return "Stay"
        case .roam: return "Roam"
        case .delete: return "Delete"
        }
    }

    public var symbol: String {
        switch self {
        case .goTo: return "mappin.and.ellipse"
        case .follow: return "figure.walk"
        case .flee: return "hare"
        case .stay: return "hand.raised"
        case .roam: return "square.dashed"
        case .delete: return "trash"
        }
    }

    /// The bar command it runs (one command path for ring, bar and Map).
    public var simCommand: SimCommand {
        switch self {
        case .goTo: return .goTo
        case .follow: return .follow
        case .flee: return .flee
        case .stay: return .stay
        case .roam: return .roam
        case .delete: return .delete
        }
    }

    /// Ring commands for a body, in ring order (clockwise from the top), from the commands it actually offers.
    public static func ring(offered: [SimCommand]) -> [RingCommand] {
        var out: [RingCommand] = []
        for r in RingCommand.allCases {
            let c = r.simCommand
            if offered.contains(c) { out.append(r); continue }
            if r == .stay, offered.contains(.stop) { out.append(.stay) }        // robots: Stop = Stay
        }
        return out
    }

    /// The command to send for a ring choice: robots / drones have Stop where animals have Stay.
    public static func command(_ r: RingCommand, offered: [SimCommand]) -> SimCommand {
        if r == .stay, !offered.contains(.stay), offered.contains(.stop) { return .stop }
        return r.simCommand
    }
}

public enum CommandRing {
    public static let buttonSize = 52.0          // ≥ 44 pt touch targets
    public static let radius = 86.0

    /// Button centres around `center` (screen points), first at the top, clockwise; the whole ring is moved inside
    /// `bounds` (x0, y0, x1, y1) with a margin so no button is off screen or under the sheet.
    public static func layout(center c: V2, count n: Int, bounds b: [Double], radius r: Double = radius,
                              button: Double = buttonSize) -> (center: V2, points: [V2]) {
        guard n > 0, b.count == 4 else { return (c, []) }
        let m = r + button / 2 + 4
        var cc = c
        if b[2] - b[0] > 2 * m { cc.x = min(max(cc.x, b[0] + m), b[2] - m) } else { cc.x = (b[0] + b[2]) / 2 }
        if b[3] - b[1] > 2 * m { cc.y = min(max(cc.y, b[1] + m), b[3] - m) } else { cc.y = (b[1] + b[3]) / 2 }
        var pts: [V2] = []
        for i in 0..<n {
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            pts.append(V2(cc.x + r * cos(a), cc.y + r * sin(a)))
        }
        return (cc, pts)
    }
}

// MARK: map plan (A2)

/// Map xy (metres, z up) ↔ view points: `center` in the map, `ppm` points per metre, `size` of the view.
/// +x right, +y up on screen (north up).
public struct PlanTransform: Equatable {
    public var center: V2
    public var ppm: Double
    public var size: V2

    public init(center: V2, ppm: Double, size: V2) { self.center = center; self.ppm = ppm; self.size = size }

    public func toView(_ p: V2) -> V2 {
        V2(size.x / 2 + (p.x - center.x) * ppm, size.y / 2 - (p.y - center.y) * ppm)
    }

    public func toMap(_ v: V2) -> V2 {
        V2(center.x + (v.x - size.x / 2) / ppm, center.y - (v.y - size.y / 2) / ppm)
    }

    /// Fit `bounds` [x0, y0, x1, y1] into the view with a margin (points).
    public static func fit(_ b: [Double], size: V2, margin: Double = 24) -> PlanTransform {
        guard b.count == 4, b[2] > b[0], b[3] > b[1] else { return PlanTransform(center: .zero, ppm: 40, size: size) }
        let w = max(size.x - 2 * margin, 10), h = max(size.y - 2 * margin, 10)
        let ppm = min(w / (b[2] - b[0]), h / (b[3] - b[1]))
        return PlanTransform(center: V2((b[0] + b[2]) / 2, (b[1] + b[3]) / 2), ppm: clampPPM(ppm), size: size)
    }

    public static func clampPPM(_ v: Double) -> Double { min(max(v, 2), 400) }

    /// Pinch: keep the map point under `anchor` (view) fixed while zooming by `factor`.
    public func zoomed(by factor: Double, anchor: V2) -> PlanTransform {
        let before = toMap(anchor)
        var t = self
        t.ppm = PlanTransform.clampPPM(ppm * factor)
        let after = t.toMap(anchor)
        t.center = V2(t.center.x + before.x - after.x, t.center.y + before.y - after.y)
        return t
    }

    /// Drag by a view translation.
    public func panned(by d: V2) -> PlanTransform {
        var t = self
        t.center = V2(center.x - d.x / ppm, center.y + d.y / ppm)
        return t
    }

    /// The scale bar: a round length (1, 2, 5 × 10^k m) about 80 points long.
    public var scaleBarMetres: Double {
        let target = 80 / ppm
        let k = pow(10, floor(log10(target)))
        for m in [1.0, 2.0, 5.0, 10.0] where m * k >= target * 0.7 { return m * k }
        return 10 * k
    }
}

/// A storey for the Map's switcher (B / 1 / 2 / Yard).
public struct PlanLevel: Equatable, Identifiable {
    public var id: String
    public var level: Int?                   // nil = Yard (the outdoor terrain view)
    public var label: String
    public var title: String
    public var floorZ: Double?
}

public enum PlanLevels {
    /// From the storeys (index, floor z): with three or more storeys the lowest is the basement "B", the rest 1, 2, …;
    /// with fewer they are 1, 2. `yard` appends the outdoor "Yard" (terrain) entry.
    public static func make(_ levels: [(level: Int, floorZ: Double?)], yard: Bool) -> [PlanLevel] {
        let sorted = levels.sorted { ($0.floorZ ?? Double($0.level)) < ($1.floorZ ?? Double($1.level)) }
        let basement = sorted.count >= 3
        var out: [PlanLevel] = []
        for (i, l) in sorted.enumerated() {
            let label: String
            let title: String
            if basement && i == 0 { label = "B"; title = "Basement" }
            else {
                let n = basement ? i : i + 1
                label = "\(n)"
                title = n == 1 ? "Main floor" : n == 2 ? "Upstairs" : "Floor \(n)"
            }
            out.append(PlanLevel(id: "L\(l.level)", level: l.level, label: label, title: title, floorZ: l.floorZ))
        }
        if yard { out.append(PlanLevel(id: "yard", level: nil, label: "Yd", title: "Yard", floorZ: nil)) }
        return out
    }

    /// The storey a map z belongs to (the highest floor ≤ z + 0.5).
    public static func level(ofZ z: Double, in levels: [PlanLevel]) -> PlanLevel? {
        let floors = levels.filter { $0.level != nil && $0.floorZ != nil }.sorted { $0.floorZ! < $1.floorZ! }
        guard !floors.isEmpty else { return levels.first { $0.level != nil } }
        var best = floors[0]
        for l in floors where l.floorZ! <= z + 0.5 { best = l }
        return best
    }

    /// The entry storey (where the yard is): the storey right above the basement, else the lowest.
    public static func entry(_ levels: [PlanLevel]) -> PlanLevel? {
        let floors = levels.filter { $0.level != nil }
        if let one = floors.first(where: { $0.label == "1" }) { return one }
        return floors.first
    }
}

// MARK: camera / sensor placements (API §5.7a, GET …/entities?include=placements)

public struct Placement: Decodable, Equatable, Identifiable {
    public struct Pose: Decodable, Equatable { public var x: Double; public var y: Double; public var z: Double; public var yaw: Double? }
    public struct Record: Decodable, Equatable {
        public var source: String?
        public var level: Int?
        public var estimated: Bool?
        public var hfov: Double?
        public var far: Double?
        public var enabled: Bool?
    }
    public var id: String
    public var kind: String                      // camera | sensor
    public var name: String?
    public var pose: Pose
    public var record: Record?

    public var title: String { name ?? id }
    /// "Ring · estimated spot" / "Frigate".
    public var subtitle: String {
        let src = (record?.source ?? kind).split(separator: ":").first.map { String($0).capitalized } ?? kind.capitalized
        return record?.estimated == true ? "\(src) · estimated spot" : src
    }
}

public struct PlacementDoc: Decodable, Equatable {
    public var entities: [Placement]
    public static func parse(_ d: Data) -> [Placement] {
        ((try? JSONDecoder().decode(PlacementDoc.self, from: d))?.entities ?? []).filter { $0.kind == "camera" || $0.kind == "sensor" }
    }
}
