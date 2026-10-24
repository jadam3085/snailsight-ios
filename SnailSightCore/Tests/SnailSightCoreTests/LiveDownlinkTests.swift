import XCTest
@testable import SnailSightCore

final class LiveDownlinkTests: XCTestCase {
    private func msg(_ s: String) -> LiveDownMessage? { LiveDownMessage.parse(Data(s.utf8)) }

    func testParseEveryMessageType() {
        XCTAssertEqual(msg(#"{"type":"head","base_version":10,"seq":4,"epoch":"e1"}"#), .head(baseVersion: 10, seq: 4, epoch: "e1"))
        XCTAssertEqual(LiveDownMessage.parseWithSeq(Data(#"{"type":"rebase","seq":77,"from_version":10,"to_version":11}"#.utf8))?.seq, 77)
        XCTAssertEqual(msg(#"{"type":"rebase","seq":77,"from_version":10,"to_version":11}"#), .rebase(toVersion: 11))
        let I = "[1,0,0,0.5, 0,1,0,0, 0,0,1,0, 0,0,0,1]"
        guard case .correction(let a, let s, let T, let placed)? = msg(#"{"type":"correction","agent_id":"rover-1","stream_id":"ar-1","T_map_odom":\#(I),"placed":true}"#) else {
            return XCTFail("correction")
        }
        XCTAssertEqual(a, "rover-1"); XCTAssertEqual(s, "ar-1"); XCTAssertEqual(T[0, 3], 0.5); XCTAssertEqual(placed, true)
        XCTAssertEqual(msg(#"{"type":"tile","layer":"mesh","key":"0/1/-2","ver":{"base_version":10,"live_seq":7},"enc":"f32","data":"AA=="}"#),
                       .tile(layer: "mesh", key: "0/1/-2", ver: TileVer(base: 10, seq: 7), enc: "f32", data: "AA=="))
        XCTAssertEqual(msg(#"{"type":"tile","layer":"terrain","key":"k","ver":3,"enc":"png16"}"#),
                       .tile(layer: "terrain", key: "k", ver: TileVer(base: 0, seq: 3), enc: "png16", data: nil))
        XCTAssertEqual(msg(#"{"type":"doc","kind":"objects","revision":9}"#), .doc(kind: "objects", revision: 9))
        XCTAssertEqual(msg(#"{"type":"change","key":"0/1/1","change":"added","bbox":[0,0,0,1,1,1]}"#),
                       .change(key: "0/1/1", kind: "added", state: nil, bbox: [0, 0, 0, 1, 1, 1]))
        // API §6b.1 shape: id (= key), state, kind added|removed
        XCTAssertEqual(msg(#"{"type":"change","seq":5,"id":"c7","state":"cleared","kind":"removed","bbox":[0,0,0,1,1,1],"objects":[{"id":"o-1","label":"chair"}]}"#),
                       .change(key: "c7", kind: "removed", state: "cleared", bbox: [0, 0, 0, 1, 1, 1]))
        XCTAssertEqual(msg(#"{"type":"commit","version":11}"#), .commit(version: 11))
        XCTAssertEqual(msg(#"{"type":"error","detail":"no map"}"#), .error("no map"))
        XCTAssertEqual(msg(#"{"type":"pong"}"#), .other("pong"))
        XCTAssertNil(msg("not json"))
        guard case .agents(let list)? = msg(#"{"type":"agent","agent_id":"d1","agent_type":"sim-drone","placed":true,"pose":{"x":1,"y":2,"z":3,"yaw":0.1}}"#) else {
            return XCTFail("agent")
        }
        XCTAssertEqual(list.first?.pose?.z, 3)
    }

    func testSubscribeMessageCarriesSinceAndAccept() throws {
        let d = LiveSubscribe.message(agentID: "phone-1", mapID: "site", baseVersion: 10,
                                      tiles: ["mesh:0/1/2": TileVer(base: 10, seq: 3)])
        let o = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(o["type"] as? String, "subscribe")
        XCTAssertEqual(o["transport"] as? String, "json")
        XCTAssertEqual(o["layers"] as? [String], ["corrections", "agents", "changes", "docs", "mesh"])
        let d2 = LiveSubscribe.message(agentID: "p", mapID: "site", baseVersion: 10, tiles: [:], epoch: "e1", seq: 99)
        let s2 = (try JSONSerialization.jsonObject(with: d2) as! [String: Any])["since"] as! [String: Any]
        XCTAssertEqual(s2["epoch"] as? String, "e1"); XCTAssertEqual(s2["seq"] as? Int, 99)
        let since = o["since"] as! [String: Any]
        XCTAssertEqual(since["base_version"] as? Int, 10)
        let t = (since["tiles"] as! [String: Any])["mesh:0/1/2"] as! [String: Int]
        XCTAssertEqual(t["live_seq"], 3)
        XCTAssertEqual(((o["accept"] as! [String: Any])["mesh"] as! [String]), ["f32"])
    }

    func testTileStoreNewerOnlyAndRebase() {
        var s = LiveTileStore()
        XCTAssertTrue(s.accept(layer: "mesh", key: "a", ver: TileVer(base: 10, seq: 1)))
        XCTAssertFalse(s.accept(layer: "mesh", key: "a", ver: TileVer(base: 10, seq: 1)))
        XCTAssertFalse(s.accept(layer: "mesh", key: "a", ver: TileVer(base: 9, seq: 50)))
        XCTAssertTrue(s.accept(layer: "mesh", key: "a", ver: TileVer(base: 10, seq: 2)))
        XCTAssertTrue(s.accept(layer: "terrain", key: "a", ver: TileVer(base: 10, seq: 1)))
        XCTAssertEqual(s.since(layer: "mesh"), ["a": TileVer(base: 10, seq: 2)])
        XCTAssertEqual(s.allSince.count, 2)
        s.rebase(11)
        XCTAssertTrue(s.have.isEmpty)
        XCTAssertEqual(s.baseVersion, 11)
    }

    func testMeshTileRoundTripAndRejectsBadIndex() {
        let m = FlatMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0.5], indices: [0, 1, 2])
        let enc = LiveMeshTile.encode(m)
        XCTAssertEqual(LiveMeshTile.decode(enc: "f32", base64: enc), m)
        XCTAssertNil(LiveMeshTile.decode(enc: "glb", base64: enc))
        let bad = LiveMeshTile.encode(FlatMesh(positions: [0, 0, 0], indices: [0, 0, 5]))
        XCTAssertNil(LiveMeshTile.decode(enc: "f32", base64: bad))
        XCTAssertNil(LiveMeshTile.decode(enc: "f32", base64: "AAA"))
    }

    func testChangeMarkersFadeExpireDynamicAndCap() {
        var c = ChangeMarkers()
        c.lifetime = 10
        XCTAssertTrue(c.add(key: "t1", kind: "added", bbox: [0, 0, 0, 1, 2, 0.5], floorZ: 0, now: 0))
        XCTAssertFalse(c.add(key: "t2", kind: "dynamic", bbox: [0, 0, 0, 1, 1, 1], floorZ: 0, now: 0))
        XCTAssertFalse(c.add(key: "t3", kind: "added", bbox: nil, floorZ: 0, now: 0))
        XCTAssertTrue(c.add(key: "t4", kind: "removed", bbox: [2, 2, 3, 3], floorZ: -1.3, now: 0))
        XCTAssertEqual(c.markers.count, 2)
        XCTAssertEqual(c.markers[0].center, [0.5, 1, 0.25])
        XCTAssertEqual(c.markers[1].center[2], -0.8, accuracy: 1e-9)
        XCTAssertEqual(c.fade(c.markers[0], now: 1), 1)
        XCTAssertEqual(c.fade(c.markers[0], now: 6), 0.5, accuracy: 1e-9)
        c.add(key: "t1", kind: "changed", bbox: [0, 0, 0, 1, 1, 1], floorZ: 0, now: 5)    // same key replaces
        XCTAssertEqual(c.markers.count, 2)
        XCTAssertTrue(c.expire(now: 12))
        XCTAssertEqual(c.markers.map(\.key), ["t1"])
        // cleared (put back) removes; dynamic never flags
        XCTAssertTrue(c.add(key: "t1", kind: "added", state: "cleared", bbox: nil, floorZ: 0, now: 13))
        XCTAssertTrue(c.markers.isEmpty)
        XCTAssertFalse(c.add(key: "d", kind: "added", state: "dynamic", bbox: [0, 0, 0, 1, 1, 1], floorZ: 0, now: 13))
        c.maxCount = 3
        for k in 0..<5 { c.add(key: "k\(k)", kind: "added", bbox: [0, 0, 1, 1], floorZ: 0, now: 6) }
        XCTAssertEqual(c.markers.count, 3)
    }

    func testAgentMarksFromLiveStateSkipMeAndUnplaced() throws {
        let j = #"{"map_id":"site","anchored":true,"base_version":10,"agents":[{"agent_id":"phone-me","agent_type":"phone","placed":true,"connected":true,"path":[[0,0,0]]},{"agent_id":"replay-basement","agent_type":"mock","placed":true,"connected":true,"last_wall":95,"path":[[0,0,0],[1,0,0],[1,0.02,0],[1,1,0]]},{"agent_id":"lost","placed":false,"connected":true,"path":[[5,5,5]]},{"agent_id":"old","agent_type":"rover","placed":true,"connected":false,"last_wall":10,"path":[[2,2,0]]}]}"#
        let doc = try JSONDecoder().decode(LiveStateDoc.self, from: Data(j.utf8))
        let m = AgentMark.from(doc.agents, me: "phone-me", now: 100)
        XCTAssertEqual(m.map(\.id), ["old", "replay-basement"])
        let r = m[1]
        XCTAssertEqual(r.position, [1, 1, 0])
        XCTAssertEqual(r.heading, .pi / 2, accuracy: 1e-9)
        XCTAssertTrue(r.live)
        XCTAssertFalse(m[0].live)
        XCTAssertEqual(r.trail.count, 4)
    }

    func testAgentTrailsFromDownlinkAgentMessages() throws {
        var tr = AgentTrails()
        func agent(_ x: Double, placed: Bool = true) throws -> LiveAgent {
            try JSONDecoder().decode(LiveAgent.self, from: Data(#"{"agent_id":"rover-1","agent_type":"rover","stream_id":"s","placed":\#(placed),"connected":true,"T_map_odom":null,"pose":{"x":\#(x),"y":0,"z":0,"yaw":0.5},"last_wall":100}"#.utf8))
        }
        try tr.update(agent(0), now: 100)
        try tr.update(agent(0.05), now: 100.5)                 // < 10 cm: no new trail point
        try tr.update(agent(0.3), now: 101)
        try tr.update(agent(0.6, placed: false), now: 101.5)   // unplaced: never a trail point
        let m = tr.marks(me: "phone-1", now: 102)
        XCTAssertEqual(m.count, 0)                              // its newest message says unplaced
        try tr.update(agent(0.9), now: 102)
        let m2 = tr.marks(me: "phone-1", now: 102)
        XCTAssertEqual(m2.first?.trail.count, 3)
        XCTAssertEqual(m2.first?.heading, 0.5)
        XCTAssertEqual(m2.first?.position, [0.9, 0, 0])
        tr.expire(now: 200)
        XCTAssertTrue(tr.latest.isEmpty)
    }

    func testServerFeatures() {
        let f = ServerFeatures.parse(Data(#"{"api":"snailsight/v1","features":["localize","live_uplink"]}"#.utf8))
        XCTAssertFalse(f.liveDownlink(forced: false))
        XCTAssertTrue(f.liveDownlink(forced: true))
        XCTAssertFalse(f.serverSim(forced: false))
        XCTAssertTrue(ServerFeatures(["live_downlink", "sim"]).liveDownlink(forced: false))
        XCTAssertTrue(ServerFeatures(["sim_server"]).serverSim(forced: false))
    }
}
