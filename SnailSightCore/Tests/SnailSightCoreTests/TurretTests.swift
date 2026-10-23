import XCTest
@testable import SnailSightCore

/// 12.7 turret + FPV camera: numbers from the server reference `sim/vehicle.py turret_camera` (API §5.9.10).
final class TurretTests: XCTestCase {
    let spec = TurretSpec.robosnailbob

    private func near(_ a: FPVPose, _ x: Double, _ y: Double, _ z: Double, _ yaw: Double, _ pitch: Double,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.y, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.z, z, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.yaw, yaw, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.pitch, pitch, accuracy: 1e-9, file: file, line: line)
    }

    func testCameraMatchesPythonReference() {
        // python3: turret_camera(1, 2, 0.1, pi/2, 1, spec, 0, 0) -> (1.0, 2.2, 0.72) yaw pi/2
        near(TurretCamera.pose(x: 1, y: 2, z: 0.1, bodyYaw: .pi / 2, scale: 1, spec: spec, turretYaw: 0, turretPitch: 0),
             1.0, 2.2, 0.72, .pi / 2, 0)
        // turret_camera(0, 0, 0, 0, 0.5, spec, pi/2, 0.3) -> (0.075, 0.025, 0.31) yaw pi/2 pitch 0.3
        near(TurretCamera.pose(x: 0, y: 0, z: 0, bodyYaw: 0, scale: 0.5, spec: spec, turretYaw: .pi / 2, turretPitch: 0.3),
             0.075, 0.025, 0.31, .pi / 2, 0.3)
        // turret_camera(-3.2, 1.7, 0.4, 2.5, 0.5, spec, -1.1, -0.2)
        near(TurretCamera.pose(x: -3.2, y: 1.7, z: 0.4, bodyYaw: 2.5, scale: 0.5, spec: spec, turretYaw: -1.1, turretPitch: -0.2),
             -3.255836592593514, 1.7695216540575083, 0.71, 1.4, -0.2)
        // turret_camera(0, 0, 0, 3.0, 1.0, spec, 0.5, 0.1): look yaw wraps to (-pi, pi]
        near(TurretCamera.pose(x: 0, y: 0, z: 0, bodyYaw: 3.0, scale: 1, spec: spec, turretYaw: 0.5, turretPitch: 0.1),
             -0.19532170885460662, 0.0036288398244990853, 0.62, -2.7831853071795867, 0.1)
    }

    func testViewerFrameConversion() {
        // map (x, y, z) z-up -> RealityKit viewer y-up: (x, z, -y); x = ARKit x, y_map = -z_ark
        XCTAssertEqual(MapViewerFrame.toViewer([1, 2, 3]), [1, 3, -2])
        XCTAssertEqual(MapViewerFrame.toMap([1, 3, -2]), [1, 2, 3])
        let c = FPVPose(x: 1, y: 2.2, z: 0.72, yaw: .pi / 2, pitch: 0)
        XCTAssertEqual(c.viewerEye, [1, 0.72, -2.2])
        let f = c.viewerForward                                   // looking along map +y = viewer -z
        XCTAssertEqual(f[0], 0, accuracy: 1e-12); XCTAssertEqual(f[1], 0, accuracy: 1e-12); XCTAssertEqual(f[2], -1, accuracy: 1e-12)
        let up = FPVPose(x: 0, y: 0, z: 0, yaw: 0, pitch: 0.5).viewerForward   // pitch up = viewer +y
        XCTAssertEqual(up[1], sin(0.5), accuracy: 1e-12); XCTAssertEqual(up[0], cos(0.5), accuracy: 1e-12)
    }

    func testChaseSitsBehindAndAbove() {
        let cam = TurretCamera.pose(x: 0, y: 0, z: 0, bodyYaw: 0, scale: 0.5, spec: spec, turretYaw: .pi / 2, turretPitch: 0)
        let ch = TurretCamera.chase(cam, scale: 0.5)
        // looks along +y (turret yaw 90°): the eye is 1.2 m behind (−y) and 0.5 m above the camera
        XCTAssertEqual(ch.eye[0], cam.x, accuracy: 1e-9)
        XCTAssertEqual(ch.eye[1], cam.y - 1.2, accuracy: 1e-9)
        XCTAssertEqual(ch.eye[2], cam.z + 0.5, accuracy: 1e-9)
        XCTAssertEqual(ch.target[1], cam.y + 2, accuracy: 1e-9)
    }

    func testSpecAndSnapshotDecoding() throws {
        let doc = #"{"id":"r1","kind":"robot","pose":{"x":0,"y":0},"turret":{"yaw":0.4,"pitch":-0.1,"spec":{"kind":"pan_tilt","origin_m":[0.15,0,0.5],"camera_m":[0.2,0,0.62],"yaw_min":null,"yaw_max":null,"pitch_min":-0.349,"pitch_max":0.785,"yaw_rate_max":1.5,"pitch_rate_max":1.0}},"lease":{"by":"snailcop-portal-1","holder":"portal (cop.snail)","until":12.5}}"#
        let d = try JSONDecoder().decode(SimEntitySnap.self, from: Data(doc.utf8))
        XCTAssertEqual(d.turret?.yaw, 0.4); XCTAssertEqual(d.turret?.spec, spec)
        XCTAssertTrue(d.turret!.spec!.continuousYaw)
        XCTAssertEqual(d.lease?.label, "portal (cop.snail)")
        let snap = try JSONDecoder().decode(SimEntitySnap.self, from: Data(#"{"id":"r1","kind":"robot","pose":{"x":0,"y":0},"turret":{"yaw":0.6,"pitch":0.2}}"#.utf8))
        XCTAssertNil(snap.turret?.spec)
        let m = snap.merged(withStatic: d)
        XCTAssertEqual(m.turret?.yaw, 0.6); XCTAssertEqual(m.turret?.spec, spec)     // snapshot pose, doc spec
        XCTAssertEqual(m.turretSpec, spec)
        let car = try JSONDecoder().decode(SimEntitySnap.self, from: Data(#"{"id":"c","kind":"rc_car","pose":{"x":0,"y":0}}"#.utf8))
        XCTAssertFalse(car.hasTurret); XCTAssertNil(car.turretSpec)
        let robot = try JSONDecoder().decode(SimEntitySnap.self, from: Data(#"{"id":"r","kind":"robot","pose":{"x":0,"y":0}}"#.utf8))
        XCTAssertEqual(robot.turretSpec, .robosnailbob)                               // before the doc arrives
    }

    func testTurretTrackInterpolatesAndClamps() {
        var t = TurretTrack(yaw: 0, pitch: 0, now: 0)
        t.update(yaw: 0.1, pitch: 0.05, now: 0.1)          // 1 rad/s yaw, 0.5 rad/s pitch
        // 50 ms later: extrapolated + the (decaying) error from what was drawn at 0.1 (0) toward 0.1
        let v = t.value(now: 0.15)
        XCTAssertGreaterThan(v.yaw, 0.05); XCTAssertLessThan(v.yaw, 0.16)
        // long after: holds at the last pose + at most maxExtrapolate × rate, no drift
        let late = t.value(now: 5)
        XCTAssertEqual(late.yaw, 0.1 + 1.0 * TurretTrack.maxExtrapolate, accuracy: 1e-6)
        // pitch never leaves the spec's range
        var p = TurretTrack(yaw: 0, pitch: 0.78, now: 0)
        p.update(yaw: 0, pitch: 0.785, now: 0.1)
        XCTAssertLessThanOrEqual(p.value(now: 0.25).pitch, spec.pitchMax + 1e-12)
        // continuous yaw wraps across ±pi
        var w = TurretTrack(yaw: 3.1, pitch: 0, now: 0)
        w.update(yaw: -3.1, pitch: 0, now: 0.1)
        let wy = w.value(now: 0.2).yaw
        XCTAssertTrue(wy < -3.0 || wy > 3.0, "\(wy)")
    }

    func testViewPanAndCommandFields() {
        var v = ViewPan()
        for _ in 0..<100 { v.step(yawRate: 0, pitchRate: 1, dt: 0.1) }
        XCTAssertEqual(v.pitch, TurretSpec.rcCarView.pitchMax, accuracy: 1e-9)
        v.step(yawRate: -1, pitchRate: 0, dt: 0.1)
        XCTAssertEqual(v.yaw, -0.15, accuracy: 1e-9)          // stick right = view right (yaw −)
        v.centre(); XCTAssertEqual(v.yaw, 0); XCTAssertEqual(v.pitch, 0)
        XCTAssertEqual(TurretCommand.rate(yaw: 2, pitch: -0.5).fields["yaw_rate"] as? Double, 1)
        XCTAssertEqual(TurretCommand.centre.fields["centre"] as? Bool, true)
        let aim = TurretCommand.aim(yaw: 0.25, pitch: nil).fields
        XCTAssertEqual(aim["yaw"] as? Double, 0.25); XCTAssertNil(aim["pitch"])
        XCTAssertTrue(TurretCommand.rate(yaw: 0.01, pitch: 0).isZeroRate)
    }

    func testWsTwinStickMessage() throws {
        let m = TeleopMessage(drive: DriveInput(throttle: 0.5, steer: -0.25), turret: .rate(yaw: -0.4, pitch: 0.2))
        let o = try JSONSerialization.jsonObject(with: SimServerAPI.wsCommand(.control(m), id: "r1", agentID: "phone-1",
                                                                              ref: nil, force: true)) as! [String: Any]
        XCTAssertEqual(o["type"] as? String, "cmd"); XCTAssertEqual(o["force"] as? Bool, true)
        XCTAssertEqual(o["ttl"] as? Double, 0.5)
        let d = o["drive"] as! [String: Any]
        XCTAssertEqual(d["throttle"] as? Double, 0.5); XCTAssertEqual(d["steer"] as? Double, -0.25)
        let t = o["turret"] as! [String: Any]
        XCTAssertEqual(t["yaw_rate"] as? Double, -0.4); XCTAssertEqual(t["pitch_rate"] as? Double, 0.2)
        XCTAssertNil(o["v"])
        let r = try JSONSerialization.jsonObject(with: SimServerAPI.wsCommand(.release, id: "r1", agentID: "p", ref: "c1")) as! [String: Any]
        XCTAssertEqual(r["release"] as? Bool, true); XCTAssertNil(r["force"])
        XCTAssertEqual(SimServerAPI.Command.control(m).name, "drive_turret")
        XCTAssertEqual(SimServerAPI.Command.control(TeleopMessage(turret: .centre)).name, "turret")
    }
}
