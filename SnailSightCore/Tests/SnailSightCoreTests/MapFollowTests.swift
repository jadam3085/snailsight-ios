import XCTest
@testable import SnailSightCore

final class MapFollowTests: XCTestCase {
    private func head(_ rev: Int?, etag: String? = nil, pending: Int? = nil) -> MapHead {
        MapHead(rev: rev, etag: etag, phone: rev.map { MapHead.Phone(usdzURL: "/v1/phone/scans/site@\($0)/files/mesh.usdz", bytes: 100) },
                collision: rev.map { MapHead.Collision(url: "/v1/scenes/site@\($0)/files/collision.obj") },
                pending: pending.map { MapHead.Pending(version: $0, phone: "running") })
    }

    func testDecodesServerHeadAndRevMessage() {
        let body = """
        {"map_id":"site","rev":14,"rev_kind":"version","ready":true,"latest_version":15,"version":14,"scene":"site@14",
         "etag":"14-1792172207","created":1.0,
         "phone":{"usdz_url":"/v1/phone/scans/site@14/files/mesh.usdz?v=1792172207","bytes":57338458,"triangles":1115475,
                  "texture_px":1057,"built":1792172211.6,"rebuilding":false,"rebuild_failed":false},
         "collision":{"url":"/v1/scenes/site@14/files/collision.obj","bytes":4862848},
         "pending":{"version":15,"phone":"queued","geometry":"ready"},"server_time":1792181329.7}
        """
        let h = MapHead.decode(Data(body.utf8))
        XCTAssertEqual(h?.rev, 14)
        XCTAssertEqual(h?.sceneID, "site@14")
        XCTAssertEqual(h?.phone?.bytes, 57338458)
        XCTAssertEqual(h?.collision?.url, "/v1/scenes/site@14/files/collision.obj")
        XCTAssertEqual(h?.pending?.version, 15)
        XCTAssertEqual(h?.latestVersion, 15)
        XCTAssertTrue(h?.usable ?? false)
        let rev = MapHead.decode(Data(#"{"type":"rev","map_id":"site","rev":15,"ready":true,"scene":"site@15","etag":"15-2"}"#.utf8))
        XCTAssertEqual(rev?.rev, 15)
        XCTAssertNil(MapHead.decode(Data(#"{"type":"head","map_id":"site","seq":3}"#.utf8)))      // the live unit's head
        XCTAssertNil(MapHead.decode(Data(#"{"type":"snapshot","seq":3,"count":0}"#.utf8)))
        let notReady = MapHead.decode(Data(#"{"map_id":"site","rev":null,"ready":false,"latest_version":1,"pending":{"version":1}}"#.utf8))
        XCTAssertNotNil(notReady)
        XCTAssertFalse(notReady!.usable)
    }

    func testNewerIsHigherRevOrSameRevRebuiltNeverOlder() {
        XCTAssertTrue(head(15).isNewer(than: head(14)))
        XCTAssertFalse(head(13).isNewer(than: head(14)))
        XCTAssertFalse(head(14).isNewer(than: head(14)))
        XCTAssertTrue(head(14, etag: "14-9").isNewer(than: head(14, etag: "14-1")))     // textured rebuild
        XCTAssertTrue(head(1).isNewer(than: nil))
        XCTAssertFalse(head(nil, pending: 3).isNewer(than: nil))                          // nothing built: never
    }

    func testLaunchShowsCachedThenFollowsANewerHead() {
        var f = MapFollow(cached: head(14))
        XCTAssertEqual(f.followVersion, 14)                     // cached head: on screen at launch, no tap
        XCTAssertFalse(f.offer(head(14)))                        // server agrees: nothing to do
        XCTAssertFalse(f.offer(head(nil, pending: 15)))          // v15 merged, phone mesh not built: never shown
        XCTAssertEqual(f.followVersion, 14)
        XCTAssertTrue(f.offer(head(15)))                         // built: prefetch it
        XCTAssertNil(f.swapDue(now: 100, still: true))           // not downloaded yet
        f.didPrefetch(head(15), now: 100)
        XCTAssertNil(f.swapDue(now: 101, still: false))          // walking: wait for a still moment
        XCTAssertEqual(f.swapDue(now: 102, still: true)?.rev, 15)
        XCTAssertEqual(f.didSwap(head(15)), "Map updated · rev 15")
        XCTAssertEqual(f.followVersion, 15)
        XCTAssertNil(f.staged)
        XCTAssertFalse(f.offer(head(15)))
        XCTAssertFalse(f.offer(head(14)))                        // never back to an older version
    }

    func testSwapsAfterMaxWaitEvenWhileMoving() {
        var f = MapFollow(cached: head(3))
        f.offer(head(4))
        f.didPrefetch(head(4), now: 10)
        XCTAssertNil(f.swapDue(now: 10 + MapFollow.maxWaitS - 1, still: false))
        XCTAssertEqual(f.swapDue(now: 10 + MapFollow.maxWaitS, still: false)?.rev, 4)
        XCTAssertLessThanOrEqual(MapFollow.maxWaitS, 60)          // plan M1 gate: swap ≤ 60 s after the mesh is ready
    }

    func testFirstMapOfTheRunSwapsAtOnceWithoutToast() {
        var f = MapFollow()
        XCTAssertNil(f.followVersion)
        XCTAssertTrue(f.offer(head(7)))
        f.didPrefetch(head(7), now: 0)
        XCTAssertEqual(f.swapDue(now: 0, still: false)?.rev, 7)  // nothing shown: no reason to wait
        XCTAssertNil(f.didSwap(head(7)))
        XCTAssertEqual(f.followVersion, 7)
    }

    func testANewerHeadSupersedesAStagedOne() {
        var f = MapFollow(cached: head(1))
        f.offer(head(2))
        f.didPrefetch(head(2), now: 0)
        XCTAssertTrue(f.offer(head(3)))
        f.didPrefetch(head(2), now: 1)                           // a late duplicate never replaces...
        f.didPrefetch(head(3), now: 2)
        XCTAssertEqual(f.staged?.rev, 3)
        f.didPrefetch(head(2), now: 3)                           // ...nor downgrades the staged head
        XCTAssertEqual(f.staged?.rev, 3)
        XCTAssertEqual(f.didSwap(head(3)), "Map updated · rev 3")
        XCTAssertNil(f.swapDue(now: 4, still: true))
    }

    func testCachedHeadThatIsNotUsableIsIgnored() {
        XCTAssertNil(MapFollow(cached: head(nil, pending: 2)).shown)
    }

    func testRoundTripsThroughJSONForTheLaunchCache() throws {
        let h = head(14, etag: "14-5", pending: 15)
        let d = try JSONEncoder().encode(h)
        XCTAssertEqual(MapHead.decode(d), h)
    }

    func testARContentFollowsTheLockFrame() {
        XCTAssertEqual(ARContentPick.version(lock: nil, follow: 14), 14)      // before the lock: preload the head
        XCTAssertEqual(ARContentPick.version(lock: 14, follow: 14), 14)
        XCTAssertEqual(ARContentPick.version(lock: 13, follow: 14), 13)       // localizer still on 13: its frame
        XCTAssertEqual(ARContentPick.version(lock: 15, follow: 14), 14)       // localizer ahead: newest BUILT only
        XCTAssertEqual(ARContentPick.version(lock: 12, follow: nil), 12)      // old server (no head): as before
        XCTAssertNil(ARContentPick.version(lock: nil, follow: nil))
    }

    func testStillDetector() {
        var s = StillDetector()
        for i in 0...10 { s.add(t: Double(i) * 0.1, position: [0.001 * Double(i), 0, 0], yawDeg: 0) }
        XCTAssertTrue(s.isStill(now: 1.0))
        var w = StillDetector()                                  // walking 1 m/s
        for i in 0...10 { w.add(t: Double(i) * 0.1, position: [0.1 * Double(i), 0, 0], yawDeg: 0) }
        XCTAssertFalse(w.isStill(now: 1.0))
        var r = StillDetector()                                  // turning on the spot 60 °/s (wraps 359 → 1)
        for i in 0...10 { r.add(t: Double(i) * 0.1, position: [0, 0, 0], yawDeg: (350 + 6 * Double(i)).truncatingRemainder(dividingBy: 360)) }
        XCTAssertFalse(r.isStill(now: 1.0))
        var short = StillDetector()                              // too little history yet
        short.add(t: 0, position: [0, 0, 0], yawDeg: 0)
        XCTAssertFalse(short.isStill(now: 0.1))
    }
}
