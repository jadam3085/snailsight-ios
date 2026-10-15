import Foundation

// SnailSight S1 support physics (owner 9.3.65: "when the real world changes — a box under them is moved away and the
// LiDAR mesh updates — they stay floating"). Bodies resting on the scene mesh re-check what holds them up whenever the
// mesh under them changes, then fall under gravity onto the next surface below, or pop up onto one that appeared.
//
// Deliberately NOT a RealityKit dynamic rigid body on the noisy LiDAR mesh (S1 rejected that for the robot: jitter,
// tipping, tunnelling at low frame rates). Here a body has one degree of freedom (height) and a downward probe fan.
// Never invents a floor: when nothing at all is under a body it holds where it is ("unsupported") and is re-checked
// when the mesh there updates again — usually the floor appears a moment later as the LiDAR sees it.

public enum SupportEvent: Equatable {
    case none
    case startedFalling
    case landed(drop: Double)
    case poppedUp(rise: Double)
    case unsupported
}

public struct SupportState: Equatable {
    /// World height (ARKit y) of the body's underside.
    public var bottom: Double
    public var vy: Double = 0
    public var falling = false
    /// Last probe found no surface below (held in place, waiting for the mesh).
    public var unsupported = false
    public var fallStart: Double = 0
    public init(bottom: Double) { self.bottom = bottom }
}

public enum SupportPhysics {
    public static let gravity = 9.81
    /// Gaps smaller than this are "resting" (LiDAR mesh noise is ~1 cm).
    public static let restTolerance = 0.015
    public static let maxFallSpeed = 6.0

    /// Support height from a probe fan. `hits[0]` is the centre ray, the rest are inset corner rays; each is the
    /// height of the first surface found going down from `bottom + popUp` (nil = nothing within the probe length).
    /// The body rests on the highest surface that holds it: the centre ray, or at least two corners agreeing within
    /// `agree` (so a block hanging half over a table edge stays on the table, but one corner on a lip does not hold).
    public static func supportHeight(hits: [Double?], agree: Double = 0.03) -> Double? {
        let found = hits.compactMap { $0 }
        guard !found.isEmpty else { return nil }
        let centre = hits.first ?? nil
        for h in found.sorted(by: >) {
            if let c = centre, abs(c - h) <= agree { return h }
            let corners = hits.dropFirst().compactMap { $0 }.filter { abs($0 - h) <= agree }.count
            if corners >= 2 { return h }
        }
        return centre ?? found.max()
    }

    /// One step. `support` = height of the surface under the body (nil = none found). `popUp` = how far a surface may
    /// rise under a resting body and still lift it (a block lifted by a box slid under it, a robot on a mat);
    /// higher than that the surface went THROUGH the body, which is left where it is.
    @discardableResult
    public static func step(_ s: inout SupportState, support: Double?, dt: Double, popUp: Double) -> SupportEvent {
        guard dt > 0 else { return .none }
        guard let f = support else {
            s.vy = 0
            s.falling = false
            let was = s.unsupported
            s.unsupported = true
            return was ? .none : .unsupported
        }
        s.unsupported = false
        let gap = s.bottom - f
        if gap < -restTolerance {                                   // surface above the underside
            let rise = -gap
            s.vy = 0
            s.falling = false
            if rise <= popUp { s.bottom = f; return .poppedUp(rise: rise) }
            return .none
        }
        if !s.falling {
            if gap <= restTolerance { s.vy = 0; return .none }      // resting
            s.falling = true
            s.fallStart = s.bottom
            s.vy = 0
            integrate(&s, floor: f, dt: dt)
            return s.falling ? .startedFalling : .landed(drop: s.fallStart - s.bottom)
        }
        integrate(&s, floor: f, dt: dt)
        return s.falling ? .none : .landed(drop: s.fallStart - s.bottom)
    }

    private static func integrate(_ s: inout SupportState, floor f: Double, dt: Double) {
        s.vy = max(s.vy - gravity * dt, -maxFallSpeed)
        s.bottom += s.vy * dt
        if s.bottom <= f {
            s.bottom = f
            s.vy = 0
            s.falling = false
        }
    }
}

/// Which bodies a mesh change can affect. Mesh anchors report their world bounds (ARKit y up); a body is affected
/// when the changed region overlaps the column under (and through) its footprint: anything below it may have been
/// what held it up.
public enum SupportWake {
    /// Column of interest for a body: its footprint (x/z grown by `margin`) from `depth` below its underside to its top.
    public static func column(center: SIMD3<Double>, halfXZ: Double, bottom: Double, top: Double,
                              margin: Double = 0.1, depth: Double = 5) -> Bounds3 {
        Bounds3(min: SIMD3(center.x - halfXZ - margin, bottom - depth, center.z - halfXZ - margin),
                max: SIMD3(center.x + halfXZ + margin, top + margin, center.z + halfXZ + margin))
    }

    /// Indices of `columns` touched by any of `regions`.
    public static func affected(columns: [Bounds3], regions: [Bounds3]) -> [Int] {
        guard !regions.isEmpty else { return [] }
        return columns.indices.filter { i in regions.contains { $0.intersects(columns[i]) } }
    }
}

/// Collects changed mesh regions and hands them out at most every `interval` seconds, after `settleDelay` (RealityKit
/// rebuilds the scene-understanding collision shapes for an updated anchor a moment after ARKit reports it). This is
/// the thermal throttle: bursts of anchor updates (ARKit refines many anchors per second while you walk) coalesce
/// into one wake pass.
public struct MeshChangeQueue {
    public var interval: Double
    public var settleDelay: Double
    public private(set) var pending: [Bounds3] = []
    private var firstMark: Double?
    private var lastTake: Double = -.infinity

    public init(interval: Double = 0.25, settleDelay: Double = 0.2) {
        self.interval = interval
        self.settleDelay = settleDelay
    }

    public mutating func mark(_ region: Bounds3, now: Double) {
        if firstMark == nil { firstMark = now }
        // merge with an overlapping region so a hot spot does not grow the list
        if let i = pending.firstIndex(where: { $0.intersects(region) }) { pending[i] = pending[i].union(region) }
        else { pending.append(region) }
    }

    /// Regions ready to process now (empty when throttled or still settling).
    public mutating func take(now: Double) -> [Bounds3] {
        guard let f = firstMark, now - f >= settleDelay, now - lastTake >= interval else { return [] }
        lastTake = now
        firstMark = nil
        defer { pending.removeAll() }
        return pending
    }

    public var isEmpty: Bool { pending.isEmpty }
}
