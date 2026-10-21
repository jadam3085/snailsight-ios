import Foundation

// SnailSight 12.5 tap tool (owner: "Don't let the cube be my default when I click on the screen. Maybe a measure point
// or something because I keep opening the app and making accidental cubes").
// - Every launch starts on Select / Inspect; the tool is never persisted (an explicit Cube pick lasts this run only).
// - Select / Inspect: a tap selects a body / object if hit, else drops a temporary measure point (distance from the
//   phone, height above the floor, level); a second point shows the point-to-point distance; points fade after 10 s.
// Pure, Linux-tested (TapToolTests).

public enum TapToolKind: String, CaseIterable, Equatable {
    case select, cube, measure, ruler, objects, robotPath
}

public struct TapToolState: Equatable {
    public static let launchDefault: TapToolKind = .select
    public private(set) var tool: TapToolKind
    public private(set) var explicitPick = false

    /// A fresh app start. `saved` is ignored on purpose: no tool survives a relaunch (accidental cubes).
    public init(saved: String? = nil) { tool = Self.launchDefault }

    /// The user picked a tool in the sheet / rail. Returns true when it changed.
    @discardableResult
    public mutating func pick(_ t: TapToolKind) -> Bool {
        guard t != tool else { return false }
        tool = t
        explicitPick = t != Self.launchDefault
        return true
    }

    /// Back to Select / Inspect (Escape from a tool, or a new launch).
    public mutating func reset() { tool = Self.launchDefault; explicitPick = false }

    /// A plain tap on a surface may place a cube only with the Cube tool explicitly picked.
    public var tapPlacesCube: Bool { tool == .cube && explicitPick }
    /// The value to persist: nothing.
    public var persisted: String? { nil }
}

/// One temporary measure point (map or world frame, metres, z/y up as given by `up`).
public struct MeasurePoint: Equatable {
    public var position: [Double]
    public var placedAt: Double
    public var distanceFromPhone: Double
    public var heightAboveFloor: Double?
    public var level: String?
    public init(position: [Double], placedAt: Double, distanceFromPhone: Double, heightAboveFloor: Double?, level: String?) {
        self.position = position; self.placedAt = placedAt; self.distanceFromPhone = distanceFromPhone
        self.heightAboveFloor = heightAboveFloor; self.level = level
    }
}

/// Up to two live points; a third tap starts a new pair. Points fade `life` s after the newest tap.
public struct MeasurePoints: Equatable {
    public static let life = 10.0
    public static let fade = 1.5            // last part of the life: drawn fading
    public private(set) var points: [MeasurePoint] = []
    public init() {}

    public static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<min(3, min(a.count, b.count)) { s += (a[i] - b[i]) * (a[i] - b[i]) }
        return s.squareRoot()
    }

    /// Add a point. `phone`: phone position, `floor`: the floor height under the point (same frame, `upAxis` = the
    /// vertical component index: 2 for the map frame, 1 for ARKit world), `level`: storey label.
    @discardableResult
    public mutating func tap(at p: [Double], phone: [Double], floor: Double?, level: String?, upAxis: Int = 2,
                             now: Double) -> MeasurePoint {
        expire(now: now)
        if points.count >= 2 { points = [] }
        let h = floor.flatMap { f in p.count > upAxis ? max(0, p[upAxis] - f) : nil }
        let m = MeasurePoint(position: p, placedAt: now, distanceFromPhone: Self.distance(p, phone),
                             heightAboveFloor: h, level: level)
        points.append(m)
        return m
    }

    /// Drop everything older than `life` since the NEWEST tap (a pair fades together).
    public mutating func expire(now: Double) {
        guard let last = points.last?.placedAt else { return }
        if now - last >= Self.life { points = [] }
    }

    /// 1 = fully visible, falling to 0 over the last `fade` s.
    public func opacity(now: Double) -> Double {
        guard let last = points.last?.placedAt else { return 0 }
        let left = Self.life - (now - last)
        if left <= 0 { return 0 }
        return min(1, left / Self.fade)
    }

    public var pairDistance: Double? {
        points.count == 2 ? Self.distance(points[0].position, points[1].position) : nil
    }

    /// "1.82 m away · 0.74 m above floor · Main floor" / "A→B 2.31 m".
    public var readout: String? {
        if let d = pairDistance { return "A→B " + Self.metres(d) }
        guard let p = points.last else { return nil }
        var parts = [Self.metres(p.distanceFromPhone) + " away"]
        if let h = p.heightAboveFloor { parts.append(Self.metres(h) + " above floor") }
        if let l = p.level { parts.append(l) }
        return parts.joined(separator: " · ")
    }

    public static func metres(_ m: Double) -> String {
        m < 1 ? String(format: "%.0f cm", m * 100) : String(format: "%.2f m", m)
    }
}
