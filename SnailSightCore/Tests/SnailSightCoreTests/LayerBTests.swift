import XCTest
@testable import SnailSightCore

final class LayerBTests: XCTestCase {
    /// base64(<u32 nv><u32 nt> f32 xyz, u32 idx) of one triangle inside block b (0.4 m blocks).
    private func tri(_ b: [Int]) -> String {
        let o = b.map { Float($0) * 0.4 + 0.1 }
        let pos: [Float] = [o[0], o[1], o[2], o[0] + 0.1, o[1], o[2], o[0], o[1] + 0.1, o[2]]
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(3); u32(1)
        for p in pos { u32(p.bitPattern) }
        for i: UInt32 in [0, 1, 2] { u32(i) }
        return d.base64EncodedString()
    }

    private func frame(since: Int?, seq: Int, blocks: [(b: [Int], s: String)], removed: [[Int]] = [], rgb: Bool = false) -> Data {
        let bl = blocks.map { e -> String in
            var s = #"{"b":[\#(e.b[0]),\#(e.b[1]),\#(e.b[2])],"s":"\#(e.s)","rev":\#(seq),"tracked":3,"src":"live""#
            if e.s == "surface" {
                s += #","nv":3,"nt":1,"data":"\#(tri(e.b))""#
                if rgb { s += #","rgb":"\#(Data([255, 0, 0, 0, 255, 0, 0, 0, 255]).base64EncodedString())""# }
            } else { s += #","nv":0,"nt":0"# }
            return s + "}"
        }.joined(separator: ",")
        let rm = removed.map { "[\($0[0]),\($0[1]),\($0[2])]" }.joined(separator: ",")
        let sinceS = since.map(String.init) ?? "null"
        let json = #"{"type":"tile","layer":"surface","key":"0/0/0","level":0,"tx":0,"ty":0,"ver":{"base_version":14,"live_seq":\#(seq)},"since":\#(sinceS),"enc":"ssmesh1+zlib","voxel_m":0.04,"block_m":0.4,"blocks":[\#(bl)],"removed":[\#(rm)],"hw":{"phone-1/ar-1":12},"hw_wall":100.5,"stages":{"capture_to_commit_ms":850}}"#
        return Data(json.utf8)
    }

    func testFullDeltaRemovedAndGap() throws {
        var st = LayerBStore()
        let full = try XCTUnwrap(SurfaceFrame.parse(frame(since: nil, seq: 10, blocks: [([1, 2, 3], "surface"), ([2, 2, 3], "empty")], rgb: true)))
        XCTAssertTrue(SurfaceFrame.isSurface(frame(since: nil, seq: 10, blocks: [])))
        XCTAssertEqual(full.captureToCommitMs, 850)
        XCTAssertEqual(full.agents, ["phone-1"])
        XCTAssertEqual(full.blocks[0].mesh?.triangleCount, 1)
        XCTAssertEqual(full.blocks[0].rgb?.count, 9)
        XCTAssertEqual(st.apply(full, now: 1), .applied(changed: [BlockKey(1, 2, 3), BlockKey(2, 2, 3)], full: true))
        XCTAssertEqual(st.blockCount, 2)
        XCTAssertEqual(st.surfaceBlocks, 1)
        // a base face inside the empty cube and one inside the surface cube are hidden, one outside is not
        let (mask, n) = st.hiddenFaces(centroids: [0.9, 0.9, 1.3, 0.5, 0.9, 1.3, 5, 5, 5])
        XCTAssertEqual(mask, [true, true, false])
        XCTAssertEqual(n, 2)
        // delta on top of 10: the empty cube is removed, a new surface block added
        let d = try XCTUnwrap(SurfaceFrame.parse(frame(since: 10, seq: 12, blocks: [([1, 3, 3], "surface")], removed: [[2, 2, 3]])))
        XCTAssertEqual(st.apply(d, now: 2), .applied(changed: [BlockKey(1, 3, 3), BlockKey(2, 2, 3)], full: false))
        XCTAssertFalse(st.supersedes(x: 0.9, y: 0.9, z: 1.3))
        XCTAssertEqual(st.held["0/0/0"], TileVer(base: 14, seq: 12))
        let m = try XCTUnwrap(st.tileMesh("0/0/0"))
        XCTAssertEqual(m.mesh.triangleCount, 2)
        XCTAssertEqual(m.mesh.indices, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(m.rgb?.count, 18)                                 // one coloured block + one grey block
        // a delta on top of 20 (missed 13…20): gap, nothing applied
        let g = try XCTUnwrap(SurfaceFrame.parse(frame(since: 20, seq: 25, blocks: [([9, 9, 9], "surface")])))
        XCTAssertEqual(st.apply(g, now: 3), .gap(held: 12, since: 20))
        XCTAssertFalse(st.supersedes(x: 3.7, y: 3.7, z: 3.7))
        // an old re-send (since older than held) is harmless
        let old = try XCTUnwrap(SurfaceFrame.parse(frame(since: 8, seq: 12, blocks: [])))
        if case .gap = st.apply(old, now: 4) { XCTFail("older since must apply") }
        // a full frame drops everything first
        let f2 = try XCTUnwrap(SurfaceFrame.parse(frame(since: nil, seq: 30, blocks: [([0, 0, 0], "empty")])))
        _ = st.apply(f2, now: 5)
        XCTAssertEqual(st.blockCount, 1)
        XCTAssertEqual(st.tileMesh("0/0/0")?.mesh.triangleCount, 0)
    }

    func testDeltaWithoutHeldTileIsAGap() throws {
        var st = LayerBStore()
        let d = try XCTUnwrap(SurfaceFrame.parse(frame(since: 3, seq: 5, blocks: [([1, 1, 1], "surface")])))
        XCTAssertEqual(st.apply(d, now: 0), .gap(held: nil, since: 3))
    }

    func testEpochResets() throws {
        var st = LayerBStore()
        st.setEpoch("a")
        _ = st.apply(try XCTUnwrap(SurfaceFrame.parse(frame(since: nil, seq: 1, blocks: [([1, 1, 1], "surface")]))), now: 0)
        st.setEpoch("a")
        XCTAssertEqual(st.blockCount, 1)
        st.setEpoch("b")
        XCTAssertEqual(st.blockCount, 0)
        XCTAssertNil(SurfaceFrame.parse(Data(#"{"type":"tile","layer":"mesh","key":"0/0/0"}"#.utf8)))
    }

    func testStagesLine() {
        var s = LiveStages()
        XCTAssertNil(s.short)
        XCTAssertTrue(s.ack(["seq": 5, "stages": ["seq": 4, "ms": ["ingest": 120, "align": 640, "mesh": 900, "publish": 1900,
                                                                  "extra": 5], "total_ms": 1900],
                             "gate": ["state": "trusted", "why": NSNull()]]))
        XCTAssertFalse(s.ack(["seq": 6]))
        s.tileArrived(hwWall: 100, now: 102.1)
        XCTAssertEqual(s.short, "capture→phone 2.1 s · server 1.9 s · gate trusted")
        s.tileDrawn(hwWall: 100, now: 102.2)
        XCTAssertEqual(s.short, "capture→drawn 2.2 s · server 1.9 s · gate trusted")
        XCTAssertEqual(s.detail, "ingest 120 ms → align 640 ms → mesh 900 ms → publish 1.9 s → extra 5 ms → phone 2.1 s → drawn 2.2 s · gate trusted · kf 4")
        s.tileArrived(hwWall: 100, now: 5000)                           // 81 min: a clock problem, ignored
        XCTAssertEqual(s.phoneMs ?? 0, 2100, accuracy: 0.01)
    }

    /// 12.24: the server's `hm` voxel mask (live 0.12): voxels 0, 123 and 999 set (python layerb.hm_encode).
    static let hm0_123_999 = "AQAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA="

    func testHideMaskOnlyHidesSetVoxels() throws {
        let m = try XCTUnwrap(HideMask.decode(Self.hm0_123_999))
        XCTAssertTrue(HideMask.bit(m, 0, 0, 0))
        XCTAssertTrue(HideMask.bit(m, 1, 2, 3))
        XCTAssertTrue(HideMask.bit(m, 9, 9, 9))
        XCTAssertFalse(HideMask.bit(m, 3, 2, 1))
        XCTAssertNil(HideMask.decode("AAAA"))                      // malformed: the whole cube (old rule)
        // block [1, 2, -1] masked (an empty block on a real floor), block [2, 2, 3] whole
        let json = #"{"type":"tile","layer":"surface","key":"0/0/0","level":0,"tx":0,"ty":0,"ver":{"base_version":14,"live_seq":5},"since":null,"hmask":"vox1","block_m":0.4,"blocks":[{"b":[1,2,-1],"s":"empty","rev":5,"nv":0,"nt":0,"hm":"\#(Self.hm0_123_999)"},{"b":[2,2,3],"s":"empty","rev":5,"nv":0,"nt":0}],"removed":[]}"#
        let f = try XCTUnwrap(SurfaceFrame.parse(Data(json.utf8)))
        XCTAssertNotNil(f.blocks[0].hideMask)
        XCTAssertNil(f.blocks[1].hideMask)
        var st = LayerBStore()
        _ = st.apply(f, now: 1)
        XCTAssertEqual(st.maskedBlocks, 1)
        // block [1, 2, -1] spans x 0.4..0.8, y 0.8..1.2, z -0.4..0; voxel (1, 2, 3) = x 0.44..0.48, y 0.88..0.92, z -0.28..-0.24
        XCTAssertTrue(st.supersedes(x: 0.46, y: 0.90, z: -0.26))
        XCTAssertTrue(st.supersedes(x: 0.41, y: 0.81, z: -0.39))     // voxel 0
        XCTAssertFalse(st.supersedes(x: 0.60, y: 1.00, z: -0.20))    // the rest of the block: base stays drawn
        XCTAssertTrue(st.supersedes(x: 0.9, y: 0.9, z: 1.3))         // mask-less block: the whole cube
        let (mask, n) = st.hiddenFaces(centroids: [0.46, 0.90, -0.26, 0.60, 1.00, -0.20])
        XCTAssertEqual(mask, [true, false])
        XCTAssertEqual(n, 1)
        // the block turns mask-less (whole cube), then is removed: no stale mask
        let d = #"{"type":"tile","layer":"surface","key":"0/0/0","level":0,"tx":0,"ty":0,"ver":{"base_version":14,"live_seq":6},"since":5,"block_m":0.4,"blocks":[{"b":[1,2,-1],"s":"empty","rev":6}],"removed":[]}"#
        _ = st.apply(try XCTUnwrap(SurfaceFrame.parse(Data(d.utf8))), now: 2)
        XCTAssertEqual(st.maskedBlocks, 0)
        XCTAssertTrue(st.supersedes(x: 0.60, y: 1.00, z: -0.20))
        let r = #"{"type":"tile","layer":"surface","key":"0/0/0","level":0,"tx":0,"ty":0,"ver":{"base_version":14,"live_seq":7},"since":6,"block_m":0.4,"blocks":[],"removed":[[1,2,-1]]}"#
        _ = st.apply(try XCTUnwrap(SurfaceFrame.parse(Data(r.utf8))), now: 3)
        XCTAssertFalse(st.supersedes(x: 0.46, y: 0.90, z: -0.26))
    }

    func testSubscribeAsksForMasks() throws {
        let d = LiveSubscribe.message(agentID: "p", mapID: "site", baseVersion: 1, tiles: [:])
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(o["hmask"] as? Int, 1)
    }
}

/// Replay of the server's own Layer B frames (services/snailsight/layerb.py integrating a REAL recorded phone stream,
/// dumped by snailCOP scratch layerb_frames.py): every delta in arrival order must end in exactly the state of the
/// final full frames, and a dropped delta must be caught as a gap. Skipped unless SNAILSIGHT_LAYERB_REPLAY is set.
final class LayerBReplayTests: XCTestCase {
    func testServerFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAILSIGHT_LAYERB_REPLAY"] else {
            throw XCTSkip("set SNAILSIGHT_LAYERB_REPLAY to a layerb_frames.py dump")
        }
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let frames = (o["frames"] as! [String]).map { Data($0.utf8) }
        let finals = (o["finals"] as! [String]).map { Data($0.utf8) }
        var live = LayerBStore(), ref = LayerBStore()
        var applied = 0, gaps = 0, deltas = 0
        let t0 = Date()
        for d in frames {
            XCTAssertTrue(SurfaceFrame.isSurface(d))
            let f = try XCTUnwrap(SurfaceFrame.parse(d))
            if f.since != nil { deltas += 1 }
            switch live.apply(f, now: 0) {
            case .applied: applied += 1
            case .gap: gaps += 1
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        for d in finals { _ = ref.apply(try XCTUnwrap(SurfaceFrame.parse(d)), now: 0) }
        XCTAssertEqual(gaps, 0)
        XCTAssertEqual(live.superseded, ref.superseded)
        // tiles the server allocated but never revised (live_seq 0, no block states) are never sent: ignore them
        let refKeys = Set(ref.tiles.filter { !$0.value.blocks.isEmpty }.keys)
        XCTAssertEqual(Set(live.tiles.filter { !$0.value.blocks.isEmpty }.keys), refKeys)
        var tris = 0
        for k in refKeys {
            XCTAssertEqual(live.tiles[k]?.ver, ref.tiles[k]?.ver, k)
            let a = live.tileMesh(k)?.mesh.triangleCount, b = ref.tileMesh(k)?.mesh.triangleCount
            XCTAssertEqual(a, b, k)
            tris += b ?? 0
        }
        // a client that missed one delta of a tile sees the next one as a gap
        var lossy = LayerBStore()
        var dropped: String?
        var caught = false
        for d in frames {
            let f = try XCTUnwrap(SurfaceFrame.parse(d))
            if dropped == nil, f.since != nil { dropped = f.key; continue }
            if case .gap = lossy.apply(f, now: 0), f.key == dropped { caught = true }
        }
        XCTAssertTrue(caught || dropped == nil)
        print("LAYERB_REPLAY frames \(frames.count) (deltas \(deltas)) applied \(applied) tiles \(ref.tiles.count) " +
              "cubes \(ref.blockCount) surface_blocks \(ref.surfaceBlocks) triangles \(tris) gap_caught \(caught) " +
              String(format: "apply_ms_total %.1f", ms))
    }
}
