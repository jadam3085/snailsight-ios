import Foundation

// SnailSight 9.8: object sleeping / activity cap (thermal budget) and the user's grab-and-throw.

/// Per-object activity bookkeeping. An object resting (speed below `restSpeed`) for `restTime` sleeps: the app turns
/// its rigid body static, so the physics engine and our contact checks skip it. Anything that could move it wakes it:
/// a push, a poke / grab, the mesh changing under it, or a moving neighbour coming close.
public struct SleepPolicy: Equatable {
    public var restSpeed = 0.03          // m/s
    public var restTime = 1.0            // s
    public var maxActive: Int            // awake dynamic bodies at most (the rest are put to sleep, slowest first)
    /// Only bodies slower than this may be forced to sleep by the cap (never freeze a flying ball mid-air).
    public var capSpeed = 0.25
    public init(maxActive: Int) { self.maxActive = maxActive }
}

public struct BodyActivity: Equatable {
    public var id: Int
    public var speed: Double
    public var restFor: Double
    public var asleep: Bool
    public var held: Bool
    public init(id: Int, speed: Double, restFor: Double = 0, asleep: Bool = false, held: Bool = false) {
        self.id = id; self.speed = speed; self.restFor = restFor; self.asleep = asleep; self.held = held
    }
}

public enum SimSleep {
    /// Advance rest timers by `dt` and return the ids to put to sleep now.
    public static func update(_ bodies: inout [BodyActivity], dt: Double, policy p: SleepPolicy) -> [Int] {
        var sleep: [Int] = []
        for i in bodies.indices where !bodies[i].asleep {
            if bodies[i].held || bodies[i].speed >= p.restSpeed { bodies[i].restFor = 0; continue }
            bodies[i].restFor += dt
            if bodies[i].restFor >= p.restTime { sleep.append(bodies[i].id) }
        }
        var awake = bodies.filter { !$0.asleep && !$0.held && !sleep.contains($0.id) }
        if awake.count > p.maxActive {
            awake = awake.filter { $0.speed < p.capSpeed }.sorted { ($0.speed, -$0.restFor) < ($1.speed, -$1.restFor) }
            let extra = bodies.filter { !$0.asleep && !sleep.contains($0.id) }.count - p.maxActive
            sleep += awake.prefix(max(0, extra)).map { $0.id }
        }
        for i in bodies.indices where sleep.contains(bodies[i].id) { bodies[i].asleep = true; bodies[i].restFor = 0 }
        return sleep
    }

    /// Sleeping bodies a moving one is about to touch (footprint circles closer than `margin`).
    public static func neighboursToWake(moving: [(pos: SIMD3<Double>, radius: Double)],
                                        sleeping: [(id: Int, pos: SIMD3<Double>, radius: Double)],
                                        margin: Double = 0.05) -> [Int] {
        sleeping.filter { s in
            moving.contains { m in
                let d = m.pos - s.pos
                return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() < m.radius + s.radius + margin
            }
        }.map { $0.id }
    }
}

/// Grab, flick and throw: the object follows the finger; on release it gets the finger's recent velocity.
public struct ThrowTracker: Equatable {
    public static let window = 0.12                  // s of samples used for the release velocity
    public static let maxSpeed = 6.0                 // m/s
    public static let lift = 0.6                     // m/s added upward on a real throw so it arcs
    public static let flickSpeed = 0.6               // below this a release is a drop, not a throw
    private var samples: [(t: Double, p: SIMD3<Double>)] = []

    public init() {}

    public mutating func add(_ p: SIMD3<Double>, at t: Double) {
        samples.append((t, p))
        samples.removeAll { t - $0.t > Self.window * 2 }
    }

    /// 9.9 raw finger velocity over the window (no flick threshold, no lift): a held object hitting an animal.
    public func velocity(at t: Double) -> SIMD3<Double> {
        let recent = samples.filter { t - $0.t <= Self.window }
        guard let a = recent.first, let b = recent.last, b.t - a.t > 1e-3 else { return .zero }
        return (b.p - a.p) / (b.t - a.t)
    }

    /// World velocity to give the object on release (zero for a still release).
    public func releaseVelocity(at t: Double) -> SIMD3<Double> {
        let recent = samples.filter { t - $0.t <= Self.window }
        guard let a = recent.first, let b = recent.last, b.t - a.t > 1e-3 else { return .zero }
        var v = (b.p - a.p) / (b.t - a.t)
        let horiz = (v.x * v.x + v.z * v.z).squareRoot()
        let sp = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        if sp < Self.flickSpeed { return .zero }
        if sp > Self.maxSpeed { v *= Self.maxSpeed / sp }
        if horiz > Self.flickSpeed { v.y += Self.lift }
        return v
    }

    public static func == (a: ThrowTracker, b: ThrowTracker) -> Bool { a.samples.count == b.samples.count }
}

/// A tap on an object: a short shove away from the camera along the ground (and a small hop) with a velocity
/// change that does not depend on mass (a cup and a crate both visibly react).
public enum Poke {
    public static let speed = 1.2                    // m/s along the ground
    public static let hop = 0.8                      // m/s up
    public static func velocityChange(cameraToObject d: SIMD3<Double>) -> SIMD3<Double> {
        let h = (d.x * d.x + d.z * d.z).squareRoot()
        guard h > 1e-6 else { return SIMD3(0, hop, 0) }
        return SIMD3(d.x / h * speed, hop, d.z / h * speed)
    }
}
