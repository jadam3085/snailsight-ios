import XCTest
@testable import SnailSightCore

/// 12.26: zlib inflate + the ssq1 Layer B transport against vectors from the server's own encoder (WireQFixtures),
/// and the subscription choice (requirement 2026-11-13 R1-R4, acceptance A1/A4/A5).
final class WireQTests: XCTestCase {
    func testInflateVectors() throws {
        let plain = Data(base64Encoded: WireQFixtures.zPlain)!
        XCTAssertEqual(try Inflate.zlib(Data(base64Encoded: WireQFixtures.zDynamic)!), plain)
        XCTAssertEqual(try Inflate.zlib(Data(base64Encoded: WireQFixtures.zStored)!), plain)
        XCTAssertEqual(String(decoding: try Inflate.zlib(Data(base64Encoded: WireQFixtures.zFixed)!), as: UTF8.self),
                       "abcabcabcabc hello hello")
    }

    func testInflateRejectsCorruption() {
        var b = [UInt8](Data(base64Encoded: WireQFixtures.zDynamic)!)
        b[b.count - 1] ^= 0xFF                                       // Adler-32 trailer
        XCTAssertThrowsError(try Inflate.zlib(Data(b)))
        XCTAssertThrowsError(try Inflate.zlib(Data([0x78])))
        XCTAssertThrowsError(try Inflate.zlib(Data(b.prefix(20))))
    }

    func testUnpackEqualsServerDecoder() throws {
        let recs = try WireQ.unpack(Data(base64Encoded: WireQFixtures.q)!, origins: WireQFixtures.origins,
                                    cq: WireQFixtures.cq)
        let ref = try JSONSerialization.jsonObject(with: Data(WireQFixtures.refJSON.utf8)) as! [[String: Any]]
        XCTAssertEqual(recs.count, ref.count)
        for (ri, (r, e)) in zip(recs, ref).enumerated() {
            let u = (e["u"] as! [NSNumber]).map(\.intValue)
            let f = (e["f"] as! [NSNumber]).map(\.uint32Value)
            XCTAssertEqual(r.mesh.indices, f, "faces + winding")
            XCTAssertEqual(r.mesh.positions.count, u.count)
            let o = WireQFixtures.origins[ri]
            for (i, p) in r.mesh.positions.enumerated() {
                XCTAssertEqual(Int(((Double(p) - o[i % 3]) * 1000).rounded()), u[i])
            }
            if let c = e["c"] as? [NSNumber] {
                XCTAssertEqual(r.rgb, c.map(\.uint8Value))
            } else {
                XCTAssertNil(r.rgb)
            }
        }
    }

    func testSurfaceFrameSSQ1EqualsF32Frame() throws {
        let f = try XCTUnwrap(SurfaceFrame.parse(Data(WireQFixtures.tileSSQ1.utf8)))
        XCTAssertTrue(SurfaceFrame.isSurface(Data(WireQFixtures.tileSSQ1.utf8)))
        XCTAssertTrue(f.ssq1)
        let summ = try JSONSerialization.jsonObject(with: Data(WireQFixtures.tileF32Summary.utf8)) as! [[String: Any]]
        XCTAssertEqual(f.blocks.count, summ.count)
        for (b, s) in zip(f.blocks, summ) {
            let k = (s["b"] as! [NSNumber]).map(\.intValue)
            XCTAssertEqual(b.key, BlockKey(k[0], k[1], k[2]))
            XCTAssertEqual(b.surface, (s["s"] as! String) == "surface")
            let nv = (s["nv"] as! NSNumber).intValue
            guard nv > 0 else { XCTAssertNil(b.mesh); continue }
            let m = try XCTUnwrap(b.mesh)
            XCTAssertEqual(m.vertexCount, nv)
            XCTAssertEqual(m.triangleCount, (s["nt"] as! NSNumber).intValue)
            let want = (s["sum_mm"] as! [NSNumber]).map(\.intValue)
            for c in 0..<3 {
                var sum = 0
                for v in 0..<nv { sum += Int((Double(m.positions[v * 3 + c]) * 1000).rounded()) }
                XCTAssertLessThanOrEqual(abs(sum - want[c]), nv, "≤ 1 mm per vertex (f32 is unquantised)")
            }
            if let sc = s["sum_rgb"] as? [NSNumber] {
                let rgb = try XCTUnwrap(b.rgb)
                for c in 0..<3 {
                    var sum = 0
                    for v in 0..<nv { sum += Int(rgb[v * 3 + c]) }
                    XCTAssertLessThanOrEqual(abs(sum - sc[c].intValue), 2 * nv, "colour bins of 4")
                }
            }
        }
        // the store applies it like an f32 frame
        var st = LayerBStore()
        guard case .applied(let changed, true) = st.apply(f, now: 1) else { return XCTFail("not applied") }
        XCTAssertEqual(changed.count, f.blocks.count)
        XCTAssertNotNil(st.tileMesh(f.key))
    }

    func testCorruptSSQ1FrameIsRejectedNotMisdrawn() {
        var s = WireQFixtures.tileSSQ1
        if let r = s.range(of: "\"q\":\"") { s.replaceSubrange(r.upperBound..<s.index(r.upperBound, offsetBy: 8), with: "AAAAAAAA") }
        XCTAssertNil(SurfaceFrame.parse(Data(s.utf8)))
    }

    func testSubscriptionChoice() throws {
        let old = ServerFeatures(["live_downlink"])
        let lb = ServerFeatures(["live_downlink", "live_surface"])
        let q = ServerFeatures(["live_downlink", "live_surface", "live_surface_ssq1"])
        XCTAssertEqual(LiveLayers.house(old, estimated: false), ["corrections", "agents", "changes", "docs", "mesh", "surface"])
        XCTAssertEqual(LiveLayers.house(lb, estimated: true), ["corrections", "agents", "changes", "docs", "surface", "estimated"])
        XCTAssertFalse(LiveLayers.house(q, estimated: false).contains("mesh"))
        XCTAssertEqual(LiveLayers.island(old), ["corrections", "mesh"])
        XCTAssertEqual(LiveLayers.island(lb), ["corrections", "surface"])
        XCTAssertNil(LiveLayers.surfaceEnc(lb))
        XCTAssertEqual(LiveLayers.surfaceEnc(q), "ssq1")
        let m = LiveSubscribe.message(agentID: "a", mapID: "site", baseVersion: 3, tiles: [:],
                                      layers: LiveLayers.house(q, estimated: false), surfaceEnc: LiveLayers.surfaceEnc(q))
        let o = try JSONSerialization.jsonObject(with: m) as! [String: Any]
        XCTAssertEqual(o["surface_enc"] as? String, "ssq1")
        XCTAssertEqual(o["hmask"] as? Int, 1)
        XCTAssertFalse((o["layers"] as! [String]).contains("mesh"))
        let m2 = LiveSubscribe.message(agentID: "a", mapID: "site", baseVersion: 3, tiles: [:])
        XCTAssertNil((try JSONSerialization.jsonObject(with: m2) as! [String: Any])["surface_enc"], "old servers: unchanged")
    }
}
