import Foundation

// SnailSight S1 "simulated agents in AR" (docs/SNAILSIGHT-REFACTOR-PLAN.md §7 S). Pure maths shared by the robot and
// the animals. Frame: the 2D GROUND frame, z up, metres — x = ARKit x, y = −ARKit z, heading θ counter-clockwise from
// +x in radians. That is the session `odom` frame of services/snailsight/frames.py, so S2 (server sim in the shared
// map frame) reuses this logic unchanged.

public typealias V2 = SIMD2<Double>

public enum SimMath {
    /// Angle wrapped to (−π, π].
    public static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x <= -.pi { x += 2 * .pi }
        if x > .pi { x -= 2 * .pi }
        return x
    }

    public static func unit(_ theta: Double) -> V2 { V2(cos(theta), sin(theta)) }

    public static func heading(_ v: V2) -> Double { atan2(v.y, v.x) }

    public static func length(_ v: V2) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

    public static func dot(_ a: V2, _ b: V2) -> Double { a.x * b.x + a.y * b.y }

    /// Move `cur` toward `target` by at most `maxDelta`.
    public static func approach(_ cur: Double, _ target: Double, _ maxDelta: Double) -> Double {
        let d = target - cur
        if abs(d) <= maxDelta { return target }
        return cur + (d > 0 ? maxDelta : -maxDelta)
    }

    /// Turn heading `cur` toward `target` by at most `maxStep` radians (shortest way round).
    public static func turnToward(_ cur: Double, _ target: Double, maxStep: Double) -> Double {
        let d = wrap(target - cur)
        if abs(d) <= maxStep { return wrap(target) }
        return wrap(cur + (d > 0 ? maxStep : -maxStep))
    }

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

/// Deterministic RNG (SplitMix64) so behaviour tests are reproducible per seed; each animal gets its own stream so a
/// herd desyncs (the wargame engine's per-entity rng substream idea, services/wargame/entities.py).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    public mutating func uniform(_ r: ClosedRange<Double>) -> Double { uniform(r.lowerBound, r.upperBound) }
    /// Standard normal (Box–Muller).
    public mutating func normal() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// "Can an agent of this radius go from a to b?" Answered by RealityKit physics queries against the LiDAR scene mesh in
/// the app (S1) and by the traversability grid on the server (S2); by simple rectangles in the tests.
public protocol SimWorld {
    func isFree(from a: V2, to b: V2, radius: Double) -> Bool
}

/// Collision helpers (pure).
public enum SimCollide {
    /// Remove the part of `move` that goes into a surface with (ground-frame) normal `normal`; motion along or away
    /// from the surface is kept. This is the "slide along the wall" response.
    public static func slide(_ move: V2, normal: V2) -> V2 {
        let len = SimMath.length(normal)
        guard len > 1e-9 else { return .zero }
        let n = normal / len
        let d = SimMath.dot(move, n)
        return d < 0 ? move - d * n : move
    }

    /// True when moving from `a` to `b` brings a disc of radius `r` closer to any other disc it already overlaps or
    /// would overlap (agents never walk through each other; moving apart is always allowed).
    public static func agentBlocked(from a: V2, to b: V2, radius r: Double, others: [(pos: V2, radius: Double)]) -> Bool {
        for o in others {
            let need = r + o.radius
            let dNew = SimMath.length(b - o.pos)
            if dNew < need && dNew < SimMath.length(a - o.pos) - 1e-9 { return true }
        }
        return false
    }
}

/// What the floor probe says about a step (robot: tracks climb ~6 cm; animals use their own limits).
public enum StepCheck: String, Equatable {
    case ok, wall, cliff, noFloor

    public static func classify(currentFloor: Double, newFloor: Double?, maxStep: Double, maxDrop: Double) -> StepCheck {
        guard let f = newFloor else { return .noFloor }
        let dz = f - currentFloor
        if dz > maxStep { return .wall }
        if -dz > maxDrop { return .cliff }
        return .ok
    }
}
