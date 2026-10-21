import Foundation

// 12.6 Articulated doors (API §8.12, live door events §6b.4). A door is a map entity with a fixed frame and ONE moving
// part: the leaf, hinged at the jamb. The app draws each leaf as a thin box (leaf_width x height x 0.04) pivoting on the
// hinge at its latest measured angle (AR, Map, Map 3D). Pure, Linux-tested (DoorsTests).
//
// Hinge transform from the GET /v1/maps/{map}/doors fields:
// - hinge.point = the hinge axis on the floor; closed leaf direction u = hinge -> latch = frame.t when hinge.jamb == "lo",
//   -frame.t when "hi" (the other jamb is at the far end of the doorway);
// - swing.direction = where the leaf points when open 90 degrees, so the rotation sign is sign(u x swing.direction);
// - leaf angle = angle_deg (0 = closed), state unknown -> closed;
// - hinge unknown (hinge null) or swing unknown: closed, centred in the doorway (frame.center, along frame.t,
//   width frame.width_m).

public struct DoorState: Codable, Equatable {
    public var state: String
    public var angleDeg: Double?
    public var t: Double?
    public var source: String?
    enum CodingKeys: String, CodingKey { case state, t, source, angleDeg = "angle_deg" }
}

public struct DoorInfo: Codable, Equatable {
    public struct Frame: Codable, Equatable {
        public var center: [Double]
        public var t: [Double]
        public var widthM: Double
        public var heightM: Double
        public var z0: Double
        public var thicknessM: Double?
        enum CodingKeys: String, CodingKey {
            case center, t, z0, widthM = "width_m", heightM = "height_m", thicknessM = "thickness_m"
        }
    }
    public struct Hinge: Codable, Equatable {
        public var jamb: String?
        public var point: [Double]
        public var side: String?
    }
    public struct Swing: Codable, Equatable {
        public var direction: [Double]
        public var into: String?
    }
    public var id: String
    public var status: String?
    public var level: Int?
    public var frame: Frame
    public var hinge: Hinge?
    public var swing: Swing?
    public var leafWidthM: Double?
    public var maxAngleDeg: Double?
    public var state: DoorState?
    enum CodingKeys: String, CodingKey {
        case id, status, level, frame, hinge, swing, state
        case leafWidthM = "leaf_width_m", maxAngleDeg = "max_angle_deg"
    }
}

public struct DoorsDoc: Decodable, Equatable {
    public var mapID: String?
    public var version: Int?
    public var rev: Int?
    public var doors: [DoorInfo]
    enum CodingKeys: String, CodingKey { case version, rev, doors, mapID = "map_id" }

    public static func parse(_ d: Data) -> DoorsDoc? { try? JSONDecoder().decode(DoorsDoc.self, from: d) }
}

/// §6b.4 live door event on the changes layer: {"type":"door", door_id, state, angle_deg, prev_state, t, source:"live", ...}.
public struct DoorEvent: Equatable {
    public var doorID: String
    public var state: String
    public var angleDeg: Double?
    public var t: Double?

    public static func parse(_ d: Data) -> DoorEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (o["type"] as? String) == "door", let id = o["door_id"] as? String, let st = o["state"] as? String
        else { return nil }
        return DoorEvent(doorID: id, state: st, angleDeg: (o["angle_deg"] as? NSNumber)?.doubleValue,
                         t: (o["t"] as? NSNumber)?.doubleValue)
    }
}

/// One drawable leaf in the map frame (Z-up metres).
public struct DoorLeaf: Equatable {
    public static let thickness = 0.04

    public var id: String
    public var level: Int
    /// The pivot: the hinge axis (floor point) or, with no hinge, the closed leaf's centre.
    public var pivot: [Double]
    /// Leaf direction (pivot -> free edge), radians about +z, already rotated by the angle.
    public var yaw: Double
    public var width: Double
    public var height: Double
    public var z0: Double
    public var state: String
    public var angleDeg: Double
    public var hinged: Bool
    /// True when the pivot is the leaf's centre (unknown hinge): the box is centred on it.
    public var centred: Bool

    public var label: String {
        switch state {
        case "closed": return "closed"
        case "ajar": return "ajar \(Int(angleDeg.rounded()))°"
        case "open": return "open \(Int(angleDeg.rounded()))°"
        default: return "closed"
        }
    }

    /// RGBA 0...1 by state: closed = steel blue, ajar = amber, open = green.
    public var colour: [Double] {
        switch state {
        case "open": return [0.30, 0.85, 0.45, 1]
        case "ajar": return [1.0, 0.72, 0.2, 1]
        default: return [0.35, 0.65, 1.0, 1]
        }
    }

    /// Centre of the box (map frame): pivot + dir * width/2 for a hinged leaf, the pivot when centred. z = mid height.
    public var boxCenter: [Double] {
        let c = centred ? 0 : width / 2
        return [pivot[0] + cos(yaw) * c, pivot[1] + sin(yaw) * c, z0 + height / 2]
    }

    /// The free edge (latch end) on the floor, for plans.
    public var tip: [Double] { [pivot[0] + cos(yaw) * (centred ? width / 2 : width), pivot[1] + sin(yaw) * (centred ? width / 2 : width)] }

    /// The other end of the leaf on the floor: the hinge, or the centred leaf's far end.
    public var tail: [Double] { centred ? [pivot[0] - cos(yaw) * width / 2, pivot[1] - sin(yaw) * width / 2] : [pivot[0], pivot[1]] }

    public static func make(_ d: DoorInfo, state override: DoorState? = nil) -> DoorLeaf? {
        guard d.status == nil || d.status == "door", d.frame.center.count >= 2, d.frame.t.count >= 2 else { return nil }
        let st = override ?? d.state
        let name = st?.state ?? "unknown"
        let tn = max(1e-9, hypot(d.frame.t[0], d.frame.t[1]))
        let tx = d.frame.t[0] / tn, ty = d.frame.t[1] / tn
        let h = d.frame.heightM > 0.3 ? d.frame.heightM : 2.0
        let z0 = d.frame.z0
        // hinge unknown: closed in the doorway, centred
        func closedCentred() -> DoorLeaf {
            DoorLeaf(id: d.id, level: d.level ?? 0, pivot: [d.frame.center[0], d.frame.center[1]], yaw: atan2(ty, tx),
                     width: d.frame.widthM, height: h, z0: z0, state: "closed", angleDeg: 0, hinged: false, centred: true)
        }
        guard let hg = d.hinge, hg.point.count >= 2 else { return closedCentred() }
        let sgn = (hg.jamb == "hi") ? -1.0 : 1.0
        let ux = tx * sgn, uy = ty * sgn
        let w = (d.leafWidthM ?? 0) > 0.2 ? d.leafWidthM! : d.frame.widthM
        var s = 0.0
        if let sw = d.swing, sw.direction.count >= 2 {
            let cross = ux * sw.direction[1] - uy * sw.direction[0]
            s = cross > 1e-6 ? 1 : (cross < -1e-6 ? -1 : 0)
        }
        // swing unknown: the leaf cannot be turned the right way, so it stays closed in the doorway
        var a = 0.0
        if s != 0, name != "unknown" { a = max(0, min(st?.angleDeg ?? 0, max(d.maxAngleDeg ?? 125, 125))) }
        let yaw = atan2(uy, ux) + s * a * .pi / 180
        let shown = (name == "unknown") ? "closed" : name
        return DoorLeaf(id: d.id, level: d.level ?? 0, pivot: [hg.point[0], hg.point[1]], yaw: yaw, width: w, height: h, z0: z0,
                        state: shown, angleDeg: a, hinged: true, centred: false)
    }
}

/// The latest state per door; live events replace the state (a door the doc does not know is ignored).
public struct DoorSet: Equatable {
    public private(set) var doors: [DoorInfo] = []
    public private(set) var rev: Int = 0
    public init() {}

    public mutating func load(_ doc: DoorsDoc) {
        doors = doc.doors.filter { $0.status == nil || $0.status == "door" }
        rev += 1
    }

    /// Returns true when a known door changed.
    @discardableResult
    public mutating func apply(_ e: DoorEvent) -> Bool {
        guard let i = doors.firstIndex(where: { $0.id == e.doorID }) else { return false }
        let new = DoorState(state: e.state, angleDeg: e.angleDeg, t: e.t, source: "live")
        if doors[i].state?.state == new.state, doors[i].state?.angleDeg == new.angleDeg { return false }
        doors[i].state = new
        rev += 1
        return true
    }

    public var leaves: [DoorLeaf] { doors.compactMap { DoorLeaf.make($0) } }
}
