import Foundation

// SnailSight S1 navigation for sim agents (owner 9.3.65: "Go to point — simple path planning on the floor grid from
// the scene mesh — A* on a 2D occupancy derived from the mesh around the user, respecting step/drop limits").
// Pure: the app feeds world triangles of the LiDAR scene mesh (ARMeshAnchor faces) around the user; everything here
// is in the ground frame (x, y) with heights h = ARKit y. S2 replaces the input with the P3 traversability grid.

public struct GridSpec: Equatable {
    public var origin: V2           // min corner (ground frame)
    public var cell: Double
    public var nx: Int, ny: Int

    public init(origin: V2, cell: Double, nx: Int, ny: Int) {
        self.origin = origin; self.cell = cell; self.nx = nx; self.ny = ny
    }

    /// A square grid of `half` metres around `center`.
    public init(center: V2, half: Double, cell: Double) {
        let n = max(1, Int((2 * half / cell).rounded(.up)))
        self.init(origin: center - V2(half, half), cell: cell, nx: n, ny: n)
    }

    public func index(_ p: V2) -> (Int, Int)? {
        let i = Int(((p.x - origin.x) / cell).rounded(.down)), j = Int(((p.y - origin.y) / cell).rounded(.down))
        return (i >= 0 && j >= 0 && i < nx && j < ny) ? (i, j) : nil
    }

    public func center(_ i: Int, _ j: Int) -> V2 { origin + V2((Double(i) + 0.5) * cell, (Double(j) + 0.5) * cell) }
    public func flat(_ i: Int, _ j: Int) -> Int { j * nx + i }
}

/// Planner cell classes. `hard` = blocked, or within the agent's radius of something blocked (its centre may not go
/// there); `near` = a margin band beyond that, passable at a high cost (paths keep off walls where they can), and the
/// agent's own spot (so one standing next to a wall can still leave).
public enum NavCell: UInt8, Equatable { case free = 0, near = 1, hard = 2 }

public struct NavGrid {
    public let spec: GridSpec
    public var cells: [NavCell]
    /// Walkable surface height per cell (nil = no floor seen).
    public var floor: [Double?]
    public var maxStep: Double

    public func at(_ i: Int, _ j: Int) -> NavCell { cells[spec.flat(i, j)] }
    public func floorAt(_ i: Int, _ j: Int) -> Double? { floor[spec.flat(i, j)] }
}

/// Builds a NavGrid from scene-mesh triangles: per cell, the floor is the highest surface at most `maxStep` above the
/// agent's floor; a cell is hard when it has no floor (never invent one), a drop deeper than `maxDrop`, or anything in
/// the body band (floor + maxStep … floor + bodyHeight + 5 cm). Table tops above the body are ignored (drive under).
public struct NavGridBuilder {
    public let spec: GridSpec
    public let refFloor: Double
    public let maxStep: Double
    public let maxDrop: Double
    public let bodyHeight: Double
    private var floorTop: [Double]
    private var samples: [[Double]]

    public init(spec: GridSpec, refFloor: Double, maxStep: Double, maxDrop: Double, bodyHeight: Double) {
        self.spec = spec; self.refFloor = refFloor; self.maxStep = maxStep; self.maxDrop = maxDrop
        self.bodyHeight = bodyHeight
        floorTop = Array(repeating: -.infinity, count: spec.nx * spec.ny)
        samples = Array(repeating: [], count: spec.nx * spec.ny)
    }

    public mutating func add(_ g: V2, h: Double) {
        guard let (i, j) = spec.index(g) else { return }
        let k = spec.flat(i, j)
        if h <= refFloor + maxStep + 0.01 { floorTop[k] = max(floorTop[k], h) }
        if h < refFloor + bodyHeight + 0.6 && samples[k].count < 48 { samples[k].append(h) }
    }

    /// Sample a triangle (ground point + height per corner) densely enough that every cell it covers gets a point.
    public mutating func addTriangle(_ a: (V2, Double), _ b: (V2, Double), _ c: (V2, Double)) {
        let lo = V2(min(a.0.x, b.0.x, c.0.x), min(a.0.y, b.0.y, c.0.y))
        let hi = V2(max(a.0.x, b.0.x, c.0.x), max(a.0.y, b.0.y, c.0.y))
        let gMax = spec.origin + V2(Double(spec.nx), Double(spec.ny)) * spec.cell
        guard hi.x >= spec.origin.x, hi.y >= spec.origin.y, lo.x <= gMax.x, lo.y <= gMax.y else { return }
        func d(_ p: (V2, Double), _ q: (V2, Double)) -> Double {
            max(SimMath.length(p.0 - q.0), abs(p.1 - q.1) * 0.5)
        }
        let longest = max(d(a, b), d(b, c), d(c, a))
        let n = min(64, max(1, Int((longest / (spec.cell * 0.6)).rounded(.up))))
        for i in 0...n {
            for j in 0...(n - i) {
                let u = Double(i) / Double(n), v = Double(j) / Double(n), w = 1 - u - v
                add(a.0 * w + b.0 * u + c.0 * v, h: a.1 * w + b.1 * u + c.1 * v)
            }
        }
    }

    /// Classify and inflate by the agent's radius. `clearAround` (the agent's own spot) is never hard: it is standing
    /// there, so there is floor even if the mesh under it is thin.
    public func build(inflate radius: Double, softMargin: Double = 0.12, clearAround: V2? = nil,
                      clearRadius: Double = 0) -> NavGrid {
        let n = spec.nx * spec.ny
        var hard = [Bool](repeating: false, count: n)
        var floor = [Double?](repeating: nil, count: n)
        for k in 0..<n {
            let f = floorTop[k]
            guard f > -.infinity else { hard[k] = true; continue }          // no floor (unknown or a step up)
            floor[k] = f
            if f < refFloor - maxDrop { hard[k] = true; continue }           // cliff / stairwell
            if samples[k].contains(where: { $0 > f + maxStep && $0 <= f + bodyHeight + 0.05 }) { hard[k] = true }
        }
        if let c = clearAround {
            for j in 0..<spec.ny { for i in 0..<spec.nx where SimMath.length(spec.center(i, j) - c) <= clearRadius {
                let k = spec.flat(i, j)
                hard[k] = false
                if floor[k] == nil { floor[k] = refFloor }
            } }
        }
        // hard within `radius` of anything hard (the agent's centre may not go there), a costly `near` band beyond it
        var cells = [NavCell](repeating: .free, count: n)
        var inflatedOnly = [Bool](repeating: false, count: n)
        let outer = radius + softMargin
        let r = Int((outer / spec.cell).rounded(.up))
        for j in 0..<spec.ny {
            for i in 0..<spec.nx where hard[spec.flat(i, j)] {
                cells[spec.flat(i, j)] = .hard
                guard r > 0 else { continue }
                for dj in -r...r {
                    for di in -r...r where (di != 0 || dj != 0) {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, jj >= 0, ii < spec.nx, jj < spec.ny else { continue }
                        let d2 = Double(di * di + dj * dj) * spec.cell * spec.cell
                        guard d2 <= outer * outer + 1e-9 else { continue }
                        let k = spec.flat(ii, jj)
                        if hard[k] { continue }
                        if d2 <= radius * radius + 1e-9 { cells[k] = .hard; inflatedOnly[k] = true }
                        else if cells[k] == .free { cells[k] = .near }
                    }
                }
            }
        }
        if let c = clearAround {      // the agent may always leave its own spot (it may be standing next to a wall)
            for j in 0..<spec.ny { for i in 0..<spec.nx where SimMath.length(spec.center(i, j) - c) <= clearRadius {
                let k = spec.flat(i, j)
                if inflatedOnly[k] || cells[k] == .hard && !hard[k] { cells[k] = .near }
            } }
        }
        return NavGrid(spec: spec, cells: cells, floor: floor, maxStep: maxStep)
    }
}

/// Binary min-heap keyed by Double (A* open list).
struct MinHeap {
    private var a: [(Double, Int)] = []
    var isEmpty: Bool { a.isEmpty }
    mutating func push(_ k: Double, _ v: Int) {
        a.append((k, v))
        var i = a.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if a[p].0 <= a[i].0 { break }
            a.swapAt(p, i); i = p
        }
    }
    mutating func pop() -> (Double, Int)? {
        guard !a.isEmpty else { return nil }
        let top = a[0]
        let last = a.removeLast()
        if !a.isEmpty {
            a[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < a.count && a[l].0 < a[m].0 { m = l }
                if r < a.count && a[r].0 < a[m].0 { m = r }
                if m == i { break }
                a.swapAt(i, m); i = m
            }
        }
        return top
    }
}

public enum PlanFailure: String, Error, Equatable { case startOutside, goalOutside, goalBlocked, noPath }

public enum AStar {
    public static let nearCost = 4.0

    /// 8-connected A* (octile heuristic, no corner cutting, floor steps ≤ maxStep between neighbours), then string
    /// pulling over free cells. Returns ground-frame waypoints from `start` to the goal (snapped to the nearest
    /// passable cell within `goalSnap` when the tapped spot itself is blocked).
    public static func plan(_ g: NavGrid, from start: V2, to goal: V2, goalSnap: Double = 0.6,
                            maxExpansions: Int = 400_000) -> Result<[V2], PlanFailure> {
        let s = g.spec
        guard let (si, sj) = s.index(start) else { return .failure(.startOutside) }
        guard let (gi0, gj0) = s.index(goal) else { return .failure(.goalOutside) }
        var (gi, gj) = (gi0, gj0)
        var goalPoint = goal
        if g.at(gi, gj) == .hard {
            guard let snapped = nearestPassable(g, gi, gj, within: goalSnap) else { return .failure(.goalBlocked) }
            (gi, gj) = snapped
            goalPoint = s.center(gi, gj)
        }
        let n = s.nx * s.ny
        var cost = [Double](repeating: .infinity, count: n)
        var from = [Int](repeating: -1, count: n)
        var closed = [Bool](repeating: false, count: n)
        let startK = s.flat(si, sj), goalK = s.flat(gi, gj)
        func h(_ i: Int, _ j: Int) -> Double {
            let dx = Double(abs(i - gi)), dy = Double(abs(j - gj))
            return (max(dx, dy) + (2.0.squareRoot() - 1) * min(dx, dy)) * s.cell
        }
        var open = MinHeap()
        cost[startK] = 0
        open.push(h(si, sj), startK)
        var expanded = 0
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        while let (_, k) = open.pop() {
            if closed[k] { continue }
            closed[k] = true
            if k == goalK { break }
            expanded += 1
            if expanded > maxExpansions { return .failure(.noPath) }
            let i = k % s.nx, j = k / s.nx
            for (di, dj) in dirs {
                let ii = i + di, jj = j + dj
                guard ii >= 0, jj >= 0, ii < s.nx, jj < s.ny else { continue }
                let kk = s.flat(ii, jj)
                if closed[kk] || g.cells[kk] == .hard { continue }
                if di != 0 && dj != 0 && (g.at(i + di, j) == .hard || g.at(i, j + dj) == .hard) { continue }
                if !stepOK(g, k, kk) { continue }
                let base = (di != 0 && dj != 0 ? 2.0.squareRoot() : 1) * s.cell
                let c = cost[k] + base * (g.cells[kk] == .near ? nearCost : 1)
                if c < cost[kk] {
                    cost[kk] = c
                    from[kk] = k
                    open.push(c + h(ii, jj), kk)
                }
            }
        }
        guard cost[goalK] < .infinity else { return .failure(.noPath) }
        var cellsPath: [Int] = []
        var k = goalK
        while k != -1 { cellsPath.append(k); k = from[k] }
        cellsPath.reverse()
        var pts = cellsPath.map { s.center($0 % s.nx, $0 / s.nx) }
        pts[0] = start
        pts[pts.count - 1] = goalPoint
        return .success(smooth(g, pts))
    }

    static func stepOK(_ g: NavGrid, _ a: Int, _ b: Int) -> Bool {
        guard let fa = g.floor[a], let fb = g.floor[b] else { return true }
        return abs(fa - fb) <= g.maxStep
    }

    static func nearestPassable(_ g: NavGrid, _ i0: Int, _ j0: Int, within r: Double) -> (Int, Int)? {
        let rc = Int((r / g.spec.cell).rounded(.up))
        var best: (Int, Int, Int)?
        for dj in -rc...rc {
            for di in -rc...rc {
                let i = i0 + di, j = j0 + dj
                guard i >= 0, j >= 0, i < g.spec.nx, j < g.spec.ny, g.at(i, j) != .hard else { continue }
                let d2 = di * di + dj * dj
                if Double(d2) * g.spec.cell * g.spec.cell > r * r { continue }
                if best == nil || d2 < best!.2 { best = (i, j, d2) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// True when the straight segment crosses only free cells with floor steps ≤ maxStep.
    public static func lineOfSight(_ g: NavGrid, _ a: V2, _ b: V2) -> Bool {
        let len = SimMath.length(b - a)
        let n = max(1, Int((len / (g.spec.cell * 0.5)).rounded(.up)))
        var prev: Int?
        for t in 0...n {
            let p = a + (b - a) * (Double(t) / Double(n))
            guard let (i, j) = g.spec.index(p) else { return false }
            let k = g.spec.flat(i, j)
            if g.cells[k] != .free && t != 0 && t != n { return false }
            if g.cells[k] == .hard { return false }
            if let q = prev, q != k, !stepOK(g, q, k) { return false }
            prev = k
        }
        return true
    }

    /// Greedy string pulling: from each kept point jump to the farthest later point still in line of sight.
    public static func smooth(_ g: NavGrid, _ pts: [V2]) -> [V2] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        var i = 0
        while i < pts.count - 1 {
            var j = pts.count - 1
            while j > i + 1 && !lineOfSight(g, pts[i], pts[j]) { j -= 1 }
            out.append(pts[j])
            i = j
        }
        return out
    }

    public static func length(_ path: [V2]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + SimMath.length($1.1 - $1.0) }
    }
}

/// Pure-pursuit style follower for the diff-drive robot: turn in place on sharp corners (as the real tracks do), else
/// drive at the Nav2 speed with a heading-proportional turn rate, slowing for the goal. nil = arrived.
public struct PathFollower: Equatable {
    public var path: [V2]
    public private(set) var index = 1
    public var lookahead = 0.35
    public var goalTolerance = 0.12
    /// Stop this far short of the goal (Follow me keeps its distance).
    public var stopDistance = 0.0

    public init(path: [V2], stopDistance: Double = 0) {
        self.path = path
        self.stopDistance = stopDistance
        index = path.count > 1 ? 1 : 0
    }

    public var goal: V2? { path.last }

    public mutating func command(pose: DrivePose, profile p: RobotProfile) -> DriveCommand? {
        guard let goal = path.last else { return nil }
        let toGoal = SimMath.length(goal - pose.position)
        if toGoal <= goalTolerance + stopDistance { return nil }
        while index < path.count - 1 && SimMath.length(path[index] - pose.position) < lookahead { index += 1 }
        let target = path[index]
        let err = SimMath.wrap(SimMath.heading(target - pose.position) - pose.theta)
        if abs(err) > 50 * Double.pi / 180 {
            return DriveCommand(v: 0, omega: (err > 0 ? 1 : -1) * p.maxYawRate * 0.8)
        }
        let slow = SimMath.clamp((toGoal - stopDistance) / 0.6, 0.25, 1)
        let v = p.navSpeed * max(0.3, cos(err)) * slow
        let w = SimMath.clamp(2.5 * err, -p.maxYawRate, p.maxYawRate)
        return DriveCommand(v: v, omega: w)
    }
}
