import Foundation

// SnailSight 11.0: client tile selection, an EXACT port of the server's reference algorithm
// (snailCOP services/snailsight/tileselect.py, verified there by tools/tile_client_sim.py). Plan §3.2.
//
// Distance to a node = distance from the camera to its bounding box, the vertical part weighted × VZ (other storeys
// count as farther: a floor slab is in the way). Heading prefetch: d_eff = d − cos(angle to heading) ·
// min(speed · LOOKAHEAD_S, LOOKAHEAD_MAX_M). A node is REFINED (its children drawn instead) while d_eff < its size ×
// REFINE_K: 8 m parents open within 8 m (so leaves = the near band ≤ 8 m), 16 m parents within 16 m, … Nothing farther
// than FAR_M is drawn. Budget (plan Q7: 600 MB): near (leaves) ≤ 350 MB, mid (parents) ≤ 150 MB by the tiles' `mem`
// estimate; over budget the farthest go first. A parent stays drawn until all its wanted children are loaded (no holes).
// Storeys (11.0.1): the camera's level = the slab under its feet (camera z − FEET_M: outdoors the camera's height is in
// the main floor's slab while the ground is level 0); every other storey adds LEVEL_PENALTY_M per level of difference,
// so the phone never pulls the floor above / below through a slab. FAR_M = 25 m = the plan's mid band.

public enum TileSelect {
    public static let VZ = 3.0
    public static let REFINE_K = 1.0
    public static let FAR_M = 25.0
    public static let FEET_M = 1.0
    public static let LEVEL_PENALTY_M = 30.0   // > FAR_M: another storey is never drawn
    public static let LOOKAHEAD_S = 5.0
    public static let LOOKAHEAD_MAX_M = 10.0
    public static let NEAR_BUDGET = 350 * (1 << 20)
    public static let MID_BUDGET = 150 * (1 << 20)
    public static let LEAF_M = 4
    /// The app re-selects this often (tile_client_sim STEP_S).
    public static let stepS = 0.5

    public enum Band: String { case near, mid }

    /// One wanted node: the node, its effective distance and its band.
    public struct Want {
        public let node: TileNode
        public let distance: Double
        public let band: Band
    }

    /// Camera → bounding box distance, vertical part × VZ.
    public static func boxDistance(_ cam: [Double], _ n: TileNode) -> Double {
        let c = [n.box[0], n.box[1], n.box[2]], h = [n.box[3], n.box[7], n.box[11]]
        var d = [0.0, 0.0, 0.0]
        for i in 0..<3 { d[i] = max(0.0, abs(cam[i] - c[i]) - h[i]) }
        return (d[0] * d[0] + d[1] * d[1] + (d[2] * VZ) * (d[2] * VZ)).squareRoot()
    }

    /// The camera's storey: the level slab containing camera z − FEET_M (nil = no slabs / outside every slab).
    public static func cameraLevel(z: Double, levels: [TileLevel]) -> Int? {
        let f = z - FEET_M
        return levels.first { f >= $0.zLo && f < $0.zHi }?.level
    }

    /// Distance less the heading lookahead (only while moving faster than 5 cm/s toward the node); other storeys
    /// than the camera's add LEVEL_PENALTY_M per level.
    public static func effDistance(_ cam: [Double], heading: (Double, Double)?, speed: Double, _ n: TileNode,
                                   camLevel: Int? = nil) -> Double {
        var d = boxDistance(cam, n)
        if let cl = camLevel, n.level != cl { d += LEVEL_PENALTY_M * Double(abs(n.level - cl)) }
        guard speed > 0.05, let hd = heading else { return d }
        let vx = n.box[0] - cam[0], vy = n.box[1] - cam[1]
        let ln = (vx * vx + vy * vy).squareRoot()
        if ln < 1e-6 { return d }
        let cosang = (vx * hd.0 + vy * hd.1) / ln
        return max(0.0, d - max(0.0, cosang) * min(speed * LOOKAHEAD_S, LOOKAHEAD_MAX_M))
    }

    /// The set of nodes that should be drawn (REPLACE: no ancestor together with a descendant), keyed by tile key.
    public static func select(_ roots: [TileNode], cam: [Double], heading: (Double, Double)? = nil, speed: Double = 0,
                              nearBudget: Int = NEAR_BUDGET, midBudget: Int = MID_BUDGET,
                              camLevel: Int? = nil) -> [String: Want] {
        var want: [Want] = []
        func visit(_ n: TileNode) {
            let d = effDistance(cam, heading: heading, speed: speed, n, camLevel: camLevel)
            if d > FAR_M { return }
            if !n.children.isEmpty && d < Double(n.size) * REFINE_K {
                for c in n.children { visit(c) }
                return
            }
            if n.uri != nil {
                want.append(Want(node: n, distance: d, band: n.size == LEAF_M ? .near : .mid))
            }
        }
        for r in roots { visit(r) }
        var out: [String: Want] = [:]
        for (band, budget) in [(Band.near, nearBudget), (Band.mid, midBudget)] {
            var used = 0
            // stable sort by distance (Python's sorted() is stable: ties keep the visit order)
            let inBand = want.enumerated().filter { $0.element.band == band }
                .sorted { $0.element.distance != $1.element.distance ? $0.element.distance < $1.element.distance
                                                                     : $0.offset < $1.offset }
            for (_, w) in inBand {
                if used + w.node.mem > budget { continue }
                used += w.node.mem
                out[w.node.key] = w
            }
        }
        return out
    }

    /// child key → parent key.
    public static func ancestorsMap(_ roots: [TileNode]) -> [String: String] {
        var par: [String: String] = [:]
        func walk(_ n: TileNode) {
            for c in n.children {
                par[c.key] = n.key
                walk(c)
            }
        }
        for r in roots { walk(r) }
        return par
    }

    /// What is on screen: wanted + loaded nodes, and a previously drawn ancestor stays until every wanted descendant
    /// under it is loaded (no holes).
    public static func drawn(want: [String: Want], loaded: Set<String>, parents par: [String: String],
                             prevDrawn: Set<String>) -> Set<String> {
        var out = Set(want.keys.filter { loaded.contains($0) })
        for k in want.keys where !loaded.contains(k) {
            var a = par[k]
            while let ak = a {
                if prevDrawn.contains(ak) && loaded.contains(ak) {
                    out.insert(ak)
                    break
                }
                a = par[ak]
            }
        }
        return out
    }

    /// Wanted keys not loaded yet, nearest first (the download order).
    public static func fetchOrder(_ want: [String: Want], loaded: Set<String>) -> [Want] {
        want.values.filter { !loaded.contains($0.node.key) }
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.node.key < $1.node.key }
    }

    /// Loaded keys that are neither wanted nor drawn (an ancestor kept as a hole-filler stays): evict these.
    public static func evictable(loaded: Set<String>, want: [String: Want], drawn: Set<String>) -> [String] {
        loaded.filter { want[$0] == nil && !drawn.contains($0) }.sorted()
    }
}

/// Speed + heading in the map plane from recent camera positions (the app's 0.5 s tick).
public struct TileMotion {
    public var window: Double = 1.5
    private var samples: [(t: Double, x: Double, y: Double)] = []

    public init() {}

    public mutating func add(t: Double, x: Double, y: Double) {
        samples.append((t, x, y))
        while let f = samples.first, t - f.t > window { samples.removeFirst() }
    }

    /// m/s over the window (0 with fewer than two samples or < 0.2 s of history).
    public var speed: Double {
        guard let a = samples.first, let b = samples.last, b.t - a.t >= 0.2 else { return 0 }
        return ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot() / (b.t - a.t)
    }

    public mutating func reset() { samples.removeAll() }

    /// Unit heading in the map plane from a forward vector (camera forward in map coordinates); nil when looking
    /// straight up / down.
    public static func heading(forward f: [Double]) -> (Double, Double)? {
        guard f.count >= 2 else { return nil }
        let l = (f[0] * f[0] + f[1] * f[1]).squareRoot()
        guard l > 1e-3 else { return nil }
        return (f[0] / l, f[1] / l)
    }
}
