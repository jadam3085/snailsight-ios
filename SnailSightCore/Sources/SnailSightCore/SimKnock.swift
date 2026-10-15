import Foundation

// SnailSight 9.9 (owner on 9.8.91: "I don't see good collision detection for things like if an animal is kicked";
// "spawn or move or toss an animal on top of things like a shelf or table, not just a floor").
//
// Animals are RealityKit bodies now: KINEMATIC while their brain drives them (collision shape = AnimalShape), and a
// DYNAMIC rigid body for a moment when something hits them hard enough (Impact): a thrown / rolled object, the robot
// driving into them, another knocked animal, your drag-and-fling or a kick (Kick = a quick flick on the animal). The
// knock state machine (Knock) then waits for the body to come to rest (or a time-out), stands it back up (recovering)
// and hands it back to its brain where it landed — the floor, or a table it was knocked onto.
// Surfaces: SurfaceClass sorts a LiDAR mesh hit by its normal (floor / elevated / wall / ceiling / steep), ElevatedNav
// decides what an animal may step onto or hop down from, RobotSurface whether RobosnailBob may stand on a table.
// Pure maths, tested on CI. World frame = ARKit (y up); ground frame (x, y) = (x, −z).

// MARK: collision shape

public enum AnimalShape: Equatable {
    /// Upright capsule (total height, radius), feet at y = 0.
    case capsule(radius: Double, height: Double)
    /// Box (length along heading, height, width), feet at y = 0.
    case box(SIMD3<Double>)

    /// Compact, upright bodies (rabbit, cat, chicken) get a capsule (they roll and tumble naturally); long or flat
    /// ones (deer, dog, frog, penguin lying wide) a box slightly inside the drawn size (legs and ears are thin).
    /// `size` = (length, height, width) at the body's current scale.
    public static func choose(size s: SIMD3<Double>) -> AnimalShape {
        let l = max(0.01, s.x), h = max(0.01, s.y), w = max(0.01, s.z)
        let footprint = max(l, w)
        if l / w <= 1.5, h >= 0.8 * footprint {
            let r = 0.45 * footprint
            return .capsule(radius: r, height: max(h, 2 * r))
        }
        return .box(SIMD3(l * 0.9, h * 0.9, w))
    }

    /// Height of the shape's centre above the feet.
    public var centreHeight: Double {
        switch self {
        case .capsule(_, let h): return h / 2
        case .box(let s): return s.y / 2
        }
    }
}

// MARK: impacts

public enum HitSource: String, Equatable, CaseIterable { case object, robot, animal, kick, fling }

public enum Impact {
    public static let restitution = 0.3
    /// Below this velocity change the animal is only startled (it bolts), not knocked over.
    public static let minKnock = 0.2
    /// From this velocity change on it tumbles (rotation free); below it slides upright.
    public static let tumbleAt = 1.0
    public static let maxDV = 5.0

    /// Velocity change of an animal (mass `animalMass`) hit by a body of mass `hitterMass` closing at `closingSpeed`
    /// along `normal` (unit, hitter → animal): 1-D collision with restitution, the animal at rest along the normal.
    public static func deltaV(hitterMass m1: Double, animalMass m2: Double, closingSpeed: Double,
                              normal n: SIMD3<Double>) -> SIMD3<Double> {
        guard closingSpeed > 0, m1 > 0, m2 > 0 else { return .zero }
        let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        guard len > 1e-9 else { return .zero }
        let mag = min(maxDV, (1 + restitution) * m1 / (m1 + m2) * closingSpeed)
        return n / len * mag
    }

    /// Impulse (N·s) that changes `massKg` by `dv`.
    public static func impulse(massKg: Double, dv: SIMD3<Double>) -> Double {
        massKg * (dv.x * dv.x + dv.y * dv.y + dv.z * dv.z).squareRoot()
    }

    public static func shouldKnock(_ dv: SIMD3<Double>) -> Bool { length(dv) >= minKnock }
    public static func tumbles(_ dv: SIMD3<Double>) -> Bool { length(dv) >= tumbleAt }

    /// A sideways hit also lifts a little (a knocked animal hops, so it can go over a table edge rather than stick).
    public static func withLift(_ dv: SIMD3<Double>, factor: Double = 0.25) -> SIMD3<Double> {
        let h = (dv.x * dv.x + dv.z * dv.z).squareRoot()
        return SIMD3(dv.x, max(dv.y, h * factor), dv.z)
    }

    /// Tumble spin (rad/s, world): about the horizontal axis perpendicular to the hit (it rolls over away from it),
    /// faster for small bodies, capped.
    public static func spin(_ dv: SIMD3<Double>, height: Double, cap: Double = 12) -> SIMD3<Double> {
        let h = SIMD3(dv.x, 0, dv.z)
        let hl = (h.x * h.x + h.z * h.z).squareRoot()
        guard hl > 1e-6 else { return .zero }
        // axis = up × dir  (rolling forward along dir)
        let d = h / hl
        let axis = SIMD3(d.z, 0, -d.x)
        let rate = min(cap, hl / max(0.05, height / 2))
        return axis * rate
    }

    static func length(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
}

/// A kick: a quick flick that starts on an animal. Screen velocity (points/s, x right, y down) → a world velocity
/// along the ground in the flick direction (screen up = away from you) with a little lift.
public enum Kick {
    public static let maxDuration = 0.35         // s from touch to release
    public static let minScreenSpeed = 700.0     // pt/s
    public static let minSpeed = 1.0, maxSpeed = 5.0   // m/s
    public static let lift = 0.35                // × speed, upward

    /// nil = not a kick (too slow or a long drag).
    public static func velocity(screenVelocity sv: SIMD2<Double>, duration: Double,
                                cameraForward fwd: SIMD3<Double>) -> SIMD3<Double>? {
        let sp = (sv.x * sv.x + sv.y * sv.y).squareRoot()
        guard duration <= maxDuration, sp >= minScreenSpeed else { return nil }
        var f = SIMD3(fwd.x, 0, fwd.z)
        let fl = (f.x * f.x + f.z * f.z).squareRoot()
        f = fl > 1e-6 ? f / fl : SIMD3(0, 0, -1)
        let r = SIMD3(-f.z, 0, f.x)                       // camera right on the ground
        var d = r * sv.x + f * (-sv.y)
        let dl = (d.x * d.x + d.z * d.z).squareRoot()
        guard dl > 1e-9 else { return nil }
        d /= dl
        let speed = min(maxSpeed, max(minSpeed, sp / 1000 * 2.2))
        return d * speed + SIMD3(0, lift * speed, 0)
    }
}

// MARK: knock state machine

public enum KnockPhase: String, Equatable { case none, airborne, recovering }

public enum KnockEvent: Equatable {
    case none
    case began
    case settled(timedOut: Bool)
    case recovered
}

public struct KnockParams: Equatable {
    public var settleSpeed = 0.12        // m/s
    public var settleSpin = 0.8          // rad/s
    public var settleTime = 0.35         // s slow before it counts as at rest
    public var minAirTime = 0.25         // s (it has to leave the ground first)
    public var maxAirTime = 5.0          // s, then it recovers wherever it is
    public var recoverTime = 0.6         // s standing back up
    public init() {}
}

public struct KnockState: Equatable {
    public var phase: KnockPhase = .none
    public var t = 0.0
    public var still = 0.0
    public var tumbled = false
    public var startY = 0.0
    public var source: HitSource = .object
    public var hits = 0                  // hits in this knock (a re-hit in the air restarts the timers)
    public init() {}
    public var active: Bool { phase != .none }
}

public enum Knock {
    /// Start (or restart, when hit again in the air or while standing up) a knock.
    @discardableResult
    public static func begin(_ s: inout KnockState, source: HitSource, y: Double, tumble: Bool) -> KnockEvent {
        if s.phase != .airborne { s.startY = y; s.hits = 0; s.tumbled = false }
        s.phase = .airborne
        s.t = 0
        s.still = 0
        s.source = source
        s.hits += 1
        s.tumbled = s.tumbled || tumble
        return .began
    }

    /// One frame. `speed` / `spin` = the rigid body's linear / angular speed.
    @discardableResult
    public static func step(_ s: inout KnockState, dt: Double, speed: Double, spin: Double,
                            params p: KnockParams = KnockParams()) -> KnockEvent {
        guard dt > 0 else { return .none }
        switch s.phase {
        case .none: return .none
        case .airborne:
            s.t += dt
            if s.t >= p.minAirTime && speed < p.settleSpeed && spin < p.settleSpin { s.still += dt } else { s.still = 0 }
            if s.still >= p.settleTime { s.phase = .recovering; s.t = 0; return .settled(timedOut: false) }
            if s.t >= p.maxAirTime { s.phase = .recovering; s.t = 0; return .settled(timedOut: true) }
            return .none
        case .recovering:
            s.t += dt
            if s.t >= p.recoverTime { s.phase = .none; s.t = 0; s.still = 0; return .recovered }
            return .none
        }
    }

    /// 0 → 1 (smoothstep) while standing back up.
    public static func recoverFraction(_ s: KnockState, params p: KnockParams = KnockParams()) -> Double {
        guard s.phase == .recovering, p.recoverTime > 0 else { return s.phase == .none ? 1 : 0 }
        let x = min(1, max(0, s.t / p.recoverTime))
        return x * x * (3 - 2 * x)
    }

    /// Heading (ground frame) the animal faces after standing up: its body's forward projected on the ground, else
    /// the one it had.
    public static func uprightHeading(forward f: SIMD3<Double>, fallback: Double) -> Double {
        let g = V2(f.x, -f.z)
        return SimMath.length(g) > 0.2 ? SimMath.heading(g) : fallback
    }
}

// MARK: surfaces

public enum SurfaceKind: String, Equatable { case floor, elevated, wall, ceiling, steep }

public enum SurfaceClass {
    /// Up to 25° from level counts as a surface to stand on (LiDAR normals on a table top wobble by a few degrees).
    public static let standCos = cos(25 * Double.pi / 180)
    /// A standable surface this much above the floor is "elevated" (table, shelf, bed, sofa seat, counter).
    public static let minElevation = 0.12

    public static func classify(normal n0: SIMD3<Double>, height y: Double, floorY: Double?) -> SurfaceKind {
        let l = (n0.x * n0.x + n0.y * n0.y + n0.z * n0.z).squareRoot()
        guard l > 1e-9 else { return .steep }
        let ny = n0.y / l
        if ny >= standCos {
            if let f = floorY, y - f > minElevation { return .elevated }
            return .floor
        }
        if ny <= -standCos { return .ceiling }
        if abs(ny) < 0.35 { return .wall }
        return .steep
    }

    public static func standable(_ k: SurfaceKind) -> Bool { k == .floor || k == .elevated }
}

/// The room's floor height from standable hits: the lowest surface seen 0.5–2.2 m below the camera (where a floor is
/// for a phone held by a standing or sitting person), lightly smoothed.
public struct FloorEstimate: Equatable {
    public private(set) var y: Double?
    public init(y: Double? = nil) { self.y = y }

    public mutating func note(surfaceY s: Double, cameraY c: Double) {
        let below = c - s
        guard below >= 0.5, below <= 2.2 else { return }
        guard let cur = y else { y = s; return }
        if s < cur - 0.03 { y = s }                          // a lower floor: that one (the first may have been a table)
        else if abs(s - cur) <= 0.05 { y = cur * 0.9 + s * 0.1 }
    }
}

public enum EdgeStep: String, Equatable { case ok, wall, edge, hop }

/// What an animal may walk onto: steps up to `maxStep`, drops up to `maxDrop`; a deeper drop is a table / shelf
/// EDGE it does not walk off — unless it is fleeing or knocked and the drop is within its hop-down height.
public enum ElevatedNav {
    /// How far an animal of drawn height `h` (m, at its scale) will hop down: 2.5 body heights, at least its normal
    /// drop limit, at most 1.2 m (a cat off a table yes, a scaled-down rabbit off a counter no).
    public static func hopDown(height h: Double, scale s: Double) -> Double {
        max(AnimalReach.maxDrop(scale: s), min(1.2, 2.5 * h))
    }

    public static func classify(currentFloor: Double, newFloor: Double?, maxStep: Double, maxDrop: Double,
                                hopDown: Double, mayHop: Bool) -> EdgeStep {
        guard let f = newFloor else { return .edge }
        let rise = f - currentFloor
        if rise > maxStep { return .wall }
        let drop = -rise
        if drop > maxDrop { return mayHop && drop <= hopDown ? .hop : .edge }
        return .ok
    }

    public static func passable(_ e: EdgeStep) -> Bool { e == .ok || e == .hop }
}

/// RobosnailBob on furniture: only on a surface big enough for its footprint (a NavGrid built at the surface height
/// with the robot's radius: the spot must not be hard) and only while it is light enough to be plausible on a table.
public enum RobotSurface {
    public static let maxElevatedMassKg = 15.0

    public enum Verdict: String, Equatable { case ok, tooSmall, tooHeavy, notStandable }

    public static func check(kind: SurfaceKind, robotMassKg: Double, fits: Bool) -> Verdict {
        switch kind {
        case .floor: return .ok
        case .elevated:
            if robotMassKg > maxElevatedMassKg { return .tooHeavy }
            return fits ? .ok : .tooSmall
        default: return .notStandable
        }
    }

    /// The robot's centre may stand at `p` on `grid` (built with refFloor = the surface, inflate = robot radius).
    public static func fits(_ grid: NavGrid, at p: V2) -> Bool {
        guard let (i, j) = grid.spec.index(p) else { return false }
        return grid.at(i, j) != .hard && grid.floorAt(i, j) != nil
    }

    public static func hint(_ v: Verdict, robotMassKg: Double) -> String? {
        switch v {
        case .ok: return nil
        case .tooSmall: return "Too small for RobosnailBob: aim at a bigger flat area (or the floor)"
        case .tooHeavy:
            return String(format: "RobosnailBob is %.0f kg at this scale: tables hold it only at ≤ %.0f kg (Sim scale ≤ 60 %%)",
                          robotMassKg, maxElevatedMassKg)
        case .notStandable: return "That's not a surface to stand on: aim at the floor or a table top"
        }
    }
}
