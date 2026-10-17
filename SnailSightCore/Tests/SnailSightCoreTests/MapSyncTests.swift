import XCTest
@testable import SnailSightCore

final class MapSyncTests: XCTestCase {
    func testDecodeSyncBlockAndFilterVariant() throws {
        let msg = #"{"type":"rev","map_id":"site","rev":14,"ready":true,"tiles":{"rev":25},"sync":{"kind":"rev","rev":25,"prev_rev":24,"changed":[{"layer":"structure","key":"1/0/-1","hash":"aa","bytes":10,"glb":"gg","lod":4},{"layer":"raw","key":"1/0/-1","hash":"bb"}],"removed":[{"layer":"structure","key":"0/9/9"}],"changed_total":7}}"#
        let ev = try XCTUnwrap(TileSyncEvent.decode(message: Data(msg.utf8)))
        XCTAssertEqual(ev.kind, "rev")
        XCTAssertEqual(ev.rev, 25)
        XCTAssertEqual(ev.changes(variant: "structure")["1/0/-1"]?.hash, "aa")
        XCTAssertEqual(ev.removedKeys(variant: "structure"), ["0/9/9"])
        XCTAssertEqual(ev.changedTotal, 7)
        XCTAssertNil(TileSyncEvent.decode(message: Data(#"{"type":"rev","map_id":"site"}"#.utf8)))
        // the M1 head decoder still reads the same message
        XCTAssertNotNil(MapHead.decode(Data(msg.utf8)))
    }

    func testSubscribeCarriesHeld() throws {
        let h = TileSync.held(variant: "structure", hashes: ["1/0/-1": "aa"])
        let s = TileSync.subscribeJSON(mapID: "site", held: h)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        XCTAssertEqual(o["type"] as? String, "subscribe")
        XCTAssertEqual((o["held"] as? [String: String])?["structure:1/0/-1"], "aa")
        XCTAssertEqual(o["layers"] as? [String], ["rev"])
    }

    func testEditQueueOrderCoalesceAndOutcomes() {
        var q = EditQueue()
        q.enqueue(EditOp(key: "k1", method: "PUT", path: "/a", body: nil, created: 1))
        q.enqueue(EditOp(key: "k2", method: "PUT", path: "/bulk", body: Data("1".utf8), created: 2, coalesce: "bulk"))
        q.enqueue(EditOp(key: "k3", method: "PUT", path: "/bulk", body: Data("2".utf8), created: 3, coalesce: "bulk"))
        XCTAssertEqual(q.ops.map { $0.key }, ["k1", "k3"])
        XCTAssertEqual(EditQueue.outcome(status: 200), .done)
        XCTAssertEqual(EditQueue.outcome(status: nil), .retryLater)
        XCTAssertEqual(EditQueue.outcome(status: 503), .retryLater)
        XCTAssertEqual(EditQueue.outcome(status: 409), .stale)
        XCTAssertEqual(EditQueue.outcome(status: 410), .drop("HTTP 410"))
        q.complete("k1")
        XCTAssertEqual(q.next?.key, "k3")
        let rt = EditQueue.decode(q.encoded())
        XCTAssertEqual(rt, q)
    }

    func testRebaseKeepsKeyAndConflictRule() throws {
        let dict: [String: Any] = ["kind": "deer", "base_revision": 3]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let op = EditOp(key: "k", method: "PUT", path: "/e/d1", body: body, entityID: "d1", seenUpdated: 100, created: 1)
        let r = EditQueue.rebased(op, revision: 9)
        XCTAssertEqual(r.key, "k")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(r.body)) as? [String: Any])
        XCTAssertEqual(o["base_revision"] as? Int, 9)
        XCTAssertFalse(EditQueue.isConflict(op, serverUpdated: 100))
        XCTAssertTrue(EditQueue.isConflict(op, serverUpdated: 150))
        XCTAssertFalse(EditQueue.isConflict(op, serverUpdated: nil))
    }
}
