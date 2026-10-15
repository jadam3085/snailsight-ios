import Foundation
import simd

// 9.8 Scans "Drone" mode (owner 2026-10-13: "the same kind of drone mode to explore the scans" as the web viewer's Fly,
// §8.7/§8.8): virtual dual joysticks (left = move/strafe, right = look) + altitude, speed slider, smooth acceleration,
// gravity-off flight, collision with the mesh (a 20 cm sphere swept against the triangles, as `surface.js` does),
// glides for walk-point jumps / return home / jump-to-label, floor levels and the top-down minimap.
// Pure maths (tested on CI). Viewer frame = Y-up metres (map (x, y, z) → (x, z, −y)).

/// A virtual thumb-stick: knob offset (points, x right, y down) → stick vector (x right, y forward/up), dead zone,
/// radial clamp and an expo curve (fine control near the centre, full speed at the rim).
public enum Joystick {
    public static func vector(dx: Float, dy: Float, radius: Float, deadZone: Float = 0.12, expo: Float = 0.45) -> SIMD2<Float> {
        guard radius > 0, dx.isFinite, dy.isFinite else { return .zero }
        let v = SIMD2<Float>(dx, -dy) / radius
        let m = simd_length(v)
        guard m > deadZone, m > 0 else { return .zero }
        let n = (min(m, 1) - deadZone) / (1 - deadZone)
        let curved = (1 - expo) * n + expo * n * n * n
        return v / m * curved
    }

    /// Knob position for drawing: the finger offset clamped to the pad radius.
    public static func knob(dx: Float, dy: Float, radius: Float) -> SIMD2<Float> {
        let v = SIMD2<Float>(dx, dy)
        let m = simd_length(v)
        return m > radius && m > 0 ? v / m * radius : v
    }
}

/// 9.9 (owner on 9.8.91: "I liked the older minimalist fly control"): Scans → Fly has two control schemes.
/// Minimal (default, the 9.6 walk / web viewer Fly): ONE stick (move + strafe), drag anywhere on the scan to look,
/// ▲▼ for height, pinch / two fingers still move. Advanced: the 9.8 dual-stick drone (move stick + look stick).
public enum FlyScheme: String, CaseIterable, Identifiable {
    case minimal, advanced
    public var id: String { rawValue }
    public var title: String { self == .minimal ? "Simple" : "Advanced" }
}

public enum FlyControl {
    /// Speed presets of the minimal scheme's single speed button (m/s), cycled by taps.
    public static let speedSteps: [Float] = [0.5, 1.2, 2.5, 5]

    public static func nextSpeed(after s: Float) -> Float {
        speedSteps.first { $0 > s + 1e-3 } ?? speedSteps[0]
    }

    /// Stick + height buttons (+ look stick in Advanced) → drone input. The minimal scheme has no look stick: looking
    /// is the drag gesture on the scan (it turns the camera directly), so a stray look value is ignored.
    public static func input(_ scheme: FlyScheme, move: SIMD2<Float>, look: SIMD2<Float>, climb: Float) -> DroneInput {
        DroneInput(move: move, look: scheme == .advanced ? look : .zero, climb: max(-1, min(1, climb)))
    }
}

public struct DroneParams: Equatable {
    public var maxSpeed: Float = 1.2          // m/s (slider 0.2 … 6, like the web viewer's wheel speed)
    public var verticalFactor: Float = 0.6    // climb speed = maxSpeed × this
    public var accelTau: Float = 0.25         // s, time constant speeding up
    public var brakeTau: Float = 0.15         // s, slowing down (stops feel crisp)
    public var yawRate: Float = 1.9           // rad/s at full right stick
    public var pitchRate: Float = 1.2
    public var radius: Float = 0.2            // collision sphere (web viewer: 20 cm)
    public var collide = true
    public static let speedRange: ClosedRange<Float> = 0.2...6
    public init() {}
}

public struct DroneInput: Equatable {
    public var move: SIMD2<Float>             // left stick: x strafe right, y forward
    public var look: SIMD2<Float>             // right stick: x turn right, y look up
    public var climb: Float                   // −1 … 1 (altitude buttons)
    public init(move: SIMD2<Float> = .zero, look: SIMD2<Float> = .zero, climb: Float = 0) {
        self.move = move; self.look = look; self.climb = climb
    }
    public var isIdle: Bool { move == .zero && look == .zero && climb == 0 }
}

public struct DroneState: Equatable {
    public var camera: WalkCamera             // eye / yaw / pitch (pitch positive = up)
    public var velocity: SIMD3<Float> = .zero
    public init(camera: WalkCamera, velocity: SIMD3<Float> = .zero) { self.camera = camera; self.velocity = velocity }
}

public enum DroneMath {
    /// World velocity the sticks ask for: horizontal along the heading (pitch ignored = a drone, not a plane).
    public static func targetVelocity(_ input: DroneInput, yaw: Float, params p: DroneParams) -> SIMD3<Float> {
        let h = SIMD3<Float>(-sinf(yaw), 0, -cosf(yaw))
        let r = SIMD3<Float>(cosf(yaw), 0, -sinf(yaw))
        var m = input.move
        let ml = simd_length(m)
        if ml > 1 { m /= ml }
        var v = (h * m.y + r * m.x) * p.maxSpeed
        v.y = max(-1, min(1, input.climb)) * p.maxSpeed * p.verticalFactor
        return v
    }

    /// Exponential approach (frame-rate independent): v → target with time constant tau.
    public static func approach(_ v: SIMD3<Float>, _ target: SIMD3<Float>, dt: Float, tau: Float) -> SIMD3<Float> {
        guard tau > 1e-4 else { return target }
        return v + (target - v) * (1 - expf(-dt / tau))
    }

    /// One frame. `collider(from, to)` returns where the eye may go (nil = fly through walls).
    public static func step(_ s: DroneState, _ input: DroneInput, dt rawDt: Float, params p: DroneParams,
                            collider: ((SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>)? = nil) -> DroneState {
        let dt = max(0, min(rawDt, 0.1))                    // a hitch never teleports the drone
        var out = s
        out.camera.yaw -= input.look.x * p.yawRate * dt
        out.camera.pitch = max(-1.2, min(1.2, out.camera.pitch + input.look.y * p.pitchRate * dt))
        let target = targetVelocity(input, yaw: out.camera.yaw, params: p)
        let tau = simd_length(target) >= simd_length(s.velocity) ? p.accelTau : p.brakeTau
        var v = approach(s.velocity, target, dt: dt, tau: tau)
        if target == .zero && simd_length(v) < 0.01 { v = .zero }
        let want = s.camera.eye + v * dt
        var got = want
        if p.collide, let c = collider, simd_distance(want, s.camera.eye) > 1e-6 { got = c(s.camera.eye, want) }
        if dt > 0, simd_distance(got, want) > 1e-5 {
            // blocked: keep only the velocity that actually happened (slide along the wall, no build-up into it)
            var real = (got - s.camera.eye) / dt
            let rl = simd_length(real), vl = simd_length(v)
            if rl > vl, rl > 0 { real *= vl / rl }
            v = real
        }
        out.camera.eye = got
        out.velocity = v
        return out
    }
}

// MARK: collision (sphere vs the mesh's triangles)

public extension TriangleIndex {
    /// Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
    static func closestPoint(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let den = va + vb + vc
        guard abs(den) > 1e-20 else { return a }
        let v = vb / den, w = vc / den
        return a + ab * v + ac * w
    }

    /// Push a sphere out of every triangle it penetrates (a few relaxation passes). Returns the new centre.
    func pushOut(_ center: SIMD3<Float>, radius r: Float, iterations: Int = 3) -> SIMD3<Float> {
        guard triangleCount > 0, center.x.isFinite, center.y.isFinite, center.z.isFinite else { return center }
        var c = center
        for _ in 0..<iterations {
            var i0 = SIMD3<Int32>(0, 0, 0), i1 = SIMD3<Int32>(0, 0, 0)
            for k in 0..<3 {
                let a = Int32(floorf((c[k] - r - lo[k]) / cell)), b = Int32(floorf((c[k] + r - lo[k]) / cell))
                i0[k] = max(0, a); i1[k] = min(dims[k] - 1, b)
                if i0[k] > i1[k] { return c }
            }
            var seen = Set<Int32>()
            var moved = false
            for z in i0.z...i1.z { for y in i0.y...i1.y { for x in i0.x...i1.x {
                let ci = Int((z * dims.y + y) * dims.x + x)
                for j in Int(cellStart[ci])..<Int(cellStart[ci + 1]) {
                    let t = cellTris[j]
                    if !seen.insert(t).inserted { continue }
                    let ti = Int(t)
                    let a = positions[Int(indices[ti * 3])], b = positions[Int(indices[ti * 3 + 1])], cc = positions[Int(indices[ti * 3 + 2])]
                    let q = Self.closestPoint(c, a, b, cc)
                    let d = c - q
                    let dd = simd_length(d)
                    guard dd < r, dd > 1e-6 else { continue }
                    c += d * ((r - dd) / dd)
                    moved = true
                }
            } } }
            if !moved { break }
        }
        return c
    }

    /// Move a sphere from `from` toward `to` without passing through the surface: stop `r` before a hit, slide along
    /// it, then push out (the web viewer's `SurfaceIndex.sweep`).
    func sweep(from: SIMD3<Float>, to: SIMD3<Float>, radius r: Float) -> SIMD3<Float> {
        guard from.x.isFinite, from.y.isFinite, from.z.isFinite, to.x.isFinite, to.y.isFinite, to.z.isFinite else { return from }
        var out = to
        let mv = to - from
        let len = simd_length(mv)
        if len > 1e-6 {
            let dir = mv / len
            if let hit = raycast(origin: from, dir: dir, maxT: len + r) {
                let allowed = max(0, min(len, hit.t - r))
                out = from + dir * allowed
                var rest = mv - dir * allowed
                rest -= hit.normal * simd_dot(rest, hit.normal)          // slide along the wall
                let rl = simd_length(rest)
                if rl > 1e-4 {
                    let rd = rest / rl
                    if let h2 = raycast(origin: out, dir: rd, maxT: rl + r) { out += rd * max(0, min(rl, h2.t - r)) }
                    else { out += rd * rl }
                }
            }
        }
        return pushOut(out, radius: r)
    }
}

// MARK: glides (walk-point jumps, return home, jump to a label)

public struct DroneGlide: Equatable {
    public var from: WalkCamera
    public var to: WalkCamera
    public var duration: Float

    /// Duration from the distance at `speed` m/s, kept within 0.35 … 2.5 s.
    public init(from: WalkCamera, to: WalkCamera, speed: Float = 3) {
        self.from = from; self.to = to
        let d = simd_distance(from.eye, to.eye)
        let turn = abs(Self.shortestAngle(from.yaw, to.yaw))
        duration = max(0.35, min(2.5, max(d / max(speed, 0.1), turn / 2.5)))
    }

    /// Signed angle from a to b in (−π, π].
    public static func shortestAngle(_ a: Float, _ b: Float) -> Float {
        var d = fmodf(b - a, 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d <= -.pi { d += 2 * .pi }
        return d
    }

    public func pose(at t: Float) -> WalkCamera {
        let s = max(0, min(1, duration > 0 ? t / duration : 1))
        let e = s * s * (3 - 2 * s)
        return WalkCamera(eye: from.eye + (to.eye - from.eye) * e,
                          yaw: from.yaw + Self.shortestAngle(from.yaw, to.yaw) * e,
                          pitch: from.pitch + (to.pitch - from.pitch) * e)
    }

    public func done(at t: Float) -> Bool { t >= duration }

    /// A pose looking at `target` from `standOff` metres away, approaching from the side the eye is on.
    public static func viewpoint(looking target: SIMD3<Float>, from eye: SIMD3<Float>, standOff: Float = 1.6,
                                 heightAbove: Float = 0.35) -> WalkCamera {
        var d = eye - target
        d.y = 0
        if simd_length(d) < 1e-3 { d = SIMD3(0, 0, 1) }
        d = simd_normalize(d)
        let e = SIMD3<Float>(target.x + d.x * standOff, target.y + heightAbove, target.z + d.z * standOff)
        let f = target - e
        let pitch = atan2f(f.y, max(1e-4, simd_length(SIMD2(f.x, f.z))))
        return WalkCamera(eye: e, yaw: WalkCamera.yaw(of: SIMD3(f.x, 0, f.z)), pitch: max(-1.2, min(1.2, pitch)))
    }
}

// MARK: floor levels

public enum ScanLevels {
    /// Floor heights (viewer Y) of the storeys in a mesh: area histogram (5 cm bins) of upward-facing triangles, peaks
    /// at least `minSeparation` apart (tables / beds at ~0.5–0.9 m never count as a level) and with at least
    /// `minFraction` of the biggest peak's area. Ascending.
    public static func detect(positions: [SIMD3<Float>], indices: [UInt32], bin: Float = 0.05,
                              minSeparation: Float = 1.9, minFraction: Float = 0.12) -> [Float] {
        let n = indices.count / 3
        guard n > 0 else { return [] }
        var lo = Float.infinity, hi = -Float.infinity
        for p in positions { lo = min(lo, p.y); hi = max(hi, p.y) }
        guard lo.isFinite, hi >= lo else { return [] }
        let nb = Int((hi - lo) / bin) + 1
        guard nb < 100_000 else { return [] }
        var hist = [Float](repeating: 0, count: nb)
        for t in 0..<n {
            let a = positions[Int(indices[t * 3])], b = positions[Int(indices[t * 3 + 1])], c = positions[Int(indices[t * 3 + 2])]
            let cr = simd_cross(b - a, c - a)
            let area2 = simd_length(cr)
            guard area2 > 1e-10, abs(cr.y) / area2 > 0.9 else { continue }     // horizontal (either side: open meshes)
            let y = (a.y + b.y + c.y) / 3
            hist[max(0, min(nb - 1, Int((y - lo) / bin)))] += area2 / 2
        }
        // triangular smoothing over ±2 bins (a floor is never perfectly flat; one clear maximum per floor)
        var sm = hist
        for i in 0..<nb {
            var s: Float = 0
            for j in max(0, i - 2)...min(nb - 1, i + 2) { s += hist[j] * Float(3 - abs(j - i)) }
            sm[i] = s
        }
        let order = (0..<nb).sorted { sm[$0] > sm[$1] }
        guard let top = order.first, sm[top] > 0 else { return [] }
        var picked: [Int] = []
        for i in order {
            if sm[i] < sm[top] * minFraction { break }
            if picked.contains(where: { abs(Float($0 - i)) * bin < minSeparation }) { continue }
            picked.append(i)
        }
        return picked.map { lo + (Float($0) + 0.5) * bin }.sorted()
    }

    /// The level whose floor is the highest one at or below `y` (+ 0.5 m slack), else the lowest.
    public static func index(of y: Float, floors: [Float]) -> Int? {
        guard !floors.isEmpty else { return nil }
        var best = 0
        for (i, f) in floors.enumerated() where f <= y + 0.5 { best = i }
        return best
    }

    /// "Ground floor" / "Basement" / "Floor 2" relative to the main floor (`mainY` = the scan's floor fit).
    public static func names(_ floors: [Float], mainY: Float?) -> [String] {
        guard !floors.isEmpty else { return [] }
        let m = mainY.flatMap { y in floors.indices.min(by: { abs(floors[$0] - y) < abs(floors[$1] - y) }) } ?? 0
        return floors.indices.map { i in
            let k = i - m
            switch k {
            case 0: return "Ground floor"
            case -1: return "Basement"
            case ..<(-1): return "Basement \(-k)"
            default: return "Floor \(k + 1)"
            }
        }
    }
}

// MARK: top-down floor plan (minimap + room editor backdrop)

public struct FloorPlan: Equatable, Sendable {
    public enum Cell: UInt8 { case empty = 0, floor = 1, wall = 2, furniture = 3 }
    public let width: Int
    public let height: Int
    public let minX: Float                    // viewer frame x of pixel column 0's left edge
    public let minZ: Float                    // viewer frame z of row 0's top edge (row grows with z = toward −map y)
    public let metersPerPixel: Float
    public let floorY: Float
    public var pixels: [UInt8]

    /// Pixel (column, row; fractional) of a viewer-frame point.
    public func pixel(_ p: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2((p.x - minX) / metersPerPixel, (p.z - minZ) / metersPerPixel)
    }
    /// Pixel of a map-frame (x, y) — room polygons.
    public func pixel(mapX x: Double, mapY y: Double) -> SIMD2<Float> { pixel(SIMD3(Float(x), 0, -Float(y))) }
    /// Viewer-frame point (at height `y`) under a pixel.
    public func world(_ px: SIMD2<Float>, y: Float) -> SIMD3<Float> {
        SIMD3(minX + px.x * metersPerPixel, y, minZ + px.y * metersPerPixel)
    }
    /// Map-frame (x, y) under a pixel.
    public func map(_ px: SIMD2<Float>) -> SIMD2<Double> {
        let w = world(px, y: 0)
        return SIMD2(Double(w.x), Double(-w.z))
    }
    public func cell(_ x: Int, _ y: Int) -> Cell {
        guard x >= 0, y >= 0, x < width, y < height else { return .empty }
        return Cell(rawValue: pixels[y * width + x]) ?? .empty
    }

    static func rank(_ v: UInt8) -> Int { [0, 1, 3, 2][Int(min(v, 3))] }      // empty < floor < furniture < wall

    /// Rasterise the slice of the mesh from `floorY − 0.25` to `floorY + band`: floor-height horizontals = floor,
    /// higher horizontals = furniture, steep faces between 0.3 m and 2 m above the floor = walls.
    public static func build(positions: [SIMD3<Float>], indices: [UInt32], floorY: Float, band: Float = 2.2,
                             metersPerPixel mpp0: Float = 0.05, maxSide: Int = 1024, margin: Float = 0.5) -> FloorPlan? {
        let n = indices.count / 3
        guard n > 0 else { return nil }
        let y0 = floorY - 0.25, y1 = floorY + band
        var lo = SIMD2<Float>(.infinity, .infinity), hi = SIMD2<Float>(-.infinity, -.infinity)
        var keep: [Int] = []
        keep.reserveCapacity(n / 2)
        for t in 0..<n {
            let a = positions[Int(indices[t * 3])], b = positions[Int(indices[t * 3 + 1])], c = positions[Int(indices[t * 3 + 2])]
            let cy = (a.y + b.y + c.y) / 3
            guard cy >= y0, cy <= y1 else { continue }
            keep.append(t)
            for p in [a, b, c] { lo = simd_min(lo, SIMD2(p.x, p.z)); hi = simd_max(hi, SIMD2(p.x, p.z)) }
        }
        guard !keep.isEmpty else { return nil }
        lo -= SIMD2(repeating: margin); hi += SIMD2(repeating: margin)
        let ext = hi - lo
        let mpp = max(mpp0, max(ext.x, ext.y) / Float(maxSide))
        let w = max(1, Int(ceilf(ext.x / mpp - 1e-3))), h = max(1, Int(ceilf(ext.y / mpp - 1e-3)))
        var px = [UInt8](repeating: 0, count: w * h)
        func put(_ x: Int, _ y: Int, _ v: UInt8) {
            guard x >= 0, y >= 0, x < w, y < h else { return }
            let i = y * w + x
            if rank(v) > rank(px[i]) { px[i] = v }
        }
        func toPx(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2((p.x - lo.x) / mpp, (p.z - lo.y) / mpp) }
        for t in keep {
            let a = positions[Int(indices[t * 3])], b = positions[Int(indices[t * 3 + 1])], c = positions[Int(indices[t * 3 + 2])]
            let cr = simd_cross(b - a, c - a)
            let l = simd_length(cr)
            guard l > 1e-12 else { continue }
            let ny = abs(cr.y) / l
            let cy = (a.y + b.y + c.y) / 3
            let v: UInt8
            if ny > 0.8 { v = cy < floorY + 0.25 ? Cell.floor.rawValue : Cell.furniture.rawValue }
            else if ny < 0.5 && max(a.y, max(b.y, c.y)) > floorY + 0.3 && min(a.y, min(b.y, c.y)) < floorY + 2.0 { v = Cell.wall.rawValue }
            else { continue }
            let pa = toPx(a), pb = toPx(b), pc = toPx(c)
            let mn = simd_min(pa, simd_min(pb, pc)), mx = simd_max(pa, simd_max(pb, pc))
            let x0 = Int(floorf(mn.x)), x1 = Int(floorf(mx.x)), r0 = Int(floorf(mn.y)), r1 = Int(floorf(mx.y))
            if v == Cell.wall.rawValue || (x1 - x0) * (r1 - r0) <= 1 {
                // a vertical face projects to a line: mark every pixel its 2D box covers (≤ a few px for cm triangles)
                if (x1 - x0 + 1) * (r1 - r0 + 1) <= 64 {
                    for yy in r0...r1 { for xx in x0...x1 { put(xx, yy, v) } }
                } else {
                    for (p, q) in [(pa, pb), (pb, pc), (pc, pa)] { line(p, q) { put($0, $1, v) } }
                }
                continue
            }
            let area = edge(pa, pb, pc)
            guard abs(area) > 1e-9 else { continue }
            for yy in r0...r1 { for xx in x0...x1 {
                let q = SIMD2<Float>(Float(xx) + 0.5, Float(yy) + 0.5)
                let w0 = edge(pb, pc, q), w1 = edge(pc, pa, q), w2 = edge(pa, pb, q)
                if area > 0 ? (w0 >= 0 && w1 >= 0 && w2 >= 0) : (w0 <= 0 && w1 <= 0 && w2 <= 0) { put(xx, yy, v) }
            } }
            let cen = (pa + pb + pc) / 3
            put(Int(cen.x), Int(cen.y), v)
        }
        return FloorPlan(width: w, height: h, minX: lo.x, minZ: lo.y, metersPerPixel: mpp, floorY: floorY, pixels: px)
    }

    static func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ p: SIMD2<Float>) -> Float {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    static func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ f: (Int, Int) -> Void) {
        let steps = Int(max(abs(b.x - a.x), abs(b.y - a.y))) + 1
        for i in 0...min(steps, 4096) {
            let t = Float(i) / Float(max(steps, 1))
            let p = a + (b - a) * t
            f(Int(floorf(p.x)), Int(floorf(p.y)))
        }
    }

    /// RGBA8 image (dark theme): empty transparent-dark, floor grey-blue, furniture mid grey, walls white.
    public func rgba() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let c: (UInt8, UInt8, UInt8, UInt8)
            switch pixels[i] {
            case 1: c = (58, 72, 92, 255)
            case 2: c = (235, 238, 245, 255)
            case 3: c = (120, 128, 140, 255)
            default: c = (14, 16, 20, 200)
            }
            out[i * 4] = c.0; out[i * 4 + 1] = c.1; out[i * 4 + 2] = c.2; out[i * 4 + 3] = c.3
        }
        return out
    }
}

/// Minimap heading arrow: the eye's forward on the plan (row grows with viewer z).
public enum PlanHeading {
    /// Unit 2D direction in plan pixels for a walk yaw.
    public static func direction(yaw: Float) -> SIMD2<Float> { SIMD2(-sinf(yaw), -cosf(yaw)) }
}

// MARK: screen projection (label billboards drawn as a 2D overlay over Mesh, Splat and Hybrid alike)

public enum ScreenProjection {
    /// Inverse of `CameraMath.ray`: screen point (points, top-left origin) and depth along `forward`, nil when the
    /// point is behind the camera or nearer than `near`.
    public static func project(_ p: SIMD3<Float>, size: SIMD2<Float>, eye: SIMD3<Float>, forward: SIMD3<Float>,
                               fovy: Float, near: Float = 0.05) -> (screen: SIMD2<Float>, depth: Float)? {
        let f = simd_normalize(forward)
        var r = simd_cross(f, SIMD3(0, 1, 0))
        if simd_length(r) < 1e-6 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        let d = p - eye
        let z = simd_dot(d, f)
        guard z > near, size.x > 0, size.y > 0 else { return nil }
        let th = tanf(fovy / 2), aspect = size.x / size.y
        let nx = simd_dot(d, r) / (z * th * aspect), ny = simd_dot(d, u) / (z * th)
        return (SIMD2((nx + 1) / 2 * size.x, (1 - ny) / 2 * size.y), z)
    }

    /// Which labels to draw: in front, within `maxDistance`, on (or a margin off) screen, nearest `maxCount` first.
    public static func visible(_ points: [SIMD3<Float>], size: SIMD2<Float>, eye: SIMD3<Float>, forward: SIMD3<Float>,
                               fovy: Float, maxDistance: Float = 25, maxCount: Int = 40, margin: Float = 40)
        -> [(index: Int, screen: SIMD2<Float>, distance: Float)] {
        var out: [(index: Int, screen: SIMD2<Float>, distance: Float)] = []
        for (i, p) in points.enumerated() {
            let dist = simd_distance(p, eye)
            guard dist <= maxDistance, let pr = project(p, size: size, eye: eye, forward: forward, fovy: fovy) else { continue }
            let s = pr.screen
            guard s.x >= -margin, s.y >= -margin, s.x <= size.x + margin, s.y <= size.y + margin else { continue }
            out.append((i, s, dist))
        }
        out.sort { $0.distance < $1.distance }
        return Array(out.prefix(maxCount))
    }
}
