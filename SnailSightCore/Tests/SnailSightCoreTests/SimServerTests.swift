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

    func testAuthorityBlockedUntilServerHoldsLocalBodies() {
        var a = SimAuthority()
        let local: Set<String> = ["deer-1", "fox-2", "robot-3"]
        // healthy stream, but the server world is empty: stay local (the owner's animals must not vanish)
        var b = SimHandoff.blocker(local: local, server: [], serverMode: false, uploading: false)
        XCTAssertEqual(b, "server world empty")
        a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 0, now: 0, blocked: b)
        XCTAssertFalse(a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 2, now: 2,
                                blocked: b))
        XCTAssertEqual(a.mode, .local); XCTAssertEqual(a.reason, "server world empty")
        b = SimHandoff.blocker(local: local, server: ["deer-1"], serverMode: false, uploading: true)
        XCTAssertEqual(b, "uploading 2 bodies")
        // the upload landed: every local body is on the server -> switch after the usual 1 s
        b = SimHandoff.blocker(local: local, server: local.union(["other-9"]), serverMode: false, uploading: false)
        XCTAssertNil(b)
        a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 3, now: 3, blocked: b)
        XCTAssertTrue(a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 4, now: 4.1,
                               blocked: b))
        XCTAssertEqual(a.mode, .server)
        // in charge: a partial world keeps it (deletes on the server are real), an empty one falls back
        XCTAssertNil(SimHandoff.blocker(local: local, server: ["deer-1"], serverMode: true, uploading: false))
        b = SimHandoff.blocker(local: local, server: [], serverMode: true, uploading: false)
        XCTAssertTrue(a.update(enabled: true, online: true, localized: true, connected: true, lastMessageAt: 5, now: 5,
                               blocked: b))
        XCTAssertEqual(a.mode, .local)
        XCTAssertNil(SimHandoff.blocker(local: [], server: [], serverMode: false, uploading: false))
    }

    func testImportBodyCarriesMapEntities() throws {
        let rec = SimEntityRecord(id: "A-1", kind: "deer", behaviour: "roam", heading: 0, anchor: [0, 0, 0])
        let e = MapEntity(id: "A-1", kind: "deer", pose: MapPose(x: 1, y: 2, z: -1.3, yaw: 0.5), mapVersion: 12,
                          record: rec, agentID: "phone-aaaa")
        let o = try JSONSerialization.jsonObject(with: SimServerAPI.importBody([e], agentID: "phone-aaaa")) as! [String: Any]
        XCTAssertEqual(o["agent_id"] as? String, "phone-aaaa")
        let first = (o["entities"] as! [[String: Any]])[0]
        XCTAssertEqual(first["id"] as? String, "A-1")
        XCTAssertEqual(first["map_version"] as? Int, 12)
        XCTAssertEqual((first["pose"] as! [String: Any])["y"] as? Double, 2)
        XCTAssertEqual(SimServerAPI.importPath(map: "site"), "/v1/maps/site/sim/import")
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

    // MARK: protocol snailsight-sim/2 (one master world, API §5.9.10)

    func testSharedClipFieldsDecodeAndMerge() throws {
        let j = #"{"id":"F1","kind":"fox","pose":{"x":1,"y":2,"z":0,"theta":0.5,"yaw":0.5},"vel":{"vx":0.2,"vy":0,"vz":0,"w":0},"state":"walk","clip":"walk","clip_t0":100.0,"clip_rate":1.0,"action":"walk","scale":0.5,"t":101.25,"seq":2}"#
        let s = try snap(j)
        XCTAssertEqual(s.clip, "walk"); XCTAssertEqual(s.clipT0, 100.0); XCTAssertEqual(s.clipRate, 1.0)
        XCTAssertEqual(s.action, "walk"); XCTAssertEqual(s.scale, 0.5); XCTAssertEqual(s.t, 101.25)
        XCTAssertEqual(s.serverClip, "walk")
        let old = try snap(#"{"id":"F1","kind":"fox","pose":{"x":0,"y":0},"state":"eat"}"#)
        XCTAssertEqual(old.serverClip, "eat"); XCTAssertNil(old.scale)
        let doc = try snap(#"{"id":"F1","kind":"fox","cat":"animal","pose":{"x":0,"y":0},"scale":0.5,"behaviour":"roam"}"#)
        let m = old.merged(withStatic: doc)
        XCTAssertEqual(m.scale, 0.5); XCTAssertEqual(m.behaviour, "roam")
    }

    func testSharedClipKeyAndPhaseMatchAcrossClients() {
        let have: Set<String> = ["idle", "walk", "run", "eat"]
        XCTAssertEqual(SimSharedClip.key("walk", available: have), "walk")
        XCTAssertEqual(SimSharedClip.key("eat", available: have), "eat")
        XCTAssertEqual(SimSharedClip.key("run", available: ["idle", "walk"]), "walk")     // local fallbacks
        XCTAssertEqual(SimSharedClip.key(nil, available: have), "idle")
        XCTAssertEqual(SimSharedClip.key("eat", available: ["static"]), "static")
        // two clients with different clock offsets, same server time -> same clip time
        var a = SimServerClock(), b = SimServerClock()
        a.observe(serverTime: 1000.0, receivedAt: 10.05)            // phone: 50 ms late
        a.observe(serverTime: 1000.1, receivedAt: 10.12)            // 20 ms late: the better sample wins
        b.observe(serverTime: 1000.1, receivedAt: 500.12)           // another device, other clock
        let ta = SimSharedClip.time(clipT0: 998.0, rate: 1, serverNow: a.serverNow(local: 11.0), duration: 1.2)
        let tb = SimSharedClip.time(clipT0: 998.0, rate: 1, serverNow: b.serverNow(local: 501.0), duration: 1.2)
        XCTAssertEqual(ta, tb, accuracy: 1e-9)
        XCTAssertEqual(ta, (1000.98 - 998.0).truncatingRemainder(dividingBy: 1.2), accuracy: 1e-6)
        XCTAssertEqual(SimSharedClip.time(clipT0: nil, rate: 1, serverNow: 5, duration: 1), 0)
        XCTAssertEqual(SimSharedClip.time(clipT0: 10, rate: 1, serverNow: 9.5, duration: 2), 1.5, accuracy: 1e-9)
    }

    func testServerVisualsUseModelsNotBoxes() throws {
        let animals: Set<String> = ["fox", "deer", "sheep"], objects: Set<String> = ["crate"]
        XCTAssertEqual(SimServerVisual.of(try snap(#"{"id":"a","kind":"deer","cat":"animal","pose":{"x":0,"y":0},"scale":0.5}"#),
                                          animalKeys: animals, objectKeys: objects), .animal(key: "deer", scale: 0.5))
        XCTAssertEqual(SimServerVisual.of(try snap(#"{"id":"r","kind":"robot","cat":"robot","pose":{"x":0,"y":0},"scale":0.5}"#),
                                          animalKeys: animals, objectKeys: objects), .robot(scale: 0.5))
        XCTAssertEqual(SimServerVisual.of(try snap(#"{"id":"c","kind":"crate","cat":"object","pose":{"x":0,"y":0},"scale":3}"#),
                                          animalKeys: animals, objectKeys: objects), .object(key: "crate", scale: 2))
        XCTAssertEqual(SimServerVisual.of(try snap(#"{"id":"d","kind":"drone","cat":"drone","pose":{"x":0,"y":0}}"#),
                                          animalKeys: animals, objectKeys: objects), .drone)
        XCTAssertEqual(SimServerVisual.of(try snap(#"{"id":"u","kind":"unicorn","pose":{"x":0,"y":0}}"#),
                                          animalKeys: animals, objectKeys: objects), .box)
    }

    func testMoveKickBehaviourBodies() throws {
        func o(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }
        let p = try o(SimServerAPI.body(.place(x: 1.23456, y: 2, z: 0.5), agentID: "phone-1"))
        XCTAssertEqual(p["place"] as? [Double], [1.235, 2, 0.5]); XCTAssertEqual(p["owner"] as? String, "phone-1")
        let k = try o(SimServerAPI.body(.kick(fromX: 0.5, fromY: -1), agentID: "phone-1"))
        XCTAssertEqual(k["kick"] as? [Double], [0.5, -1])
        let b = try o(SimServerAPI.body(.behaviour("roam"), agentID: "phone-1"))
        XCTAssertEqual(b["behaviour"] as? String, "roam")
    }

    func testEntitiesDocCarriesTombstones() throws {
        let d = try JSONDecoder().decode(MapEntitiesDoc.self, from: Data(#"{"map_id":"site","revision":3,"map_version":13,"entities":[],"deleted":["BOB"]}"#.utf8))
        XCTAssertEqual(d.deleted, ["BOB"])
        let old = try JSONDecoder().decode(MapEntitiesDoc.self, from: Data(#"{"map_id":"site","revision":3,"entities":[]}"#.utf8))
        XCTAssertNil(old.deleted)
    }
}
