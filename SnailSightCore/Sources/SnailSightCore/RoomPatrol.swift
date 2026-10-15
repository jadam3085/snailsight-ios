import Foundation

// SnailSight P2a (plan §7 P2a): animals that live in "their" room. Pure geometry for the home area an animal roams or
// paces in: polygons in the 2D GROUND frame (x = ARKit x, y = −ARKit z, metres), the room bounds found by flood-filling
// the LiDAR floor grid from the spawn point, and the pacing loop inside them.

public enum Poly {
    /// Point in polygon (even-odd ray crossing). Polygons with < 3 points contain nothing.
    public static func contains(_ poly: [V2], _ p: V2) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Signed area (CCW positive).
    public static func signedArea(_ poly: [V2]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    public static func area(_ poly: [V2]) -> Double { abs(signedArea(poly)) }

    /// Area centroid (vertex mean for degenerate polygons).
    public static func centroid(_ poly: [V2]) -> V2 {
        guard !poly.isEmpty else { return .zero }
        let a = signedArea(poly)
        if abs(a) < 1e-9 { return poly.reduce(V2.zero, +) / Double(poly.count) }
        var c = V2.zero
        for i in 0..<poly.count {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let k = p.x * q.y - q.x * p.y
            c += (p + q) * k
        }
        return c / (6 * a)
    }

    /// Convex hull (Andrew's monotone chain), counter-clockwise, no repeated first point.
    public static func convexHull(_ pts: [V2]) -> [V2] {
        let s = Array(Set(pts.map { [$0.x, $0.y] })).map { V2($0[0], $0[1]) }
            .sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard s.count >= 3 else { return s }
        func cross(_ o: V2, _ a: V2, _ b: V2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [V2] = [], upper: [V2] = []
        for p in s {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in s.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Regular polygon approximating a circle (CCW).
    public static func circle(center: V2, radius: Double, sides: Int = 16) -> [V2] {
        (0..<max(3, sides)).map { k in center + SimMath.unit(2 * .pi * Double(k) / Double(max(3, sides))) * radius }
    }

    /// Every vertex pulled toward the centroid: factor 1 = unchanged, 0.5 = half size.
    public static func scaled(_ poly: [V2], factor: Double) -> [V2] {
        let c = centroid(poly)
        return poly.map { c + ($0 - c) * factor }
    }

    /// Distance from p to the nearest polygon edge.
    public static func edgeDistance(_ poly: [V2], _ p: V2) -> Double {
        guard poly.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ab = b - a
            let L2 = SimMath.dot(ab, ab)
            let t = L2 < 1e-12 ? 0 : SimMath.clamp(SimMath.dot(p - a, ab) / L2, 0, 1)
            best = min(best, SimMath.length(p - (a + ab * t)))
        }
        return best
    }

    /// Perimeter length.
    public static func perimeter(_ poly: [V2]) -> Double {
        guard poly.count >= 2 else { return 0 }
        return (0..<poly.count).reduce(0) { $0 + SimMath.length(poly[($1 + 1) % poly.count] - poly[$1]) }
    }

    /// `n` points evenly spaced along the perimeter, starting at vertex 0.
    public static func resample(_ poly: [V2], count n: Int) -> [V2] {
        let L = perimeter(poly)
        guard poly.count >= 2, n > 0, L > 1e-9 else { return poly }
        var out: [V2] = []
        let step = L / Double(n)
        var target = 0.0, walked = 0.0
        var i = 0
        while out.count < n && i < poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let seg = SimMath.length(b - a)
            while out.count < n && target <= walked + seg + 1e-12 {
                let t = seg < 1e-12 ? 0 : (target - walked) / seg
                out.append(a + (b - a) * t)
                target += step
            }
            walked += seg
            i += 1
        }
        return out
    }

    /// Rotate by `yaw` (CCW, radians) then translate by `offset`.
    public static func transform(_ poly: [V2], yaw: Double, offset: V2) -> [V2] {
        let c = cos(yaw), s = sin(yaw)
        return poly.map { V2(c * $0.x - s * $0.y, s * $0.x + c * $0.y) + offset }
    }

    /// Inverse of `transform`.
    public static func untransform(_ poly: [V2], yaw: Double, offset: V2) -> [V2] {
        transform(poly.map { $0 - offset }, yaw: -yaw, offset: .zero)
    }
}

/// Where a home area came from: the LiDAR floor around the spawn point, a plain radius (floor not scanned yet), or a
/// room polygon from the snailsight server (only once the phone is localized in the site frame — P2 server loc).
public enum HomeSource: String, Codable, Equatable { case mesh, radius, room }

/// The home area an animal roams / paces in. Stored RELATIVE to its anchor (ground frame, anchor at the origin, anchor
/// yaw removed), so it follows the anchor wherever ARKit puts it after relocalization.
public struct HomeArea: Codable, Equatable {
    public var source: HomeSource
    public var name: String?
    public var polygon: [V2]

    public init(source: HomeSource, name: String? = nil, polygon: [V2]) {
        self.source = source; self.name = name; self.polygon = polygon
    }

    /// From a world (ground-frame) polygon and the anchor's ground position + yaw.
    public static func relative(_ world: [V2], source: HomeSource, name: String? = nil, anchor: V2, yaw: Double) -> HomeArea {
        HomeArea(source: source, name: name, polygon: Poly.untransform(world, yaw: yaw, offset: anchor))
    }

    /// Back to the world ground frame for an anchor at `anchor` with heading `yaw`.
    public func world(anchor: V2, yaw: Double) -> [V2] { Poly.transform(polygon, yaw: yaw, offset: anchor) }

    public var area: Double { Poly.area(polygon) }
}

/// Room bounds from the LiDAR floor (NavGrid built from the scene mesh around the spawn point).
public enum RoomBounds {
    /// The flood-fill grid is inflated by this much: openings narrower than twice it (interior doors, 0.76–0.91 m) are
    /// closed, so the fill stays in the room the animal was put in.
    public static let doorClose = 0.46
    /// Never further than this from the spawn point (a big open basement is still a "room" of this size).
    public static let maxRadius = 3.5
    /// Floor not scanned enough yet: a plain circle of this radius.
    public static let fallbackRadius = 1.5
    /// Smaller than this (m²) means the floor around the spawn point is not scanned: use the fallback.
    public static let minArea = 1.2

    /// Flood fill over non-hard cells from the cell under `spawn` (≤ maxRadius from it), convex hull of the reached cell
    /// centres. nil when the reached area is too small to mean anything.
    public static func fromGrid(_ g: NavGrid, spawn: V2, maxRadius: Double = maxRadius) -> [V2]? {
        guard let (si, sj) = g.spec.index(spawn) else { return nil }
        let nx = g.spec.nx, ny = g.spec.ny
        var seen = [Bool](repeating: false, count: nx * ny)
        var stack = [(si, sj)]
        var pts: [V2] = []
        seen[g.spec.flat(si, sj)] = true
        while let (i, j) = stack.popLast() {
            let c = g.spec.center(i, j)
            pts.append(c)
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ii = i + di, jj = j + dj
                guard ii >= 0, jj >= 0, ii < nx, jj < ny else { continue }
                let k = g.spec.flat(ii, jj)
                guard !seen[k], g.cells[k] != .hard,
                      SimMath.length(g.spec.center(ii, jj) - spawn) <= maxRadius else { continue }
                seen[k] = true
                stack.append((ii, jj))
            }
        }
        let hull = Poly.convexHull(pts)
        guard hull.count >= 3, Poly.area(hull) >= minArea else { return nil }
        return hull
    }

    /// The home polygon (world ground frame) for a spawn point: the room from the grid when there is one, else a
    /// fallback circle. Always contains the spawn point.
    public static func home(grid: NavGrid?, spawn: V2) -> (polygon: [V2], source: HomeSource) {
        if let g = grid, let p = fromGrid(g, spawn: spawn) {
            if Poly.contains(p, spawn) { return (p, .mesh) }
            // spawn on the hull edge (a cell centre exactly on it): include it explicitly
            let h = Poly.convexHull(p + [spawn])
            if h.count >= 3 { return (h, .mesh) }
        }
        return (Poly.circle(center: spawn, radius: fallbackRadius), .radius)
    }
}

/// The pacing loop: points on the home polygon pulled 35 % toward its centre (keeps clear of the walls and furniture
/// along them), evenly spaced, starting at the point nearest the animal and going counter-clockwise.
public enum RoomPatrol {
    public static func loop(home: [V2], from p: V2, count: Int = 6, inset: Double = 0.65) -> [V2] {
        guard home.count >= 3 else { return [] }
        let ccw = Poly.signedArea(home) >= 0 ? home : home.reversed()
        var pts = Poly.resample(Poly.scaled(ccw, factor: inset), count: max(3, count))
        if pts.count < 3 { pts = Poly.scaled(ccw, factor: inset) }
        guard let k = pts.indices.min(by: { SimMath.length(pts[$0] - p) < SimMath.length(pts[$1] - p) }) else { return [] }
        return Array(pts[k...] + pts[..<k])
    }
}
