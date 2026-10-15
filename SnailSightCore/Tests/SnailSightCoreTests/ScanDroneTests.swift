import XCTest
import simd
@testable import SnailSightCore

/// 9.8 Scans drone mode: joysticks → velocity, smooth acceleration, collision (sweep / push-out / slide), glides,
/// floor levels, floor plan raster, screen projection.
final class ScanDroneTests: XCTestCase {
    /// A wall: the plane z = `z` (x, y in −5 … 5), two triangles.
    func wall(z: Float) -> TriangleIndex {
        TriangleIndex(positions: [SIMD3(-5, -5, z), SIMD3(5, -5, z), SIMD3(5, 5, z), SIMD3(-5, 5, z)],
                      indices: [0, 1, 2, 0, 2, 3], cell: 0.5)
    }

    /// Horizontal quad (two triangles) at height y covering x0…x1, z0…z1, appended to a soup.
    func quad(_ pos: inout [SIMD3<Float>], _ idx: inout [UInt32], y: Float, x0: Float, x1: Float, z0: Float, z1: Float) {
        let b = UInt32(pos.count)
        pos += [SIMD3(x0, y, z0), SIMD3(x1, y, z0), SIMD3(x1, y, z1), SIMD3(x0, y, z1)]
        idx += [b, b + 1, b + 2, b, b + 2, b + 3]
    }

    func testJoystick() {
        XCTAssertEqual(Joystick.vector(dx: 3, dy: 0, radius: 60), .zero)                  // dead zone
        let r = Joystick.vector(dx: 60, dy: 0, radius: 60)
        XCTAssertEqual(r.x, 1, accuracy: 1e-5); XCTAssertEqual(r.y, 0, accuracy: 1e-6)
        let up = Joystick.vector(dx: 0, dy: -60, radius: 60)                              // drag up = forward
        XCTAssertEqual(up.y, 1, accuracy: 1e-5)
        let far = Joystick.vector(dx: 300, dy: 300, radius: 60)                           // clamped to the rim
        XCTAssertEqual(simd_length(far), 1, accuracy: 1e-5)
        XCTAssertGreaterThan(far.x, 0); XCTAssertLessThan(far.y, 0)
        let half = Joystick.vector(dx: 30, dy: 0, radius: 60)                             // expo: gentle near centre
        XCTAssertLessThan(half.x, 0.5); XCTAssertGreaterThan(half.x, 0.1)
        XCTAssertEqual(simd_length(Joystick.knob(dx: 120, dy: 0, radius: 60)), 60, accuracy: 1e-4)
        XCTAssertEqual(Joystick.knob(dx: 10, dy: 5, radius: 60), SIMD2(10, 5))
        XCTAssertEqual(Joystick.vector(dx: .nan, dy: 0, radius: 60), .zero)
    }

    func testTargetVelocity() {
        var p = DroneParams(); p.maxSpeed = 2
        let f = DroneMath.targetVelocity(DroneInput(move: SIMD2(0, 1)), yaw: 0, params: p)
        XCTAssertEqual(f.z, -2, accuracy: 1e-5); XCTAssertEqual(f.x, 0, accuracy: 1e-5)  // yaw 0 = looking along −Z
        let s = DroneMath.targetVelocity(DroneInput(move: SIMD2(1, 0)), yaw: 0, params: p)
        XCTAssertEqual(s.x, 2, accuracy: 1e-5)                                            // strafe right = +X
        let turned = DroneMath.targetVelocity(DroneInput(move: SIMD2(0, 1)), yaw: -.pi / 2, params: p)
        XCTAssertEqual(turned.x, 2, accuracy: 1e-5)                                       // turned right, forward = +X
        let c = DroneMath.targetVelocity(DroneInput(climb: 1), yaw: 0, params: p)
        XCTAssertEqual(c.y, 2 * p.verticalFactor, accuracy: 1e-5)
        let diag = DroneMath.targetVelocity(DroneInput(move: SIMD2(1, 1)), yaw: 0, params: p)
        XCTAssertEqual(simd_length(diag), 2, accuracy: 1e-4)                              // diagonal not faster
    }

    func testSmoothAccelerationAndStop() {
        let p = DroneParams()
        var s = DroneState(camera: WalkCamera(eye: .zero))
        let fwd = DroneInput(move: SIMD2(0, 1))
        s = DroneMath.step(s, fwd, dt: 1.0 / 60, params: p)
        XCTAssertGreaterThan(simd_length(s.velocity), 0)
        XCTAssertLessThan(simd_length(s.velocity), p.maxSpeed * 0.2)                     // no instant jump
        for _ in 0..<120 { s = DroneMath.step(s, fwd, dt: 1.0 / 60, params: p) }
        XCTAssertEqual(simd_length(s.velocity), p.maxSpeed, accuracy: 0.01)              // cruise after 2 s
        XCTAssertLessThan(s.camera.eye.z, -1.5)
        for _ in 0..<60 { s = DroneMath.step(s, DroneInput(), dt: 1.0 / 60, params: p) }
        XCTAssertEqual(s.velocity, .zero)                                                  // stopped within 1 s
        // a 2 s hitch is clamped to one 0.1 s step
        let z0 = s.camera.eye.z
        var h = s; h.velocity = SIMD3(0, 0, -1)
        h = DroneMath.step(h, fwd, dt: 2, params: p)
        XCTAssertGreaterThan(h.camera.eye.z, z0 - 0.2)
        // look: right stick right turns right (yaw decreases), up looks up, pitch clamped
        var l = DroneState(camera: WalkCamera(eye: .zero))
        l = DroneMath.step(l, DroneInput(look: SIMD2(1, 1)), dt: 0.1, params: p)
        XCTAssertLessThan(l.camera.yaw, 0); XCTAssertGreaterThan(l.camera.pitch, 0)
        for _ in 0..<100 { l = DroneMath.step(l, DroneInput(look: SIMD2(0, 1)), dt: 0.1, params: p) }
        XCTAssertEqual(l.camera.pitch, 1.2, accuracy: 1e-5)
    }

    func testCollisionStopsAtWallAndSlides() {
        let w = wall(z: -1)
        var p = DroneParams(); p.maxSpeed = 3
        let collider: (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float> = { w.sweep(from: $0, to: $1, radius: p.radius) }
        var s = DroneState(camera: WalkCamera(eye: SIMD3(0, 1, 0)))
        for _ in 0..<180 { s = DroneMath.step(s, DroneInput(move: SIMD2(0, 1)), dt: 1.0 / 60, params: p, collider: collider) }
        XCTAssertGreaterThanOrEqual(s.camera.eye.z, -1 + p.radius - 0.01)               // never through the wall
        XCTAssertLessThan(s.camera.eye.z, -1 + p.radius + 0.05)                          // but right up to it
        XCTAssertLessThan(simd_length(s.velocity), 0.1)                                   // no build-up into it
        // diagonal into the wall: slides sideways along it
        let x0 = s.camera.eye.x
        for _ in 0..<60 { s = DroneMath.step(s, DroneInput(move: SIMD2(1, 1)), dt: 1.0 / 60, params: p, collider: collider) }
        XCTAssertGreaterThan(s.camera.eye.x, x0 + 0.5)
        XCTAssertGreaterThanOrEqual(s.camera.eye.z, -1 + p.radius - 0.01)
        // collision off: straight through
        p.collide = false
        var g = DroneState(camera: WalkCamera(eye: SIMD3(0, 1, 0)))
        for _ in 0..<180 { g = DroneMath.step(g, DroneInput(move: SIMD2(0, 1)), dt: 1.0 / 60, params: p, collider: collider) }
        XCTAssertLessThan(g.camera.eye.z, -2)
    }

    func testSweepTunnellingAndPushOut() {
        let w = wall(z: -1)
        // one huge step straight through: stops in front
        let e = w.sweep(from: SIMD3(0, 0, 0), to: SIMD3(0, 0, -10), radius: 0.2)
        XCTAssertEqual(e.z, -0.8, accuracy: 0.01)
        // already penetrating: pushed out to the radius
        let q = w.pushOut(SIMD3(0.3, -0.5, -0.9), radius: 0.2)          // well away from the quad's diagonal edge
        XCTAssertEqual(q.z, -0.8, accuracy: 1e-3); XCTAssertEqual(q.x, 0.3, accuracy: 1e-4)
        // far away: untouched
        XCTAssertEqual(w.pushOut(SIMD3(0, 0, 3), radius: 0.2), SIMD3(0, 0, 3))
        // free move: unchanged
        XCTAssertEqual(w.sweep(from: SIMD3(0, 0, 2), to: SIMD3(1, 0, 2), radius: 0.2), SIMD3(1, 0, 2))
    }

    func testClosestPointOnTriangle() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(1, 0, 0), c = SIMD3<Float>(0, 1, 0)
        let f = TriangleIndex.closestPoint(SIMD3(0.2, 0.2, 1), a, b, c)                                // face
        XCTAssertEqual(f.x, 0.2, accuracy: 1e-6); XCTAssertEqual(f.y, 0.2, accuracy: 1e-6); XCTAssertEqual(f.z, 0, accuracy: 1e-6)
        XCTAssertEqual(TriangleIndex.closestPoint(SIMD3(-1, -1, 0), a, b, c), a)                      // vertex
        let e = TriangleIndex.closestPoint(SIMD3(0.5, -1, 0), a, b, c)                                 // edge ab
        XCTAssertEqual(e.x, 0.5, accuracy: 1e-6); XCTAssertEqual(e.y, 0, accuracy: 1e-6)
        let h = TriangleIndex.closestPoint(SIMD3(1, 1, 0), a, b, c)                                    // edge bc
        XCTAssertEqual(h.x, 0.5, accuracy: 1e-6); XCTAssertEqual(h.y, 0.5, accuracy: 1e-6)
    }

    func testGlides() {
        let a = WalkCamera(eye: .zero, yaw: 3.0), b = WalkCamera(eye: SIMD3(6, 0, 0), yaw: -3.0)
        let g = DroneGlide(from: a, to: b, speed: 3)
        XCTAssertEqual(g.duration, 2, accuracy: 1e-5)
        XCTAssertEqual(g.pose(at: 0), a)
        XCTAssertEqual(g.pose(at: g.duration).eye, b.eye)
        XCTAssertTrue(g.done(at: 2.1))
        let mid = g.pose(at: 1)
        XCTAssertEqual(mid.eye.x, 3, accuracy: 1e-4)
        XCTAssertGreaterThan(mid.yaw, 3.0)                                       // through π, not back through 0
        XCTAssertEqual(DroneGlide.shortestAngle(3.0, -3.0), 2 * .pi - 6, accuracy: 1e-5)
        XCTAssertEqual(DroneGlide(from: a, to: a).duration, 0.35, accuracy: 1e-6)
        XCTAssertEqual(DroneGlide(from: a, to: WalkCamera(eye: SIMD3(100, 0, 0))).duration, 2.5, accuracy: 1e-6)
        // jump-to-label viewpoint: 1.6 m away on the eye's side, looking at it
        let t = SIMD3<Float>(2, 1, -3)
        let v = DroneGlide.viewpoint(looking: t, from: SIMD3(2, 1.5, 5))
        XCTAssertEqual(v.eye.z, -3 + 1.6, accuracy: 1e-4)
        let dir = simd_normalize(t - v.eye)
        XCTAssertGreaterThan(simd_dot(dir, v.forward), 0.999)
    }

    func testLevels() {
        var pos: [SIMD3<Float>] = [], idx: [UInt32] = []
        quad(&pos, &idx, y: 0, x0: 0, x1: 8, z0: 0, z1: 8)             // ground floor
        quad(&pos, &idx, y: 2.8, x0: 0, x1: 8, z0: 0, z1: 6)           // upstairs
        quad(&pos, &idx, y: -2.6, x0: 0, x1: 5, z0: 0, z1: 5)          // basement
        quad(&pos, &idx, y: 0.75, x0: 1, x1: 3, z0: 1, z1: 2)          // a table: not a level
        quad(&pos, &idx, y: 5.3, x0: 0, x1: 0.5, z0: 0, z1: 0.5)       // a tiny shelf: too small
        let lv = ScanLevels.detect(positions: pos, indices: idx)
        XCTAssertEqual(lv.count, 3)
        XCTAssertEqual(lv[0], -2.6, accuracy: 0.05); XCTAssertEqual(lv[1], 0, accuracy: 0.05); XCTAssertEqual(lv[2], 2.8, accuracy: 0.05)
        XCTAssertEqual(ScanLevels.names(lv, mainY: 0.02), ["Basement", "Ground floor", "Floor 2"])
        XCTAssertEqual(ScanLevels.index(of: 1.5, floors: lv), 1)
        XCTAssertEqual(ScanLevels.index(of: 4, floors: lv), 2)
        XCTAssertEqual(ScanLevels.index(of: -9, floors: lv), 0)
        XCTAssertTrue(ScanLevels.detect(positions: [], indices: []).isEmpty)
    }

    func testFloorPlan() throws {
        var pos: [SIMD3<Float>] = [], idx: [UInt32] = []
        quad(&pos, &idx, y: 0, x0: 0, x1: 4, z0: 0, z1: 4)
        // a wall along x = 4 (vertical, 0 … 2.4 m)
        let b = UInt32(pos.count)
        pos += [SIMD3(4, 0, 0), SIMD3(4, 0, 4), SIMD3(4, 2.4, 4), SIMD3(4, 2.4, 0)]
        idx += [b, b + 1, b + 2, b, b + 2, b + 3]
        quad(&pos, &idx, y: 0.8, x0: 1, x1: 2, z0: 1, z1: 2)           // table top = furniture
        quad(&pos, &idx, y: 2.8, x0: 0, x1: 4, z0: 0, z1: 4)           // the floor above: not in this slice
        let fp = try XCTUnwrap(FloorPlan.build(positions: pos, indices: idx, floorY: 0, metersPerPixel: 0.05))
        func at(_ x: Float, _ z: Float) -> FloorPlan.Cell {
            let p = fp.pixel(SIMD3(x, 0, z))
            return fp.cell(Int(p.x), Int(p.y))
        }
        XCTAssertEqual(at(3, 3), .floor)
        XCTAssertEqual(at(1.5, 1.5), .furniture)
        XCTAssertEqual(at(4.0, 2), .wall)
        XCTAssertEqual(at(-0.3, 2), .empty)                             // margin
        let w = fp.world(fp.pixel(SIMD3(1.23, 0, 2.5)), y: 0)
        XCTAssertEqual(w.x, 1.23, accuracy: 1e-4); XCTAssertEqual(w.z, 2.5, accuracy: 1e-4)
        // map (x, y) → viewer (x, −y): map y = −2.5 is viewer z = 2.5
        XCTAssertEqual(fp.pixel(mapX: 1.23, mapY: -2.5), fp.pixel(SIMD3(1.23, 0, 2.5)))
        let m = fp.map(fp.pixel(mapX: 1.0, mapY: -3.0))
        XCTAssertEqual(m.x, 1.0, accuracy: 1e-4); XCTAssertEqual(m.y, -3.0, accuracy: 1e-4)
        XCTAssertEqual(fp.rgba().count, fp.width * fp.height * 4)
        // a big plan is capped at maxSide pixels
        var bp: [SIMD3<Float>] = [], bi: [UInt32] = []
        quad(&bp, &bi, y: 0, x0: 0, x1: 200, z0: 0, z1: 10)
        let big = try XCTUnwrap(FloorPlan.build(positions: bp, indices: bi, floorY: 0, maxSide: 512))
        XCTAssertLessThanOrEqual(big.width, 512)
        XCTAssertNil(FloorPlan.build(positions: bp, indices: bi, floorY: 50))
        // heading arrow: yaw 0 looks along −z = up on the plan (row decreases)
        XCTAssertEqual(PlanHeading.direction(yaw: 0).y, -1, accuracy: 1e-6)
    }

    func testProjectionRoundTrip() throws {
        let size = SIMD2<Float>(390, 844), eye = SIMD3<Float>(1, 1.5, 2), fwd = simd_normalize(SIMD3<Float>(0.3, -0.2, -1))
        let fovy: Float = 60 * .pi / 180
        for p in [SIMD2<Float>(195, 422), SIMD2<Float>(10, 30), SIMD2<Float>(380, 800)] {
            let r = CameraMath.ray(screen: p, size: size, eye: eye, forward: fwd, fovy: fovy)
            let w = r.origin + r.dir * 4
            let pr = try XCTUnwrap(ScreenProjection.project(w, size: size, eye: eye, forward: fwd, fovy: fovy))
            XCTAssertEqual(pr.screen.x, p.x, accuracy: 0.05); XCTAssertEqual(pr.screen.y, p.y, accuracy: 0.05)
        }
        XCTAssertNil(ScreenProjection.project(eye - fwd, size: size, eye: eye, forward: fwd, fovy: fovy))   // behind
        let f10: SIMD3<Float> = fwd * 10, f2: SIMD3<Float> = fwd * 2, f40: SIMD3<Float> = fwd * 40
        let pts: [SIMD3<Float>] = [eye + f10, eye + f2, eye - f2, eye + f40]
        let vis = ScreenProjection.visible(pts, size: size, eye: eye, forward: fwd, fovy: fovy, maxDistance: 25)
        XCTAssertEqual(vis.map { $0.index }, [1, 0])                                       // nearest first; behind / far out
        XCTAssertEqual(ScreenProjection.visible(pts, size: size, eye: eye, forward: fwd, fovy: fovy, maxCount: 1).count, 1)
    }
}
