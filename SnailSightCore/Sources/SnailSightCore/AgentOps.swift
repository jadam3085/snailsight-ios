import Foundation

// SnailSight 12.0 agent ops (concept O2) + outdoor terrain map (concept O1): the pure parts.
// - AgentOpsControl: Hold / Climb above / Return / Land now for a selected sim drone or rover, with what the map
//   server can do TODAY (API §5.9: robot / drone orders idle | goto | follow | patrol | teleop; a drone flies at the
//   altitude it was spawned with). With the server flag `drone_missions` (API §5.16) the drone gets the real orders
//   {hold|climb_above|return|land: true}; without it, controls the server cannot do are disabled WITH the reason.
// - ObstacleBanner: "Obstacle sensor took over" from the planner status / events of the selected agent.
// - AltitudeProfile: ground (+ canopy, when known) under a route, for the O2 strip.
// - TerrainPlanRaster: the O1 terrain colouring of a robot terrain grid: slope shading, robot no-go, and which cells
//   are SURVEYED (measured by our sensors) vs ESTIMATED / not measured (drawn hatched by the view).
// - GapFinder: "Explore gaps": the biggest unsurveyed area next to surveyed ground, as a goal.
// Pure, Linux-tested (AgentOpsTests).

public enum AgentOpsControl: String, CaseIterable, Equatable {
    case hold, climbAbove, returnHome, landNow

    public var title: String {
        switch self {
        case .hold: return "Hold"
        case .climbAbove: return "Climb above"
        case .returnHome: return "Return"
        case .landNow: return "Land now"
        }
    }

    public var symbol: String {
        switch self {
        case .hold: return "pause.circle"
        case .climbAbove: return "arrow.up.to.line"
        case .returnHome: return "arrow.uturn.backward.circle"
        case .landNow: return "arrow.down.to.line"
        }
    }

    /// The server feature flag (GET /v1 `features`) of the drone mission orders (API §5.16, estimated-world lane).
    public static let missionsFlag = "drone_missions"

    /// The §5.16 one-of order key.
    public var missionKey: String {
        switch self {
        case .hold: return "hold"
        case .climbAbove: return "climb_above"
        case .returnHome: return "return"
        case .landNow: return "land"
        }
    }

    /// Controls shown for a drone / a rover.
    public static func offered(drone: Bool) -> [AgentOpsControl] {
        drone ? [.hold, .climbAbove, .returnHome, .landNow] : [.hold, .returnHome]
    }

    public struct Availability: Equatable {
        public var enabled: Bool
        public var reason: String?
    }

    /// Enabled, or why not. `home` = where Return goes without mission orders (nil = unknown).
    public func availability(drone: Bool, features: Set<String>, home: [Double]?, serverSim: Bool) -> Availability {
        guard serverSim else { return Availability(enabled: false, reason: "Needs the shared server sim") }
        if drone && features.contains(Self.missionsFlag) { return Availability(enabled: true, reason: nil) }
        switch self {
        case .hold: return Availability(enabled: true, reason: nil)
        case .returnHome:
            return home == nil ? Availability(enabled: false, reason: "No launch point known yet")
                               : Availability(enabled: true, reason: nil)
        case .climbAbove, .landNow:
            guard drone else { return Availability(enabled: false, reason: "Drones only") }
            return Availability(enabled: false, reason: self == .climbAbove
                                ? "The map server has no climb order yet (drone missions not switched on)"
                                : "The map server has no land order yet (Hold keeps it hovering)")
        }
    }

    /// The order to send for an enabled control: the §5.16 mission orders when the server has them (drones), else the
    /// plain sim orders (Hold = stop, Return = a goto to the launch point).
    public func command(drone: Bool = true, features: Set<String> = [], home: [Double]?) -> SimServerAPI.Command? {
        if drone && features.contains(Self.missionsFlag) { return .droneOp(missionKey) }
        switch self {
        case .hold: return .stop
        case .returnHome:
            guard let h = home, h.count >= 2 else { return nil }
            return .goal(x: h[0], y: h[1], z: h.count > 2 ? h[2] : nil)
        case .climbAbove, .landNow: return nil
        }
    }
}

/// O2's banner: the onboard obstacle sensor took over (replanned around something the estimate did not have).
public struct ObstacleBanner: Equatable {
    public var title: String
    public var detail: String
    public var at: Double

    /// From the selected agent's planner status (`nav`) and the latest sim event for it (`event`: block / stuck /
    /// plan / goal_failed …). nil = nothing to say.
    public static func make(nav: SimNav?, event: String?, eventDetail: String? = nil, now: Double) -> ObstacleBanner? {
        switch event {
        case "obstacle_takeover", "takeover":
            return ObstacleBanner(title: "Obstacle sensor took over",
                                  detail: eventDetail ?? "Something the estimate did not have; the route is replanned around it",
                                  at: now)
        case "block":
            return ObstacleBanner(title: "Obstacle sensor took over",
                                  detail: eventDetail ?? "Something is in the way; the route is replanned around it", at: now)
        case "plan":
            return ObstacleBanner(title: "Route replanned", detail: eventDetail ?? "A new route around what the sensors saw",
                                  at: now)
        case "stuck", "goal_failed":
            return ObstacleBanner(title: "Can't get through", detail: eventDetail ?? nav?.reason ?? "No way past the obstacle",
                                  at: now)
        default: break
        }
        guard let n = nav else { return nil }
        switch n.status {
        case "no_path": return ObstacleBanner(title: "No route", detail: n.reason ?? "Nothing passable to the goal", at: now)
        case "stuck": return ObstacleBanner(title: "Stuck", detail: n.reason ?? "Inside an obstacle", at: now)
        case "lost": return ObstacleBanner(title: "Lost", detail: n.reason ?? "No position", at: now)
        default: return nil
        }
    }

    public func visible(now: Double, for s: Double = 8) -> Bool { now - at < s }
}

/// One sample of the O2 altitude strip.
public struct AltitudeSample: Equatable {
    public var s: Double                    // metres along the route
    public var ground: Double?              // map z of the ground (nil = unknown)
    public var body: Double                 // the agent's planned z
    public var canopy: Double?              // canopy top (estimated), nil = none / unknown
}

public enum AltitudeProfile {
    /// Samples every `step` metres along `route` ([[x, y, z]…]); `ground(x, y)` and `canopy(x, y)` look up the terrain.
    public static func sample(route: [[Double]], step: Double = 0.5, ground: (Double, Double) -> Double?,
                              canopy: (Double, Double) -> Double? = { _, _ in nil }) -> [AltitudeSample] {
        guard route.count >= 2, step > 0 else {
            return route.first.map { p in [AltitudeSample(s: 0, ground: ground(p[0], p[1]), body: p.count > 2 ? p[2] : 0,
                                                          canopy: canopy(p[0], p[1]))] } ?? []
        }
        var out: [AltitudeSample] = []
        var acc = 0.0
        var next = 0.0
        for i in 0..<(route.count - 1) {
            let a = route[i], b = route[i + 1]
            let az = a.count > 2 ? a[2] : 0, bz = b.count > 2 ? b[2] : 0
            let len = hypot(b[0] - a[0], b[1] - a[1])
            while next <= acc + len + 1e-9 {
                let u = len > 0 ? (next - acc) / len : 0
                let x = a[0] + (b[0] - a[0]) * u, y = a[1] + (b[1] - a[1]) * u
                out.append(AltitudeSample(s: next, ground: ground(x, y), body: az + (bz - az) * u, canopy: canopy(x, y)))
                next += step
            }
            acc += len
        }
        return out
    }

    /// The lowest clearance (body − max(ground, canopy)) along the samples; nil = nothing known.
    public static func minClearance(_ s: [AltitudeSample]) -> Double? {
        let c = s.compactMap { x -> Double? in
            let top = [x.ground, x.canopy].compactMap { $0 }.max()
            return top.map { x.body - $0 }
        }
        return c.min()
    }

    /// The route length (xy).
    public static func length(_ route: [[Double]]) -> Double {
        guard route.count >= 2 else { return 0 }
        return (0..<(route.count - 1)).reduce(0) { $0 + hypot(route[$1 + 1][0] - route[$1][0], route[$1 + 1][1] - route[$1][1]) }
    }
}

/// O1 terrain colouring of a robot terrain grid (API §8.10 layers elevation / slope / cost / unknown).
public enum TerrainPlanRaster {
    public enum Cell: UInt8 { case unknown = 0, ground, caution, noGo }

    public struct Result: Equatable {
        public var nx: Int, ny: Int
        public var rgba: [UInt8]                // row 0 = max y (image order), 4 bytes per cell
        public var surveyed: Int                // measured cells
        public var unknown: Int                 // inside the bounds, not measured (drawn hatched as "estimated")
        public var noGo: Int
        public var surveyedFrac: Double { let t = surveyed + unknown; return t > 0 ? Double(surveyed) / Double(t) : 0 }
    }

    /// `maxSlopeDeg` = robot no-go slope (RobosnailBob ~14°: the O1 example).
    public static func classify(slopeDeg: Float?, cost: Float?, unknown: Float?, maxSlopeDeg: Float = 14) -> Cell {
        if let u = unknown, u > 0.5 { return .unknown }
        guard slopeDeg != nil || cost != nil else { return .unknown }
        if let s = slopeDeg, s.isFinite, s > maxSlopeDeg { return .noGo }
        if let c = cost, c.isFinite {
            switch TerrainClass.of(cost: c) {
            case .lethal: return .noGo
            case .hard, .caution: return .caution
            case .free: break
            }
        }
        if let s = slopeDeg, !s.isFinite { return .unknown }
        return .ground
    }

    /// Hillshade 0.55…1.0 from the slope (steeper = darker) for a ground cell.
    public static func shade(slopeDeg: Float?) -> Double {
        guard let s = slopeDeg, s.isFinite else { return 1 }
        return max(0.55, 1 - Double(min(s, 45)) / 45 * 0.45)
    }

    public static func build(_ g: TerrainGrid, maxSlopeDeg: Float = 14) -> Result {
        var rgba = [UInt8](repeating: 0, count: g.nx * g.ny * 4)
        var surveyed = 0, unknown = 0, nogo = 0
        for iy in 0..<g.ny {
            for ix in 0..<g.nx {
                let slope = g.value("slope", ix: ix, iy: iy)          // degrees (terrain.py UNITS)
                let c = classify(slopeDeg: slope, cost: g.value("cost", ix: ix, iy: iy),
                                 unknown: g.value("unknown", ix: ix, iy: iy), maxSlopeDeg: maxSlopeDeg)
                let row = g.ny - 1 - iy
                let o = (row * g.nx + ix) * 4
                switch c {
                case .unknown:
                    unknown += 1
                    continue
                case .ground:
                    surveyed += 1
                    let k = shade(slopeDeg: slope)
                    rgba[o] = UInt8(78 * k); rgba[o + 1] = UInt8(130 * k); rgba[o + 2] = UInt8(62 * k); rgba[o + 3] = 235
                case .caution:
                    surveyed += 1
                    let k = shade(slopeDeg: slope)
                    rgba[o] = UInt8(150 * k); rgba[o + 1] = UInt8(140 * k); rgba[o + 2] = UInt8(60 * k); rgba[o + 3] = 235
                case .noGo:
                    surveyed += 1; nogo += 1
                    rgba[o] = 231; rgba[o + 1] = 160; rgba[o + 2] = 60; rgba[o + 3] = 235
                }
            }
        }
        return Result(nx: g.nx, ny: g.ny, rgba: rgba, surveyed: surveyed, unknown: unknown, noGo: nogo)
    }

    /// Unknown cells inside the grid (for the hatch) as a mask, row 0 = max y.
    public static func unknownMask(_ g: TerrainGrid) -> [Bool] {
        var m = [Bool](repeating: false, count: g.nx * g.ny)
        for iy in 0..<g.ny {
            for ix in 0..<g.nx {
                let u = g.value("unknown", ix: ix, iy: iy).map { $0 > 0.5 }
                    ?? !(g.value("elevation", ix: ix, iy: iy).map { $0.isFinite } ?? false)
                m[(g.ny - 1 - iy) * g.nx + ix] = u
            }
        }
        return m
    }
}

/// "Explore gaps": the largest connected not-surveyed region that touches surveyed ground, and the surveyed cell next
/// to it to drive / fly to.
public enum GapFinder {
    public struct Gap: Equatable {
        public var cells: Int
        public var center: [Double]              // map xy of the region's centroid
        public var approach: [Double]            // map xy of a surveyed cell on its border (the goal)
    }

    /// `unknown` / `known` masks in grid order (index = iy * nx + ix, iy 0 = min y).
    public static func find(nx: Int, ny: Int, x0: Double, y0: Double, cell: Double, unknown: [Bool], known: [Bool],
                            minCells: Int = 20) -> Gap? {
        guard nx > 0, ny > 0, unknown.count == nx * ny, known.count == nx * ny else { return nil }
        var seen = [Bool](repeating: false, count: nx * ny)
        var best: Gap?
        for start in 0..<(nx * ny) where unknown[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var n = 0, sx = 0.0, sy = 0.0
            var border: Int?
            while let i = stack.popLast() {
                n += 1
                let ix = i % nx, iy = i / nx
                sx += Double(ix); sy += Double(iy)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let jx = ix + dx, jy = iy + dy
                    guard jx >= 0, jy >= 0, jx < nx, jy < ny else { continue }
                    let j = jy * nx + jx
                    if unknown[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    else if known[j] && border == nil { border = j }
                }
            }
            guard n >= minCells, let b = border, n > (best?.cells ?? 0) else { continue }
            best = Gap(cells: n, center: [x0 + (sx / Double(n) + 0.5) * cell, y0 + (sy / Double(n) + 0.5) * cell],
                       approach: [x0 + (Double(b % nx) + 0.5) * cell, y0 + (Double(b / nx) + 0.5) * cell])
        }
        return best
    }
}
