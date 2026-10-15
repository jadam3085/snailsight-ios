import XCTest
@testable import SnailSightCore

final class SimServerTests: XCTestCase {
    private func snap(_ s: String) throws -> SimEntitySnap { try JSONDecoder().decode(SimEntitySnap.self, from: Data(s.utf8)) }

    func testDecodeTolerantShapes() throws {
        let a = try snap(#"{"id":"r1","kind":"robot","pose":{"x":1,"y":2,"z":-1.3,"theta":0.5},"vel":{"v":0.3,"w":0.1},"state":"goto","owner":"phone-1","t_mono":12.5}"#)
        XCTAssertEqual(a.pose, SimPose(x: 1, y: 2, z: -1.3, theta: 0.5))
        XCTAssertEqual(a.vel.v, 0.3); XCTAssertEqual(a.vel.w, 0.1)
        XCTAssertTrue(a.isRover); XCTAssertFalse(a.isDrone)
        let b = try snap(#"{"id":7,"kind":"sim-drone","pose":[1,2,3,0.2],"vel":{"vx":1,"vy":0,"vz":0.5,"omega":0.2}}"#)
        XCTAssertEqual(b.id, "7"); XCTAssertEqual(b.pose.z, 3); XCTAssertEqual(b.pose.theta, 0.2)
        XCTAssertEqual(b.vel.vx, 1); XCTAssertEqual(b.vel.w, 0.2); XCTAssertTrue(b.isDrone)
        let c = try snap(#"{"id":"deer-1","kind":"deer","pose":{"x":0,"y":0,"yaw":1.0}}"#)
        XCTAssertEqual(c.pose.theta, 1.0); XCTAssertEqual(c.vel, .zero)
        XCTAssertThrowsError(try snap(#"{"id":"x","kind":"deer"}"#))
    }

    func testStreamMessages() throws {
        let m = SimStreamMessage.parse(Data(#"{"type":"snapshot","t_mono":3.0,"entities":[{"id":"r1","pose":{"x":0,"y":0}}]}"#.utf8))
        guard case .snapshot(let t, let ents, let full)? = m else { return XCTFail() }
        XCTAssertEqual(t, 3.0); XCTAssertEqual(ents.first?.kind, "robot"); XCTAssertTrue(full)
        XCTAssertEqual(SimStreamMessage.parse(Data(#"{"type":"event","event":"arrived","entity_id":"r1"}"#.utf8)),
                       .event(kind: "arrived", text: nil, entityID: "r1"))
        XCTAssertEqual(SimStreamMessage.parse(Data(#"{"type":"lease","entity_id":"r1","owner":"p","granted":false}"#.utf8)),
                       .lease(entityID: "r1", owner: "p", granted: false))
        guard case .snapshot(_, let e2, _)? = SimStreamMessage.parse(Data(#"{"entities":[]}"#.utf8)) else { return XCTFail() }
        XCTAssertTrue(e2.isEmpty)
        // the sim lane's real shapes (sim_api.py / sim/world.py): hello with entity docs, partial snapshots, entity
        let hello = #"{"type":"hello","map_id":"site","map_version":10,"entities":[{"id":"e1","kind":"crate","cat":"object","pose":{"x":1,"y":2,"z":0,"yaw":0.3,"theta":0.3},"dims":[0.4,0.3,0.3],"name":null,"owner":"phone-1"}]}"#
        guard case .snapshot(_, let h, let hf)? = SimStreamMessage.parse(Data(hello.utf8)) else { return XCTFail("hello") }
        XCTAssertTrue(hf); XCTAssertEqual(h.first?.dims, [0.4, 0.3, 0.3]); XCTAssertTrue(h.first!.isObject)
        let part = #"{"type":"snapshot","t":1.0,"t_mono":5.0,"tick":3,"seq":4,"full":false,"entities":[{"id":"r1","kind":"robot","pose":{"x":0,"y":0,"z":0,"theta":0},"vel":{"vx":0.3,"vy":0,"vz":0,"w":0,"v":0.3},"state":"walk","seq":1,"agent_type":"sim-rover"}]}"#
        guard case .snapshot(_, let ps, let pf)? = SimStreamMessage.parse(Data(part.utf8)) else { return XCTFail("partial") }
        XCTAssertFalse(pf); XCTAssertTrue(ps[0].isRover)
        let merged = ps[0].merged(withStatic: try snap(#"{"id":"r1","kind":"robot","cat":"robot","name":"Bob","pose":{"x":0,"y":0},"dims":[0.82,0.62,0.6]}"#))
        XCTAssertEqual(merged.name, "Bob"); XCTAssertEqual(merged.dims?[0], 0.82); XCTAssertEqual(merged.vel.v, 0.3)
        guard case .entity(let one)? = SimStreamMessage.parse(Data(#"{"type":"entity","entity":{"id":"r1","kind":"robot","cat":"robot","pose":{"x":0,"y":0}}}"#.utf8)) else { return XCTFail("entity") }
        XCTAssertEqual(one.cat, "robot")
        XCTAssertEqual(SimStreamMessage.parse(Data(#"{"type":"event","seq":3,"kind":"arrive","id":"r1","goal":[1,2]}"#.utf8)),
                       .event(kind: "arrive", text: nil, entityID: "r1"))
    }

    func testExtrapolationUnicycleStraightWorldAndCap() throws {
        let s = try snap(#"{"id":"r","pose":{"x":0,"y":0,"theta":0},"vel":{"v":1,"w":0}}"#)
        XCTAssertEqual(RemoteTrack.extrapolate(s, dt: 0.2).x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(RemoteTrack.extrapolate(s, dt: 5).x, 0.5, accuracy: 1e-9)          // capped at 0.5 s
        XCTAssertEqual(RemoteTrack.extrapolate(s, dt: -1).x, 0, accuracy: 1e-9)
        // a quarter circle: v = π/2 · r with r = 1, w = π/2 → after 1 s... capped at 0.5 s → 45°
        let t = try snap(#"{"id":"r","pose":{"x":0,"y":0,"theta":0},"vel":{"v":1.5707963267948966,"w":1.5707963267948966}}"#)
        let p = RemoteTrack.extrapolate(t, dt: 0.5)
        XCTAssertEqual(p.x, sin(Double.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(p.y, 1 - cos(Double.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(p.theta, .pi / 4, accuracy: 1e-9)
        let w = try snap(#"{"id":"d","pose":{"x":0,"y":0,"z":1,"theta":0},"vel":{"vx":0,"vy":2,"vz":-1}}"#)
        let q = RemoteTrack.extrapolate(w, dt: 0.25)
        XCTAssertEqual(q.y, 0.5, accuracy: 1e-9); XCTAssertEqual(q.z, 0.75, accuracy: 1e-9)
    }

    func testTrackEasesCorrectionAndSnapsTeleports() throws {
        var tr = RemoteTrack(try snap(#"{"id":"r","pose":{"x":0,"y":0,"theta":0},"vel":{"v":0.3,"w":0}}"#), now: 0)
        XCTAssertEqual(tr.pose(now: 0.1).x, 0.03, accuracy: 1e-9)
        // the server says it is 5 cm behind the prediction: no jump at the moment of the update, then converges
        tr.update(try snap(#"{"id":"r","pose":{"x":-0.02,"y":0,"theta":0},"vel":{"v":0.3,"w":0}}"#), now: 0.1)
        XCTAssertEqual(tr.pose(now: 0.1).x, 0.03, accuracy: 1e-9)
        XCTAssertEqual(tr.pose(now: 1.1).x, -0.02 + 0.15, accuracy: 0.002)      // error gone, extrapolation capped
        tr.update(try snap(#"{"id":"r","pose":{"x":5,"y":5,"theta":0}}"#), now: 2)
        XCTAssertEqual(tr.pose(now: 2).x, 5, accuracy: 1e-9)
    }

    func testAuthorityHysteresis() {
        var a = SimAuthority()
        a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 0, now: 0)
        XCTAssertEqual(a.mode, .local); XCTAssertEqual(a.reason, "connecting")
        XCTAssertTrue(a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 1, now: 1.1))
        XCTAssertEqual(a.mode, .server)
        XCTAssertFalse(a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 1, now: 3.5))
        XCTAssertTrue(a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 1, now: 4.5))
        XCTAssertEqual(a.reason, "stream silent")
        a.update(enabled: true, online: true, localized: false, connected: true, lastMessageAt: 5, now: 5)
        XCTAssertEqual(a.reason, "not localized")
        a.update(enabled: false, online: true, localized: true, connected: true, lastMessageAt: 5, now: 5)
        XCTAssertEqual(a.reason, "off")
    }

    func testTeleopDeadmanCadence() {
        var t = TeleopSender()
        XCTAssertNil(t.next(v: 0, w: 0, now: 0))
        XCTAssertNotNil(t.next(v: 0.3, w: 0, now: 0))
        XCTAssertNil(t.next(v: 0.3, w: 0, now: 0.05))
        let c = t.next(v: 0.3, w: 0.2, now: 0.11)
        XCTAssertEqual(c?.w, 0.2); XCTAssertEqual(c?.ttl, 0.5)
        let stop = t.next(v: 0, w: 0, now: 0.12)
        XCTAssertEqual(stop?.v, 0)
        XCTAssertNil(t.next(v: 0, w: 0, now: 0.5))
    }

    func testCommandBodiesAndPaths() throws {
        func obj(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }
        let tele = try obj(SimServerAPI.body(.teleop(v: 0.31234, w: -0.5, ttl: 0.5), agentID: "p"))
        XCTAssertEqual(tele["v"] as? Double, 0.312); XCTAssertEqual(tele["ttl"] as? Double, 0.5)
        let g = try obj(SimServerAPI.body(.goTo(label: "lamp", objectID: "o-1", x: 1, y: 2), agentID: "p"))
        XCTAssertEqual(g["goal"] as? [Double], [1, 2])
        XCTAssertEqual((g["target"] as? [String: Any])?["object_id"] as? String, "o-1")
        let pt = try obj(SimServerAPI.body(.patrol([[0, 0], [1, 1]]), agentID: "p"))
        XCTAssertEqual((pt["patrol"] as? [[Double]])?.count, 2)
        let sp = try obj(SimServerAPI.spawnBody(kind: "sim-drone", x: 1, y: 2, z: 0, theta: 0, agentID: "p"))
        XCTAssertEqual(sp["agent_type"] as? String, "sim-drone")
        XCTAssertEqual(SimServerAPI.cmdPath(map: "site", id: "r1"), "/v1/maps/site/sim/entities/r1/cmd")
        let gl = try obj(SimServerAPI.body(.goToLabel("lamp"), agentID: "p"))
        XCTAssertNil(gl["goal"]); XCTAssertEqual((gl["target"] as? [String: Any])?["label"] as? String, "lamp")
        let task = try obj(SimServerAPI.taskBody(task: "drone_assist", goal: [1.23456, 2, -1.3], agentID: "p"))
        XCTAssertEqual(task["task"] as? String, "drone_assist"); XCTAssertEqual(task["goal"] as? [Double], [1.235, 2, -1.3])
        XCTAssertEqual(SimServerAPI.taskPath(map: "site", id: "r1"), "/v1/maps/site/sim/entities/r1/task")
    }

    func testSemanticGoal() throws {
        let doc = try JSONDecoder().decode(ARObjectsDoc.self, from: Data(#"{"revision":1,"objects":[{"id":"a","label":"lamp","centroid":[5,0,1],"box":{"center":[5,0,1],"size":[0.4,0.4,1.6]}},{"id":"b","label":"floor lamp","centroid":[1,0,1]},{"id":"c","label":"chair","centroid":[0.5,0,0.4]}]}"#.utf8))
        let o = SemanticGoal.pick(doc.objects, query: "Lamp", from: [0, 0])
        XCTAssertEqual(o?.id, "b")
        let far = SemanticGoal.pick(doc.objects, query: "lamp", from: [6, 0])!
        XCTAssertEqual(far.id, "a")
        let g = SemanticGoal.standoff(far, from: [6, 0])
        XCTAssertEqual(g[0], 5 + 0.2 + 0.5, accuracy: 1e-9); XCTAssertEqual(g[1], 0, accuracy: 1e-9)
        XCTAssertNil(SemanticGoal.pick(doc.objects, query: "sofa", from: [0, 0]))
        let bad = try JSONDecoder().decode(ARObjectsDoc.self, from: Data(#"{"revision":1,"objects":[{"id":"x","label":"lamp","centroid":[1]}]}"#.utf8))
        XCTAssertNil(SemanticGoal.pick(bad.objects, query: "lamp", from: [0, 0]))      // malformed: never indexed
        XCTAssertEqual(ARBoxItem(id: "a", label: "a", center: [0, 0, 0], size: [1, 1, 1], yaw: 0, movable: true, confidence: 1).id, "a")
    }
}
