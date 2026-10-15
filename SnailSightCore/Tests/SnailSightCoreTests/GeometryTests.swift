import XCTest
import simd
@testable import SnailSightCore

final class GeometryTests: XCTestCase {
    func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), tol, "\(a) != \(b)", file: file, line: line)
    }

    func pose(position p: SIMD3<Float>, normal n: SIMD3<Float>) -> simd_float4x4 {
        // Build a hit-like transform whose +Y is n.
        let y = simd_normalize(n)
        let ref: SIMD3<Float> = abs(y.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)
        let x = simd_normalize(simd_cross(y, simd_cross(ref, y)))
        let z = simd_cross(x, y)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(p, 1))
    }

    func testCentimetresFormatting() {
        XCTAssertEqual(Geo.centimetres(1.0), "100.0 cm")
        XCTAssertEqual(Geo.centimetres(0.1234), "12.3 cm")
        XCTAssertEqual(Geo.centimetres(0), "0.0 cm")
    }

    func testDistanceOneMetreDiagonal() {
        let a = SIMD3<Float>(0.2, 0.0, -1.0)
        let b = a + simd_normalize(SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(Geo.distance(a, b), 1.0, accuracy: 1e-5)
    }

    func testAngle() {
        XCTAssertEqual(Geo.angleDegrees(SIMD3(1, 0, 0), SIMD3(0, 1, 0)), 90, accuracy: 1e-3)
        XCTAssertEqual(Geo.angleDegrees(SIMD3(0, 1, 0), SIMD3(0, 2, 0)), 0, accuracy: 1e-2)
        XCTAssertEqual(Geo.angleDegrees(SIMD3(0, 0, 0), SIMD3(0, 1, 0)), 0)
    }

    func testProjectOntoPlane() {
        approx(Geo.projectOntoPlane(SIMD3(1, 2, 3), normal: SIMD3(0, 5, 0)), SIMD3(1, 0, 3))
    }

    func testPlacementOnFloorIsGravityAlignedAndFacesCamera() {
        // Slightly tilted floor normal (5°) must still give an exactly-upright cube.
        let n = simd_normalize(SIMD3<Float>(sin(5 * .pi / 180), cos(5 * .pi / 180), 0))
        let hit = pose(position: SIMD3(1, -1.4, -2), normal: n)
        let cam = SIMD3<Float>(1, 0, 0)        // camera 2 m "behind" the hit along +Z, 1.4 m up
        let m = Geo.placementTransform(hit: hit, cameraPosition: cam)
        approx(Geo.position(m), SIMD3(1, -1.4, -2))
        approx(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(0, 1, 0))
        approx(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z), SIMD3(0, 0, 1))   // +Z toward camera
        XCTAssertTrue(Geo.isRigid(m))
    }

    func testPlacementOnWallKeepsHitPose() {
        let hit = pose(position: SIMD3(0, 1, -3), normal: SIMD3(0, 0, 1))
        let m = Geo.placementTransform(hit: hit, cameraPosition: .zero)
        XCTAssertEqual(m, hit)
    }

    func testPlacementCameraDirectlyAbove() {
        let hit = pose(position: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0))
        let m = Geo.placementTransform(hit: hit, cameraPosition: SIMD3(0, 1.5, 0))
        XCTAssertTrue(Geo.isRigid(m))
        approx(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(0, 1, 0))
    }

    func testRulerFrameAlongProjectedForward() {
        // Camera looks down-forward (-Z, tilted 45° down) at the floor.
        let fwd = simd_normalize(SIMD3<Float>(0, -1, -1))
        let f = Geo.rulerFrame(origin: SIMD3(0, -1.4, -1), normal: SIMD3(0, 1, 0), cameraForward: fwd)!
        approx(SIMD3(f.columns.0.x, f.columns.0.y, f.columns.0.z), SIMD3(0, 0, -1))
        XCTAssertTrue(Geo.isRigid(f))
        // 1 m along +X of the frame lands 1 m further from the user on the floor.
        let end = f * SIMD4<Float>(1, 0, 0, 1)
        approx(SIMD3(end.x, end.y, end.z), SIMD3(0, -1.4, -2))
    }

    func testRulerFrameNilWhenLookingAlongNormal() {
        XCTAssertNil(Geo.rulerFrame(origin: .zero, normal: SIMD3(0, 1, 0), cameraForward: SIMD3(0, -1, 0)))
    }

    func testSegmentSpansEndpoints() {
        for (a, b) in [(SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)),
                       (SIMD3<Float>(1, 2, 3), SIMD3<Float>(-1, 2.5, 0)),
                       (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 0))] {   // antiparallel to +X
            let s = Geo.segment(from: a, to: b)
            XCTAssertEqual(s.length, simd_distance(a, b), accuracy: 1e-5)
            let half = s.rotation.act(SIMD3<Float>(s.length / 2, 0, 0))
            approx(s.center + half, b)
            approx(s.center - half, a)
        }
    }

    func testTicksEveryTenCentimetresOnOneMetre() {
        let t = Geo.ticks(length: 1.0, spacing: 0.1)
        XCTAssertEqual(t.count, 11)
        XCTAssertEqual(t.first, 0)
        XCTAssertEqual(t.last!, 1.0, accuracy: 1e-5)
        XCTAssertEqual(Geo.ticks(length: 0.25, spacing: 0.1).count, 3)
        XCTAssertEqual(Geo.ticks(length: 1, spacing: 0), [])
    }

    func testIsRigidRejectsScaleAndMirror() {
        XCTAssertTrue(Geo.isRigid(matrix_identity_float4x4))
        XCTAssertFalse(Geo.isRigid(simd_float4x4(diagonal: SIMD4(2, 1, 1, 1))))
        XCTAssertFalse(Geo.isRigid(simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1))))
    }

    func testBillboardFacesCameraUpright() {
        let p = SIMD3<Float>(0, 0, -2), c = SIMD3<Float>(1, 1, 0)
        let q = Geo.billboardRotation(position: p, camera: c)
        approx(q.act(SIMD3(0, 0, 1)), simd_normalize(c - p))
        XCTAssertEqual(q.act(SIMD3(1, 0, 0)).y, 0, accuracy: 1e-5)   // no roll
        XCTAssertGreaterThan(q.act(SIMD3(0, 1, 0)).y, 0)
        let top = Geo.billboardRotation(position: .zero, camera: SIMD3(0, 2, 0))
        approx(top.act(SIMD3(0, 0, 1)), SIMD3(0, 1, 0))
    }
}
