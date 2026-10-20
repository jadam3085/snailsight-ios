import XCTest
@testable import SnailSightCore

final class CameraMarkTests: XCTestCase {
    private func close(_ a: [Double], _ b: [Double], _ eps: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for i in a.indices { XCTAssertEqual(a[i], b[i], accuracy: eps, "component \(i): \(a) vs \(b)", file: file, line: line) }
    }

    /// ARKit camera → world, row-major, from a rotation about the camera's x axis (pitch) then a translation.
    private func camera(at p: [Double], pitchDeg: Double = 0, yawDeg: Double = 0) -> Mat4 {
        let a = pitchDeg * .pi / 180, b = yawDeg * .pi / 180
        // R = Ry(yaw) · Rx(pitch) (ARKit: y up)
        let rx = [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]]
        let ry = [[cos(b), 0, sin(b)], [0, 1, 0], [-sin(b), 0, cos(b)]]
        var r = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { r[i][j] = (0..<3).reduce(0) { $0 + ry[i][$1] * rx[$1][j] } } }
        return Mat4([r[0][0], r[0][1], r[0][2], p[0], r[1][0], r[1][1], r[1][2], p[1], r[2][0], r[2][1], r[2][2], p[2], 0, 0, 0, 1])
    }

    // MARK: ray maths

    func testCrosshairRayIdentityAlignmentMapsArkitYUpToMapZUp() {
        let T = Align4(x: 0, y: 0, z: 0, yaw: 0).matrix
        let r = MarkMath.crosshairRay(T_map_arkit: T, camera: camera(at: [1, 1.5, 0]))
        close(r.origin, [1, 0, 1.5])                         // ARKit (x, y, z) → map (x, −z, y)
        close(r.dir, [0, 1, 0])                              // looking along ARKit −z = map +y
    }

    func testCrosshairRayFollowsAlignmentYawAndTranslation() {
        let T = Align4(x: 10, y: -4, z: 0.3, yaw: .pi / 2).matrix
        let r = MarkMath.crosshairRay(T_map_arkit: T, camera: camera(at: [0, 1.4, 0]))
        close(r.origin, [10, -4, 1.7])
        close(r.dir, [-1, 0, 0])                             // ARKit −z rotated by +90° about map z
        // the ray must agree with transforming two points of it
        let far = T.apply([0, 1.4, -5])
        close(MarkMath.unit(MarkMath.sub(far, r.origin)), r.dir)
    }

    func testCrosshairRayPitchedUpAtTheRoofline() {
        let T = Align4(x: 0, y: 0, z: 0, yaw: 0.3).matrix
        let r = MarkMath.crosshairRay(T_map_arkit: T, camera: camera(at: [0, 1.5, 0], pitchDeg: 30, yawDeg: 20))
        XCTAssertEqual(r.dir[2], sin(30 * .pi / 180), accuracy: 1e-9)      // 30° up stays 30° up in the map
        XCTAssertEqual(MarkMath.norm(r.dir), 1, accuracy: 1e-12)
        // heading in the map = alignment yaw + 90° (ARKit −z = map +y at yaw 0) + the camera's own yaw
        let heading = atan2(r.dir[1], r.dir[0])
        XCTAssertEqual(heading, 0.3 + .pi / 2 + 20 * .pi / 180, accuracy: 1e-9)
    }

    func testPixelDirectionCentreIsMinusZAndOffCentreTilts() {
        close(MarkMath.pixelDirection(u: 960, v: 720, fx: 1400, fy: 1400, cx: 960, cy: 720), [0, 0, -1])
        let d = MarkMath.pixelDirection(u: 960 + 1400, v: 720, fx: 1400, fy: 1400, cx: 960, cy: 720)
        XCTAssertEqual(MarkMath.angleDeg(d, [0, 0, -1]), 45, accuracy: 1e-9)
        XCTAssertGreaterThan(d[0], 0)
        let up = MarkMath.pixelDirection(u: 960, v: 0, fx: 1400, fy: 1400, cx: 960, cy: 720)
        XCTAssertGreaterThan(up[1], 0)                       // image row 0 = up
    }

    // MARK: triangulation (local fallback) + spread

    private func ray(from o: [Double], to p: [Double], lock: MarkLock = .strong) -> MarkRay {
        MarkRay(origin: o, dir: MarkMath.sub(p, o), t: 0, lock: lock)
    }

    func testTwoRaysTriangulateARooflineCamera() {
        let cam = [0.0, 10, 5.2]
        let rays = [ray(from: [-2, 0, 1.5], to: cam), ray(from: [2, 0, 1.5], to: cam)]
        XCTAssertGreaterThan(MarkMath.maxSpreadDeg(rays), 20)
        close(MarkMath.closestPoint(rays)!, cam, 1e-6)
        let r = MarkMath.localTriangulate(rays)!
        close(r.point!, cam, 1e-6)
        XCTAssertTrue(r.local)
        XCTAssertLessThan(r.sigmaM!, 0.5)
        XCTAssertGreaterThan(r.sigmaM!, 0.01)
    }

    func testNoisyRaysLeastSquaresAndBehindRejected() {
        let cam = [3.0, 8, 4]
        var rays = [ray(from: [0, 0, 1.5], to: [3.02, 8, 4]), ray(from: [5, 0, 1.4], to: [3, 8.03, 3.98]),
                    ray(from: [7, 2, 1.5], to: [2.98, 7.99, 4.01])]
        let p = MarkMath.closestPoint(rays)!
        XCTAssertLessThan(MarkMath.norm(MarkMath.sub(p, cam)), 0.05)
        rays = [ray(from: [0, 0, 1], to: [0, 5, 1]), ray(from: [1, 0, 1], to: [1, -5, 1])]   // diverging: no point in front
        XCTAssertNil(MarkMath.closestPoint(rays))
        rays = [ray(from: [0, 0, 1], to: [0, 5, 1]), ray(from: [1, 0, 1], to: [1, 5, 1])]    // parallel
        XCTAssertNil(MarkMath.closestPoint(rays))
    }

    func testLocalTriangulateNeedsTenDegreesAndIgnoresNoLock() {
        let cam = [0.0, 10, 5]
        let narrow = [ray(from: [-0.4, 0, 1.5], to: cam), ray(from: [0.4, 0, 1.5], to: cam)]
        XCTAssertLessThan(MarkMath.maxSpreadDeg(narrow), 10)
        XCTAssertNil(MarkMath.localTriangulate(narrow))
        let unlocked = [ray(from: [-3, 0, 1.5], to: cam), ray(from: [3, 0, 1.5], to: cam, lock: .none)]
        XCTAssertNil(MarkMath.localTriangulate(unlocked))
    }

    // MARK: guidance

    func testGuideAimThenStepSidewaysThenReady() {
        let cam = [0.0, 10, 5]
        XCTAssertEqual(MarkGuide.evaluate([]).phase, .aim)
        let first = ray(from: [0, 0, 1.5], to: cam)
        let g1 = MarkGuide.evaluate([first], me: [0, 0, 1.5])
        XCTAssertEqual(g1.phase, .moveSideways)
        XCTAssertTrue(g1.text.hasPrefix("Step 2.0 m sideways"), g1.text)
        // walking ALONG the ray toward the camera is not sideways
        XCTAssertTrue(MarkGuide.evaluate([first], me: [0, 2, 2]).text.hasPrefix("Step"))
        // 2 m sideways: the next mark is good
        XCTAssertTrue(MarkGuide.evaluate([first], me: [2, 0, 1.5]).text.hasPrefix("Good spot"))
        // a second mark only ~5° apart
        let close5 = ray(from: [0.9, 0, 1.5], to: cam)
        let g2 = MarkGuide.evaluate([first, close5], me: [0.9, 0, 1.5])
        XCTAssertEqual(g2.phase, .moveSideways)
        XCTAssertTrue(g2.text.hasPrefix("Only"), g2.text)
        XCTAssertGreaterThanOrEqual(g2.stepM!, 2)
        let wide = ray(from: [3, 0, 1.5], to: cam)
        let g3 = MarkGuide.evaluate([first, wide])
        XCTAssertEqual(g3.phase, .ready)
        XCTAssertGreaterThanOrEqual(g3.spreadDeg, 10)
    }

    func testGuideScalesStepWithRange() {
        // a far camera (30 m) needs more than 2 m sideways for 10°
        let cam = [0.0, 30, 6]
        let a = ray(from: [0, 0, 1.5], to: cam), b = ray(from: [1, 0, 1.5], to: cam)
        let g = MarkGuide.evaluate([a, b], me: [1, 0, 1.5])
        XCTAssertEqual(g.phase, .moveSideways)
        XCTAssertGreaterThanOrEqual(g.stepM!, 5)
    }

    func testLockQualityFromLocalizer() {
        XCTAssertEqual(MarkLock.from(source: "server", method: "both", errCm: 2), .strong)
        XCTAssertEqual(MarkLock.from(source: "server", method: "visual", errCm: 3), .good)
        XCTAssertEqual(MarkLock.from(source: "place_cache", method: nil, errCm: 5), .good)
        XCTAssertEqual(MarkLock.from(source: "carried", method: nil, errCm: 12), .weak)
        XCTAssertEqual(MarkLock.from(source: "", method: nil, errCm: nil), .none)
        XCTAssertEqual(MarkLock.from(source: "server", method: "both", errCm: 40), .none)
    }

    // MARK: wire

    func testTriangulateBodyDropsUnlockedRaysAndCarriesHit() throws {
        let rays = [MarkRay(origin: [0, 0, 1], dir: [0, 2, 0], t: 5, lock: .good, hit: [0, 3, 1]),
                    MarkRay(origin: [1, 0, 1], dir: [0, 1, 0], t: 6, lock: .none)]
        let body = MarkWire.triangulate(rays: rays, agentID: "phone-x", mapVersion: 14)
        let data = try JSONSerialization.data(withJSONObject: body)
        let back = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let list = back["rays"] as! [[String: Any]]
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["lock_quality"] as? String, "good")
        XCTAssertEqual((list[0]["dir"] as! [Double]), [0, 1, 0])                    // normalised
        XCTAssertEqual((list[0]["raycast_hit"] as! [Double]), [0, 3, 1])
        XCTAssertEqual(back["map_version"] as? Int, 14)
    }

    func testParseServerTriangulation() {
        let json = """
        {"ok":true,"point":[1.5,9.8,5.1],"sigma_m":0.12,"cov":[[0.01,0,0],[0,0.0144,0],[0,0,0.004]],
         "ellipse":{"axes_m":[0.12,0.1,0.06],"axes":[[0,1,0],[1,0,0],[0,0,1]]},"residual_deg_p50":0.4,"residual_deg_max":0.9,
         "max_angle_deg":23.5,"used":[0,1,2],"rejected":[{"i":3,"why":"outlier"}],"n_rays":4,"map_version":14,
         "entity_id":"front_door","current":[1,9,4.5],"delta_m":1.1}
        """
        let r = TriangulateResult.parse(Data(json.utf8))!
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.point!, [1.5, 9.8, 5.1])
        XCTAssertEqual(r.used, 3)
        XCTAssertEqual(r.ringRadii.0, 0.12, accuracy: 1e-12)
        XCTAssertEqual(r.ringRadii.1, 0.1, accuracy: 1e-12)
        XCTAssertEqual(r.summary, "± 12 cm · 3 rays · 24° apart · moves 1.1 m")
        let bad = TriangulateResult.parse(Data(#"{"ok":false,"why":"need >= 2 rays at >= 10 deg apart","used":[]}"#.utf8))!
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.why, "need >= 2 rays at >= 10 deg apart")
        XCTAssertNil(MarkWire.accept(bad, rays: 2, agentID: "a", mapVersion: nil))
        XCTAssertNotNil(MarkWire.accept(r, rays: 4, agentID: "a", mapVersion: 14))
    }

    func testNewPlacementSourceAndID() {
        XCTAssertTrue(MarkWire.validSource("frigate:garage"))
        XCTAssertTrue(MarkWire.validSource("kinect"))
        XCTAssertFalse(MarkWire.validSource("frigate:"))
        XCTAssertFalse(MarkWire.validSource("rtsp://x"))
        XCTAssertEqual(MarkWire.newID(name: "Roof Cam #2", t: 4096), "roof_cam_2-1000")
        let b = MarkWire.newPlacement(kind: "camera", name: "Roof", source: "ha:camera.roof", point: [1, 2, 3], sigmaM: 0.2,
                                      rays: 3, agentID: "p", mapVersion: 14, level: 1, t: 10)
        let rec = b["record"] as! [String: Any]
        XCTAssertEqual(rec["estimated"] as? Bool, false)
        XCTAssertEqual((rec["position"] as! [String: Any])["source"] as? String, "triangulated")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(b))
    }

    // MARK: camera check

    func testCoverageAndWalkStatusParse() {
        let cov = CoverageAnswer.parse(Data("""
        {"cameras":[{"id":"a","name":"Front","sees":true,"score":0.4,"calibrated":false},
                    {"id":"b","sees":false},{"id":"c","sees":true,"score":0.9,"calibrated":true}]}
        """.utf8))!
        XCTAssertEqual(cov.seeing.map(\.id), ["c", "a"])
        let w = WalkStatus.parse(Data("""
        {"status":"open","end_t":2000,"poses_n":40,"cameras":[{"id":"a","detections_n":5,"matches_n":3,"last_match_t":995}],
         "recent":[{"camera_id":"a","t":995,"box":[0,0,1,1],"matched":true},{"camera_id":"b","t":999,"matched":false},
                   {"camera_id":"c","t":900,"matched":true}]}
        """.utf8))!
        XCTAssertEqual(w.status, "open")
        XCTAssertEqual(w.sawMe(now: 1000), ["a"])
        XCTAssertEqual(w.cameras.first?.matches, 3)
    }

    func testPoseBufferRateFlushAndNoLock() {
        var b = WalkPoseBuffer(hz: 2, flushEvery: 5)
        var kept = 0
        for i in 0..<60 { if b.offer(t: Double(i) / 60 * 3, p: [0, 0, 0], yaw: 0, lock: .good) { kept += 1 } }  // 3 s at 20 Hz
        XCTAssertEqual(kept, 6)                                             // 2 Hz
        XCTAssertFalse(b.offer(t: 10, p: [0, 0, 0], yaw: 0, lock: .none))
        XCTAssertFalse(b.due(now: 3))
        XCTAssertTrue(b.due(now: 5.1))
        let batch = b.take(now: 5.1)
        XCTAssertEqual(batch.count, 6)
        XCTAssertEqual(batch[0]["lock_quality"] as? String, "good")
        XCTAssertTrue(b.snapshot.isEmpty)
        XCTAssertFalse(b.due(now: 20))
    }

    func testFrustumFallback() {
        // camera on the roofline at (0, 0, 5) facing +y (yaw 90°), 30° down, 90° x 60° FOV, 15 m
        let c = [0.0, 0, 5]
        XCTAssertTrue(CameraFrustum.sees(camera: c, yaw: .pi / 2, pitchDeg: -30, hfovDeg: 90, vfovDeg: 60, far: 15, point: [0, 6, 1.4]))
        XCTAssertFalse(CameraFrustum.sees(camera: c, yaw: .pi / 2, pitchDeg: -30, hfovDeg: 90, vfovDeg: 60, far: 15, point: [0, -6, 1.4]))
        XCTAssertFalse(CameraFrustum.sees(camera: c, yaw: .pi / 2, pitchDeg: -30, hfovDeg: 90, vfovDeg: 60, far: 15, point: [12, 3, 1.4]))
        XCTAssertFalse(CameraFrustum.sees(camera: c, yaw: .pi / 2, pitchDeg: -30, hfovDeg: 90, vfovDeg: 60, far: 15, point: [0, 20, 1.4]))
    }
}
