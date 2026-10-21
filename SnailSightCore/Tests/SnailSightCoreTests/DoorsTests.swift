import XCTest
@testable import SnailSightCore

final class DoorsTests: XCTestCase {
    // site@14 door-L1-06 (API §8.12 sample): hinge lo, left, swings to -n; open 81.9
    private func info(jamb: String = "lo", state: String = "open", angle: Double? = 81.9, hinge: Bool = true,
                      dir: [Double] = [-0.1326, -0.9912]) -> DoorInfo {
        let hg = hinge ? DoorInfo.Hinge(jamb: jamb, point: [-3.8686, 0.2944], side: "left") : nil
        return DoorInfo(id: "door-L1-06", status: "door", level: 1,
                        frame: .init(center: [-3.3832, 0.3405, 1.419], t: [0.99117, -0.13258], widthM: 0.95, heightM: 1.6,
                                     z0: 1.419, thicknessM: 0.22),
                        hinge: hg, swing: hinge ? .init(direction: dir, into: "neg") : nil, leafWidthM: 0.628, maxAngleDeg: 90,
                        state: DoorState(state: state, angleDeg: angle, t: 1, source: "geometry"))
    }

    private func deg(_ r: Double) -> Double { r * 180 / .pi }
    private func wrap(_ d: Double) -> Double { var x = d; while x > 180 { x -= 360 }; while x < -180 { x += 360 }; return x }

    func testClosedLeafRunsFromHingeToLatch() {
        let l = DoorLeaf.make(info(state: "closed", angle: 2.2).with(angle: 0))!
        XCTAssertEqual(l.pivot[0], -3.8686, accuracy: 1e-9)
        XCTAssertEqual(wrap(deg(l.yaw) - deg(atan2(-0.13258, 0.99117))), 0, accuracy: 0.01)
        XCTAssertEqual(l.angleDeg, 0)
        // free edge lands at the other jamb (hinge + 0.628 along t)
        XCTAssertEqual(l.tip[0], -3.8686 + 0.628 * 0.99117 / hypot(0.99117, 0.13258), accuracy: 1e-6)
    }

    func testOpenLeafTurnsTowardTheSwingSide() {
        let l = DoorLeaf.make(info())!
        // the swing direction is at 90 deg; at 81.9 deg the leaf is 8.1 deg short of it
        let swingYaw = deg(atan2(-0.9912, -0.1326))
        XCTAssertEqual(wrap(deg(l.yaw) - swingYaw), 8.1, accuracy: 0.6)
        XCTAssertEqual(l.state, "open"); XCTAssertEqual(l.label, "open 82°")
        XCTAssertEqual(l.width, 0.628, accuracy: 1e-9)
        XCTAssertEqual(l.boxCenter[2], 1.419 + 0.8, accuracy: 1e-9)
    }

    func testHiJambMirrorsAndOppositeSwingTurnsTheOtherWay() {
        let hi = DoorLeaf.make(info(jamb: "hi", dir: [0.1326, 0.9912]))!
        let t = atan2(-0.13258, 0.99117)
        XCTAssertEqual(wrap(deg(hi.yaw) - deg(t + .pi)), -81.9, accuracy: 0.2)   // u = -t, the swing side is -z: turns clockwise
        let a = DoorLeaf.make(info(dir: [-0.1326, -0.9912]))!
        let b = DoorLeaf.make(info(dir: [0.1326, 0.9912]))!
        XCTAssertEqual(wrap(deg(a.yaw) - deg(t)) , -wrap(deg(b.yaw) - deg(t)), accuracy: 1e-6)
    }

    func testUnknownStateIsClosedAndUnknownHingeIsCentred() {
        let u = DoorLeaf.make(info(state: "unknown", angle: nil))!
        XCTAssertEqual(u.angleDeg, 0); XCTAssertEqual(u.state, "closed")
        let c = DoorLeaf.make(info(state: "closed", angle: 5.8, hinge: false))!
        XCTAssertTrue(c.centred); XCTAssertFalse(c.hinged); XCTAssertEqual(c.angleDeg, 0)
        XCTAssertEqual(c.boxCenter[0], -3.3832, accuracy: 1e-9)
        XCTAssertEqual(c.width, 0.95)
    }

    func testOpeningsAreNotDrawn() {
        var o = info(); o.status = "opening"
        XCTAssertNil(DoorLeaf.make(o))
    }

    func testLiveEventReplacesTheAngle() throws {
        let json = """
        {"id":"door-L1-06","status":"door","level":1,"frame":{"center":[-3.3832,0.3405,1.419],"t":[0.99117,-0.13258],
        "width_m":0.95,"height_m":1.6,"z0":1.419},"hinge":{"jamb":"lo","point":[-3.8686,0.2944],"side":"left"},
        "swing":{"direction":[-0.1326,-0.9912]},"leaf_width_m":0.628,"max_angle_deg":90,
        "state":{"state":"open","angle_deg":81.9}}
        """
        let doc = DoorsDoc.parse(Data("{\"map_id\":\"site\",\"doors\":[\(json)]}".utf8))!
        var set = DoorSet(); set.load(doc)
        let before = set.leaves[0].yaw
        let ev = DoorEvent.parse(Data("{\"type\":\"door\",\"door_id\":\"door-L1-06\",\"state\":\"closed\",\"angle_deg\":0.5,\"source\":\"live\"}".utf8))!
        XCTAssertTrue(set.apply(ev))
        XCTAssertFalse(set.apply(ev))                       // same reading: no redraw
        XCTAssertNotEqual(set.leaves[0].yaw, before)
        XCTAssertEqual(set.leaves[0].state, "closed")
        XCTAssertEqual(set.leaves[0].angleDeg, 0.5, accuracy: 1e-9)
        XCTAssertFalse(set.apply(DoorEvent(doorID: "nope", state: "open", angleDeg: 90, t: nil)))
        XCTAssertNil(DoorEvent.parse(Data("{\"type\":\"change\"}".utf8)))
    }

    func testDoorEventRidesTheDownlinkAsOther() {
        let d = Data(("{\"type\":\"door\",\"door_id\":\"door-L2-10\",\"state\":\"open\",\"angle_deg\":85.1,\"prev_state\":\"closed\","
                      + "\"prev_angle_deg\":2.2,\"t\":1792200000.5,\"source\":\"live\",\"agent\":\"a1\",\"conf\":0.7,\"level\":2,"
                      + "\"base_version\":14,\"observed_by\":[\"a1\"],\"seq\":812}").utf8)
        guard let (m, seq) = LiveDownMessage.parseWithSeq(d) else { return XCTFail("did not parse") }
        XCTAssertEqual(m, .other("door")); XCTAssertEqual(seq, 812)
        XCTAssertEqual(DoorEvent.parse(d)?.angleDeg, 85.1)
    }

    func testDoorsLayerFollowsTheMasterSwitch() {
        let s = LayerSnapshot()
        XCTAssertTrue(WorldGate.doors(s, worldOn: true))
        XCTAssertFalse(WorldGate.doors(s, worldOn: false))
        XCTAssertFalse(WorldGate.doors(LayerSnapshot(doors: false), worldOn: true))
        XCTAssertFalse(LayerSnapshot.cameraOnly.doors)
        // a pre-12.6 stored snapshot (no `doors`) still decodes, doors on
        let old = Data("{\"house\":\"Model\",\"meshLive\":true,\"objects\":true,\"terrain\":false,\"cameras\":true,\"agents\":true}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(LayerSnapshot.self, from: old), LayerSnapshot())
    }
}

private extension DoorInfo {
    func with(angle: Double) -> DoorInfo { var c = self; c.state = DoorState(state: "closed", angleDeg: angle, t: nil, source: nil); return c }
}
