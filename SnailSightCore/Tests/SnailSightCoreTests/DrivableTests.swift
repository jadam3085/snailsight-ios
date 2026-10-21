import XCTest
@testable import SnailSightCore

final class DrivableTests: XCTestCase {
    private func snap(_ json: String) throws -> SimEntitySnap {
        try JSONDecoder().decode(SimEntitySnap.self, from: Data(json.utf8))
    }

    func testDrivableFromCatalogElseKindFallback() {
        XCTAssertTrue(Drivable.isDrivable(kind: "robot"))
        XCTAssertTrue(Drivable.isDrivable(kind: "rc_car"))
        XCTAssertTrue(Drivable.isDrivable(kind: "sim-rover"))
        XCTAssertFalse(Drivable.isDrivable(kind: "sim-drone"))
        XCTAssertFalse(Drivable.isDrivable(kind: "drone", cat: "drone"))
        XCTAssertFalse(Drivable.isDrivable(kind: "deer", cat: "animal"))
        XCTAssertFalse(Drivable.isDrivable(kind: "rc_car", catalogDrivable: false))      // the catalog wins
        XCTAssertTrue(Drivable.isDrivable(kind: "kart", catalogDrivable: true))
        XCTAssertEqual(Drivable.driveKind(kind: "rc_car"), .ackermann)
        XCTAssertEqual(Drivable.driveKind(kind: "robot"), .diff)
        XCTAssertEqual(Drivable.driveKind(kind: "kart", catalogDrive: "ackermann"), .ackermann)
    }

    func testRCCarSnapshotDecodesAndDrawsAsTheToyCar() throws {
        let s = try snap("""
        {"id":"car1","kind":"rc_car","cat":"robot","pose":{"x":1,"y":2,"z":0,"yaw":0.5,"theta":0.5},
         "vel":{"vx":0.3,"vy":0,"vz":0,"w":0.1,"v":0.3},"steer":-0.2,"drive":"ackermann","clip":"drive",
         "action":"teleop","level":1,"scale":0.5,"dims":[0.225,0.125,0.08]}
        """)
        XCTAssertEqual(s.kind, "rc_car")
        XCTAssertEqual(s.steer, -0.2)
        XCTAssertEqual(s.drive, "ackermann")
        XCTAssertTrue(s.isDrivable && s.isRCCar && !s.isDrone)
        XCTAssertEqual(s.driveKind, .ackermann)
        XCTAssertEqual(s.role, .robot)
        XCTAssertEqual(SimServerVisual.of(s, animalKeys: ["deer"], objectKeys: ["toycar"]), .rcCar(scale: 0.5))
        // an unknown future field / kind never breaks decoding
        let u = try snap(#"{"id":"x","kind":"hovercraft","pose":[0,0,0,0],"steer":"left","drive":{"a":1}}"#)
        XCTAssertNil(u.steer)
        XCTAssertNil(u.drive)
        XCTAssertEqual(SimServerVisual.of(u, animalKeys: [], objectKeys: []), .box)
        // the stream parser keeps a snapshot that carries an rc_car
        let m = SimStreamMessage.parse(Data(#"{"type":"snapshot","entities":[{"id":"c","kind":"rc_car","pose":{"x":0,"y":0}}]}"#.utf8))
        guard case .snapshot(_, let list, _)? = m else { return XCTFail("no snapshot") }
        XCTAssertEqual(list.first?.kind, "rc_car")
    }

    func testRCCarModelScaleAndWheels() {
        let k = RCCar.modelScale(scale: 1)
        XCTAssertEqual(k[0], 0.45 / 0.25, accuracy: 1e-9)
        XCTAssertEqual(k[1], 0.16 / 0.129, accuracy: 1e-9)
        XCTAssertEqual(k[2], 0.25 / 0.15, accuracy: 1e-9)
        let half = RCCar.modelScale(model: [0.25, 0.129, 0.15], scale: 0.5)
        XCTAssertEqual(half[0] * 0.25, 0.225, accuracy: 1e-9)       // drawn length = 0.45 × 0.5
        XCTAssertEqual(RCCar.wheelYaw(steer: 1.0), 0.41, accuracy: 1e-9)
        XCTAssertEqual(RCCar.wheelYaw(steer: nil), 0)
        let it = RCCar.catalogItem()
        XCTAssertEqual(it.key, "rc_car")
        XCTAssertEqual(it.file(clip: "static"), "toycar.usdz")
        XCTAssertEqual(it.sizeM, [0.45, 0.16, 0.25])
        XCTAssertEqual(it.group, "Vehicles")
    }

    func testStickToThrottleSteerWithDeadZone() {
        let m = DriveStick()
        XCTAssertEqual(m.map(V2(0.05, 0.1)).throttle, 0)          // inside the dead zone
        XCTAssertEqual(m.map(V2(0.05, 0.1)).steer, 0)
        let up = m.map(V2(0.05, 1))
        XCTAssertEqual(up.throttle, 1, accuracy: 0.02)
        XCTAssertEqual(up.steer, 0)                                 // a straight push does not steer
        let right = m.map(V2(1, 0))
        XCTAssertEqual(right.steer, 1, accuracy: 1e-9)              // + = right
        XCTAssertEqual(m.map(V2(-1, 0)).steer, -1, accuracy: 1e-9)
        XCTAssertEqual(m.map(V2(0, -1)).throttle, -1, accuracy: 1e-9)  // reverse
        let half = m.map(V2(0, 0.6)).throttle
        XCTAssertGreaterThan(half, 0)
        XCTAssertLessThan(half, 0.6)                                // expo: finer near the centre
        let big = m.map(V2(3, 4))                                   // outside the disc: clamped
        XCTAssertLessThanOrEqual(abs(big.throttle), 1)
        XCTAssertLessThanOrEqual(abs(big.steer), 1)
    }

    func testRouteRobotKeepsTeleopCarSendsDrive() {
        guard case .teleop(let v, let w) = DriveRoute.make(stick: V2(1, 0), kind: .diff, tank: true) else {
            return XCTFail("robot must stay on teleop")
        }
        XCTAssertEqual(v, 0, accuracy: 1e-9)
        XCTAssertLessThan(w, 0)                                     // stick right = clockwise
        guard case .teleop(let v2, _) = DriveRoute.make(stick: V2(0, 1), kind: .diff, tank: false) else { return XCTFail() }
        XCTAssertEqual(v2, RobotProfile.robosnailbob.maxSpeed, accuracy: 1e-9)
        guard case .drive(let d) = DriveRoute.make(stick: V2(1, 1).normalizedDisc, kind: .ackermann, tank: true) else {
            return XCTFail("rc_car must send drive")
        }
        XCTAssertTrue(d.tank)
        XCTAssertGreaterThan(d.throttle, 0)
        XCTAssertGreaterThan(d.steer, 0)
    }

    func testDriveSenderCadenceAndOneZeroOnRelease() {
        var s = DriveSender()
        let d = DriveInput(throttle: 0.5, steer: 0.2)
        XCTAssertEqual(s.next(d, now: 0), d)
        XCTAssertNil(s.next(d, now: 0.05))
        XCTAssertEqual(s.next(d, now: 0.1), d)                      // 10 Hz
        XCTAssertEqual(s.next(.zero, now: 0.12), .zero)             // release: one brake
        XCTAssertNil(s.next(.zero, now: 0.3))
        XCTAssertNil(s.next(.zero, now: 1.0))
        XCTAssertEqual(s.next(d, now: 1.01), d)                     // a new push goes at once
        XCTAssertEqual(DriveInput(throttle: 3, steer: -3).throttle, 1)
        XCTAssertEqual(DriveInput(throttle: 3, steer: -3).steer, -1)
    }

    func testDriveMessageEncoding() throws {
        let data = SimServerAPI.wsCommand(.drive(throttle: 0.75, steer: -0.5, tank: false, ttl: DriveSender.ttl),
                                          id: "car1", agentID: "phone", ref: "d1")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["type"] as? String, "cmd")
        XCTAssertEqual(o["id"] as? String, "car1")
        XCTAssertEqual(o["ref"] as? String, "d1")
        XCTAssertEqual(o["ttl"] as? Double, 0.5)
        XCTAssertEqual(o["owner"] as? String, "phone")
        let dr = try XCTUnwrap(o["drive"] as? [String: Any])
        XCTAssertEqual(dr["throttle"] as? Double, 0.75)
        XCTAssertEqual(dr["steer"] as? Double, -0.5)
        XCTAssertEqual(dr["tank"] as? Bool, false)
        XCTAssertNil(o["v"])
        XCTAssertEqual(SimServerAPI.Command.drive(throttle: 0, steer: 0, tank: true, ttl: 0.5).name, "drive")
        let rest = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: SimServerAPI.body(.drive(throttle: 2, steer: 0, tank: true, ttl: 0.5), agentID: "p")) as? [String: Any])
        XCTAssertEqual((rest["drive"] as? [String: Any])?["throttle"] as? Double, 1)     // clamped
        XCTAssertEqual((rest["drive"] as? [String: Any])?["tank"] as? Bool, true)
    }

    func testOfferedCommandsForDrivableBodies() {
        XCTAssertEqual(SimCommand.offered(role: .robot, server: true, drivable: true).first, .drive)
        XCTAssertFalse(SimCommand.offered(role: .robot, drone: true, server: true, drivable: true).contains(.drive))
        XCTAssertFalse(SimCommand.offered(role: .robot, server: true).contains(.drive))
        XCTAssertTrue(SimCommand.available(for: .robot).contains(.drive))
        XCTAssertFalse(SimCommand.drive.needsPoint)
    }

    // MARK: 12.5 owner items from the 12.4 screenshot

    func testFootprintUsesTheBodyScale() {
        XCTAssertEqual(BodyFootprint.size(scale: 1), [0.82, 0.62])                  // what 12.4 always drew
        let half = BodyFootprint.size(scale: 0.5)
        XCTAssertEqual(half[0], 0.41, accuracy: 1e-9)
        XCTAssertEqual(half[1], 0.31, accuracy: 1e-9)
        XCTAssertEqual(BodyFootprint.size(dims: [0.41, 0.31, 0.5], scale: 2), [0.41, 0.31])   // server dims win
        let car = BodyFootprint.size(scale: 0.5, kind: "rc_car")
        XCTAssertEqual(car[0], 0.225, accuracy: 1e-9)
        XCTAssertEqual(car[1], 0.125, accuracy: 1e-9)
        XCTAssertEqual(BodyFootprint.planScale(selected: 0.75, localRobot: 0.5, simOn: true, global: 0.5), 0.75)
        XCTAssertEqual(BodyFootprint.planScale(selected: nil, localRobot: 0.35, simOn: true, global: 0.5), 0.35)
        XCTAssertEqual(BodyFootprint.planScale(selected: nil, localRobot: nil, simOn: true, global: 0.5), 0.5)
        XCTAssertEqual(BodyFootprint.planScale(selected: nil, localRobot: nil, simOn: false, global: 0.5), 1)
    }

    func testSimNavQueryAtTheBodyScale() throws {
        let a = try JSONDecoder().decode(SimNavQueryAnswer.self, from: Data(#"{"level":1,"cell":[3,4],"known":true,"cost":0.4,"lethal":false,"floor_z":0.02,"blocked_body":false,"scale":0.5}"#.utf8))
        XCTAssertEqual(a.fits, true)
        XCTAssertEqual(a.floorZ, 0.02)
        let b = try JSONDecoder().decode(SimNavQueryAnswer.self, from: Data(#"{"level":1,"known":true,"cost":1.0,"lethal":true,"blocked_body":true}"#.utf8))
        XCTAssertEqual(b.fits, false)
        let u = try JSONDecoder().decode(SimNavQueryAnswer.self, from: Data(#"{"level":1,"known":false,"cost":null,"lethal":null}"#.utf8))
        XCTAssertNil(u.fits)
        let q = SimNavQueryAnswer.query(x: 1, y: 2, z: nil, scale: 0.5, kind: "rc_car")
        XCTAssertEqual(q.map(\.0), ["x", "y", "scale", "kind"])
        XCTAssertEqual(q[2].1, "0.500")
        XCTAssertEqual(q[3].1, "rc_car")
        XCTAssertEqual(SimNavQueryAnswer.query(x: 0, y: 0, z: 1, scale: 9, kind: "sim-rover").last?.1, "robot")
        XCTAssertEqual(SimNavQueryAnswer.query(x: 0, y: 0, z: 1, scale: 9, kind: "robot")[3].1, "2.000")
    }

    func testSelectingAnotherBodyClearsThePreviousOverlays() {
        var o = SelectionOverlays()
        XCTAssertEqual(o.select("robot"), [])
        o.drew(.pathPreview, for: "robot")
        o.drew(.robotPathResult, for: "robot")
        o.drew(.goalMarkers, for: "robot")
        XCTAssertEqual(o.select("robot"), [])                                       // same body: kept
        XCTAssertEqual(o.select("chicken"), [.pathPreview, .robotPathResult, .goalMarkers])
        XCTAssertTrue(o.drawn.isEmpty)
        o.drew(.homeOutline, for: "chicken")
        o.drew(.robotPathResult, for: nil)                                         // planned from where you stand
        XCTAssertEqual(o.select(nil), [.homeOutline, .robotPathResult])            // deselect: everything
        o.drew(.robotPathResult, for: nil)
        XCTAssertEqual(o.select("deer"), [.robotPathResult])
        o.drew(.ring, for: "deer")
        o.cleared(.ring)
        XCTAssertEqual(o.select("fox"), [])
    }

    func testFollowPoseKeepsSendingThroughStaleSnapshotsAndReselect() {
        var f = FollowPoseTracker()
        f.follow("chicken", now: 0)
        // the snapshot in flight when Follow was sent still says roam: within the grace it must not drop the follower
        f.observe("chicken", behaviour: "roam", now: 0.1)
        f.observe("chicken", behaviour: nil, now: 0.2)                             // no behaviour in this snapshot
        XCTAssertTrue(f.shouldSend(now: 0.5, alive: ["chicken"], localized: true))
        XCTAssertFalse(f.shouldSend(now: 0.6, alive: ["chicken"], localized: true))  // ~2 Hz
        XCTAssertTrue(f.shouldSend(now: 1.0, alive: ["chicken"], localized: true))
        f.observe("chicken", behaviour: "follow", now: 1.1)                        // the server confirms
        // selecting another body does not touch the tracker; 30 s later it still sends at 2 Hz
        var sent = 0
        var t = 1.5
        while t < 31.5 { if f.shouldSend(now: t, alive: ["chicken", "robot"], localized: true) { sent += 1 }; t += 0.5 }
        XCTAssertGreaterThanOrEqual(sent, 58)
        XCTAssertFalse(f.shouldSend(now: 40, alive: ["chicken"], localized: false))  // not localized: nothing
        // after confirmation the server's own "roam" ends it
        f.observe("chicken", behaviour: "roam", now: 41)
        XCTAssertTrue(f.isEmpty)
        // unconfirmed and still not following after the grace: dropped
        f.follow("deer", now: 50)
        f.observe("deer", behaviour: "idle", now: 54)
        XCTAssertTrue(f.isEmpty)
        // a body that left the world is dropped
        f.follow("fox", now: 60)
        XCTAssertFalse(f.shouldSend(now: 61, alive: [], localized: true))
        XCTAssertTrue(f.isEmpty)
        f.follow("a", now: 70); f.drop("a")
        XCTAssertTrue(f.isEmpty)
    }
}

private extension V2 {
    var normalizedDisc: V2 { let l = (x * x + y * y).squareRoot(); return l > 1 ? self / l : self }
}
