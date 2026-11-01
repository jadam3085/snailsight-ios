import XCTest
@testable import SnailSightCore

final class SurfaceConfirmTests: XCTestCase {
    private let ident = Align4(x: 0, y: 0, z: 0, yaw: 0)
    private let eye: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    /// map (x, y, z) for an ARKit world point under the identity alignment (world = (x, z, −y)).
    private func mapPoint(_ p: [Float]) -> [Float] { [p[0], -p[2], p[1]] }

    private func flat(_ d: Float, w: Int = 64, h: Int = 48) -> ([Float], [Float]) {
        ([Float](repeating: d, count: w * h), [50, 50, Float(w) / 2, Float(h) / 2])
    }

    func testOnlyFacesOnTheMeasuredSurfaceAreShown() {
        var h = DeviceSurfaceHits()
        let (d, K) = flat(2)
        let st = h.observe(depth: d, width: 64, height: 48, confidence: nil, K: K, camToWorld: eye, stride: 2)
        XCTAssertGreaterThan(st.created, 50)
        // on the wall, 3 cm off it, 50 cm in front (free space), 15 cm behind (hidden by the wall), outside the view
        let pts: [[Float]] = [[0, 0, -2.0], [0.1, 0.1, -2.03], [0, 0, -1.5], [0, 0, -2.15], [6, 0, -2]]
        var cf = ConfirmedFaces(id: "t", centroids: pts.flatMap { mapPoint($0) })
        let r = cf.update(hits: h, align: ident)
        XCTAssertEqual(r.shown, 2)
        XCTAssertEqual(cf.shown, [true, true, false, false, false])
        XCTAssertEqual(cf.hiddenMask, [false, false, true, true, true])
    }

    func testDepthThroughAConfirmedPlaceHidesItAgain() {
        var h = DeviceSurfaceHits()
        let (d, K) = flat(2)
        h.observe(depth: d, width: 64, height: 48, confidence: nil, K: K, camToWorld: eye, stride: 1)
        var cf = ConfirmedFaces(id: "t", centroids: mapPoint([0, 0, -2]))
        cf.update(hits: h, align: ident)
        XCTAssertEqual(cf.shown, [true])
        // the object moved away: later frames see 1 m deeper, straight through the old place
        let (d2, _) = flat(3)
        for _ in 0..<4 { h.observe(depth: d2, width: 64, height: 48, confidence: nil, K: K, camToWorld: eye, stride: 1) }
        let r = cf.update(hits: h, align: ident)
        XCTAssertEqual(r.hidden, 1)
        XCTAssertEqual(cf.shown, [false])
    }

    func testGrazingRaysAlongAWallDoNotUnconfirmIt() {
        // camera at the origin looking along −z; a wall at x = 0.5 fills the right half of the view (depth = z where
        // the ray meets it), a far wall at z = −4 the left half
        let w = 256, hh = 64
        let K: [Float] = [160, 160, 128, 32]
        var d = [Float](repeating: 4, count: w * hh)
        for v in 0..<hh { for u in 0..<w {
            let rx = (Float(u) + 0.5 - K[2]) / K[0]
            if rx > 0.52 / 4 { d[v * w + u] = 0.52 / rx }              // x = rx·z = 0.52 (mid-voxel)
        } }
        var h = DeviceSurfaceHits()
        for _ in 0..<6 { h.observe(depth: d, width: w, height: hh, confidence: nil, K: K, camToWorld: eye, stride: 1) }
        // wall faces 1.0 … 2.5 m along it, at eye height
        let wall = stride(from: Float(1.0), through: 2.5, by: 0.25).flatMap { mapPoint([0.52, 0, -$0]) }
        var cf = ConfirmedFaces(id: "w", centroids: wall)
        cf.update(hits: h, align: ident)
        XCTAssertEqual(cf.shownCount, cf.faceCount, "grazing passes must not cancel the wall's own returns")
    }

    func testEngineConfirmMeshStartsHiddenAndHideSeenMeshStartsDrawn() {
        var e = DeviceSurfaceEngine()
        let plan = MemPlan.plan(level: .normal, thermal: .nominal)
        let wall = [mapPoint([0, 0, -2]), mapPoint([0, 0, -1])].flatMap { $0 }
        let d0 = e.register(id: "base", centroids: wall, policy: .confirm, active: true, now: 0)
        XCTAssertEqual(d0?.hidden, [true, true])                     // nothing confirmed yet: nothing drawn
        XCTAssertNil(e.register(id: "live", centroids: wall, policy: .hideSeen, active: true, now: 0))
        let (d, K) = flat(2)
        let cy = e.observe(depth: d, width: 64, height: 48, confidence: nil, K: K, camToWorld: eye, align: ident,
                           plan: plan, now: 1.5, stride: 1)
        let byID = Dictionary(uniqueKeysWithValues: cy.deliveries.map { ($0.id, $0) })
        XCTAssertEqual(byID["base"]?.hidden, [false, true])          // the wall face is confirmed, the ghost is not
        XCTAssertEqual(byID["live"]?.hidden, [true, true])           // 12.18: both places observed
        let rs = Dictionary(uniqueKeysWithValues: e.reset(now: 1).map { ($0.id, $0) })
        XCTAssertEqual(rs["base"]?.hidden, [true, true])
        XCTAssertEqual(rs["live"]?.hidden, [])
    }

    func testEngineHidesWithoutWaitingForTheRebuildSpacing() {
        var e = DeviceSurfaceEngine()
        let plan = MemPlan.plan(level: .shed, thermal: .nominal)    // maskRebuildMinS 3 s
        _ = e.register(id: "b", centroids: mapPoint([0, 0, -2]), policy: .confirm, active: true, now: 0)
        let (d, K) = flat(2)
        let c1 = e.observe(depth: d, width: 64, height: 48, confidence: nil, K: K, camToWorld: eye, align: ident,
                           plan: plan, now: 5, stride: 1)
        XCTAssertEqual(c1.deliveries.first?.hidden, [false])
        let (d2, _) = flat(3)
        var hiddenAt: Double?
        for i in 1...6 where hiddenAt == nil {
            let c = e.observe(depth: d2, width: 64, height: 48, confidence: nil, K: K, camToWorld: eye, align: ident,
                              plan: plan, now: 5 + 0.4 * Double(i), stride: 1)
            if c.deliveries.first?.hidden == [true] { hiddenAt = 0.4 * Double(i) }
        }
        XCTAssertNotNil(hiddenAt)
        XCTAssertLessThan(hiddenAt ?? 99, plan.maskRebuildMinS)
    }

    func testRecordingNoLongerPausesLiveMap() {
        XCTAssertNil(LivePause.reason(recording: true, scansOpen: false, map3DOpen: false, thermalCritical: false,
                                      trackingNormal: true))
        XCTAssertEqual(LivePause.reason(recording: true, scansOpen: false, map3DOpen: false, thermalCritical: false,
                                        trackingNormal: true, pauseWhileRecording: true), "recording")
        XCTAssertEqual(LivePause.reason(recording: false, scansOpen: false, map3DOpen: false, thermalCritical: false,
                                        trackingNormal: false), "tracking")
    }

    func testTileHysteresisStopsBudgetEdgeSwaps() {
        func leaf(_ k: String, _ x: Double) -> TileNode {
            TileNode(key: k, size: 4, box: [x, 0, 1, 2, 0, 0, 0, 2, 0, 0, 0, 1.5], uri: "\(k).usdz", mem: 20 << 20)
        }
        let roots = [leaf("a", -6), leaf("b", 6), leaf("c", 0)]
        // budget for two tiles; the camera at x = 0 turns left / right while walking (heading prefetch)
        var loaded: Set<String> = []
        var swaps = [0, 0]
        for (vi, bonus) in [0.0, 4.0].enumerated() {
            loaded = []
            for i in 0..<20 {
                let hd: (Double, Double) = i % 2 == 0 ? (-1, 0) : (1, 0)
                let w = TileSelect.select(roots, cam: [0.3 * Double(i % 2 == 0 ? -1 : 1), 0, 1.4], heading: hd, speed: 0.6,
                                          nearBudget: 40 << 20, midBudget: 0, keep: loaded, keepBonusM: bonus)
                let now = Set(w.keys)
                if !loaded.isEmpty && now != loaded { swaps[vi] += 1 }
                loaded = now
            }
        }
        XCTAssertGreaterThan(swaps[0], 10)
        XCTAssertEqual(swaps[1], 0)
    }

    func testLiveOffTapRightAfterRecordStopAsksAgain() {
        // 10-31: Record stopped at 205.86 s, a Live-map-off quick_action arrived at 208.58 s
        XCTAssertEqual(LiveTapGuard.decide(now: 208.58, turningOn: false, lastRecordToggle: 205.86, pendingConfirmAt: nil), .confirm)
        XCTAssertEqual(LiveTapGuard.decide(now: 210.0, turningOn: false, lastRecordToggle: 205.86, pendingConfirmAt: 208.58), .apply)
        XCTAssertEqual(LiveTapGuard.decide(now: 230.0, turningOn: false, lastRecordToggle: 205.86, pendingConfirmAt: nil), .apply)
        XCTAssertEqual(LiveTapGuard.decide(now: 206.0, turningOn: true, lastRecordToggle: 205.86, pendingConfirmAt: nil), .apply)
        // a stale confirmation does not count
        XCTAssertEqual(LiveTapGuard.decide(now: 207.0, turningOn: false, lastRecordToggle: 205.0, pendingConfirmAt: 190), .confirm)
    }
}
