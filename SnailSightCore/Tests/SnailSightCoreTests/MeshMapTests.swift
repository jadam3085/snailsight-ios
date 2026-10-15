import XCTest
@testable import SnailSightCore

final class MeshMapTests: XCTestCase {
    /// Row-major camera → world: translation (x, y, z), yaw `deg` about +Y.
    private func pose(_ x: Double, _ y: Double = 0, _ z: Double = 0, yawDeg: Double = 0) -> [Double] {
        let a = yawDeg * .pi / 180, c = cos(a), s = sin(a)
        return [c, 0, s, x, 0, 1, 0, y, -s, 0, c, z, 0, 0, 0, 1]
    }

    func testIds() {
        let id = MeshMapID.make(date: Date(timeIntervalSince1970: 1_792_000_000), random: 0xABCDEF12)
        XCTAssertEqual(id, "mm-20261014-174640-cdef12")
        XCTAssertTrue(MeshMapID.isValid(id))
        XCTAssertFalse(MeshMapID.isValid("mm-ab"))
        XCTAssertFalse(MeshMapID.isValid("mm-has space"))
        XCTAssertFalse(MeshMapID.isValid("s-20261015"))
    }

    func testChunkRoundTrip() throws {
        let al = MeshMapAlign(T: pose(1, 0, 2), version: 10, method: "visual+mesh", errCm: 1.5)
        let h = MeshMapChunk.frameHeader(kind: .keyframe, seq: 7, streamID: "ar-0000abcd", t: 12.5, wall: 1000,
                                         T: pose(0.5), K: [1400, 1400, 960, 720], imageSize: [1920, 1440], align: al,
                                         sharpness: 210, blurPx: .nan)
        let d = try XCTUnwrap(MeshMapChunk.encode(header: h, blobs: [("depth_png", Data([1, 2, 3])),
                                                                     ("rgb_jpg", Data([9, 9]))]))
        XCTAssertEqual(Array(d.prefix(4)), Array("SSMM".utf8))
        let (hdr, blobs) = try XCTUnwrap(MeshMapChunk.parse(d))
        XCTAssertEqual(hdr["kind"] as? String, "keyframe")
        XCTAssertEqual(hdr["seq"] as? Int, 7)
        XCTAssertEqual(hdr["map_version"] as? Int, 10)
        XCTAssertEqual(hdr["align_method"] as? String, "visual+mesh")
        XCTAssertEqual((hdr["T_map_arkit"] as? [Double])?[3], 1)
        XCTAssertNil(hdr["blur_px"])                               // non-finite numbers are dropped, never sent
        XCTAssertEqual(blobs.map(\.name), ["depth_png", "rgb_jpg"])
        XCTAssertEqual(blobs[1].data, Data([9, 9]))
        // the big-endian header length
        let n = Int(d[4]) << 24 | Int(d[5]) << 16 | Int(d[6]) << 8 | Int(d[7])
        XCTAssertEqual(d.count, 8 + n + 5)
        XCTAssertNil(MeshMapChunk.parse(d.dropLast()))             // truncated
        // no alignment = no map fields
        let h2 = MeshMapChunk.frameHeader(kind: .depth, seq: 0, streamID: "ar-1", t: 0, wall: 0, T: pose(0), K: [1, 1, 1, 1],
                                          imageSize: [1920, 1440], align: nil)
        XCTAssertNil(h2["T_map_arkit"])
        let a = MeshMapChunk.alignHeader(seq: 3, streamID: "ar-1", t: 1, wall: 2, align: al, spreadCm: 0.7)
        XCTAssertEqual(a["kind"] as? String, "align")
        XCTAssertEqual(a["spread_cm"] as? Double, 0.7)
        XCTAssertNotNil(MeshMapChunk.encode(header: a, blobs: []))
    }

    func testMeshChunkAndAnchorPack() throws {
        let v: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, -1.5, 2.25, 0]
        let f: [UInt32] = [0, 1, 2, 0, 2, 3]
        let blob = MeshAnchorPack.encode(vertices: v, faces: f)
        XCTAssertEqual(blob.count, 4 * 12 + 2 * 12)
        XCTAssertEqual(blob.prefix(8), Data([0, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(Array(blob[12..<16]), [0, 0, 0x80, 0x3F])     // 1.0f little-endian
        let back = try XCTUnwrap(MeshAnchorPack.decode(blob, vertices: 4, faces: 2))
        XCTAssertEqual(back.vertices, v)
        XCTAssertEqual(back.faces, f)
        XCTAssertNil(MeshAnchorPack.decode(blob, vertices: 5, faces: 2))
        let h = MeshMapChunk.meshHeader(seq: 2, streamID: "ar-1", t: 0, wall: 0,
                                        anchors: [MeshAnchorEntry(id: "A-1", T: pose(1), vertices: 4, faces: 2)])
        let d = try XCTUnwrap(MeshMapChunk.encode(header: h, blobs: [("a0", blob)]))
        let (hdr, blobs) = try XCTUnwrap(MeshMapChunk.parse(d))
        let a = try XCTUnwrap((hdr["anchors"] as? [[String: Any]])?.first)
        XCTAssertEqual(a["blob"] as? String, "a0")
        XCTAssertEqual(a["faces"] as? Int, 2)
        XCTAssertEqual(blobs.first?.data, blob)
    }

    func testAnchorTracker() {
        var t = MeshAnchorTracker()
        XCTAssertTrue(t.wants(id: "a", vertices: 100, now: 0))
        XCTAssertFalse(t.wants(id: "a", vertices: 0, now: 0))
        t.didSend(id: "a", vertices: 100, now: 0)
        XCTAssertFalse(t.wants(id: "a", vertices: 200, now: 5))          // too soon
        XCTAssertFalse(t.wants(id: "a", vertices: 110, now: 20))         // too small a change
        XCTAssertTrue(t.wants(id: "a", vertices: 120, now: 20))
        t.removed(id: "a")
        XCTAssertTrue(t.wants(id: "a", vertices: 100, now: 21))
    }

    func testGateDepthRateAndStillness() {
        var g = MeshMapGate()
        // first frame: a keyframe (sharp)
        XCTAssertEqual(g.decide(t: 0, T: pose(0), blurPx: 1), .keyframe)
        g.commit(.keyframe, t: 0, T: pose(0))
        XCTAssertEqual(g.decide(t: 0.2, T: pose(0.3), blurPx: 1), .skip)          // 2 Hz: too soon
        XCTAssertEqual(g.decide(t: 0.6, T: pose(0.05), blurPx: 1), .skip)         // still: < 10 cm, < 8°
        XCTAssertEqual(g.decide(t: 0.6, T: pose(0.15), blurPx: 1), .depth)
        g.commit(.depth, t: 0.6, T: pose(0.15))
        XCTAssertEqual(g.decide(t: 1.2, T: pose(0.15, yawDeg: 10), blurPx: 1), .depth)  // a turn counts
        // hot: 1 Hz
        var h = MeshMapGate()
        h.commit(.keyframe, t: 0, T: pose(0))
        XCTAssertEqual(h.decide(t: 0.6, T: pose(0.2), blurPx: 1, hot: true), .skip)
        XCTAssertEqual(h.decide(t: 1.01, T: pose(0.2), blurPx: 1, hot: true), .depth)
    }

    func testGateKeyframeSpacingAndBlur() {
        var g = MeshMapGate()
        g.commit(.keyframe, t: 0, T: pose(0))
        // 0.8 m away and > 0.8 s later: due, but blurry -> depth only, the keyframe waits
        XCTAssertEqual(g.decide(t: 1.0, T: pose(0.8), blurPx: 4), .depth)
        g.commit(.depth, t: 1.0, T: pose(0.8))
        XCTAssertEqual(g.kfDueSince, 1.0)
        XCTAssertEqual(g.decide(t: 1.6, T: pose(0.95), blurPx: 1.5), .keyframe)   // sharp now
        g.commit(.keyframe, t: 1.6, T: pose(0.95))
        XCTAssertNil(g.kfDueSince)
        // waited 1.5 s with blur 4 px: accepted late (≤ 6 px), but never 9 px
        var w = MeshMapGate()
        w.commit(.keyframe, t: 0, T: pose(0))
        _ = w.decide(t: 2.0, T: pose(0, yawDeg: 25), blurPx: 9)
        XCTAssertNotEqual(w.decide(t: 3.6, T: pose(0, yawDeg: 27), blurPx: 9), .keyframe)
        XCTAssertEqual(w.decide(t: 3.7, T: pose(0, yawDeg: 28), blurPx: 4), .keyframe)
        // a turn of 20° alone makes one due
        var r = MeshMapGate()
        r.commit(.keyframe, t: 0, T: pose(0))
        XCTAssertEqual(r.decide(t: 1, T: pose(0, yawDeg: 21), blurPx: 0.5), .keyframe)
        var bad = MeshMapGate()
        XCTAssertEqual(bad.decide(t: 0, T: [1, 2], blurPx: 0), .skip)            // malformed pose
    }

    func testPolicy() {
        XCTAssertTrue(MeshMapPolicy.wanted(toggle: true, auto: false, localized: false))
        XCTAssertFalse(MeshMapPolicy.wanted(toggle: false, auto: true, localized: false))
        XCTAssertTrue(MeshMapPolicy.wanted(toggle: false, auto: true, localized: true))
        XCTAssertFalse(MeshMapPolicy.wanted(toggle: false, auto: false, localized: true))   // off by default
        XCTAssertEqual(MeshMapPolicy.pauseReason(recording: true, scansOpen: false, thermalCritical: true,
                                                 trackingNormal: true, meshSupported: true, depthSupported: true,
                                                 spoolFull: false), "recording")
        XCTAssertEqual(MeshMapPolicy.pauseReason(recording: false, scansOpen: false, thermalCritical: true,
                                                 trackingNormal: false, meshSupported: true, depthSupported: true,
                                                 spoolFull: false), "too hot")
        XCTAssertNil(MeshMapPolicy.pauseReason(recording: false, scansOpen: false, thermalCritical: false,
                                               trackingNormal: true, meshSupported: true, depthSupported: true,
                                               spoolFull: false))
        XCTAssertEqual(MeshMapPolicy.pauseReason(recording: false, scansOpen: false, thermalCritical: false,
                                                 trackingNormal: true, meshSupported: false, depthSupported: true,
                                                 spoolFull: false), "no LiDAR")
    }

    func testLedger() throws {
        var l = MeshMapLedger(uploadID: "mm-x", mapID: "site", created: 0)
        XCTAssertEqual(l.add(.keyframe, bytes: 400_000, now: 1), 0)
        XCTAssertEqual(l.add(.depth, bytes: 60_000, now: 1), 1)
        XCTAssertEqual(l.add(.mesh, bytes: 100_000, now: 1), 2)
        XCTAssertEqual(l.pending, 3)
        XCTAssertEqual(l.keyframes, 1)
        XCTAssertEqual(l.frames, 2)
        l.acked(haveContiguous: 1, bytes: 460_000, now: 2)
        l.acked(haveContiguous: 0, bytes: 0, now: 3)                   // never goes backwards
        XCTAssertEqual(l.ackedThrough, 1)
        XCTAssertEqual(l.pending, 1)
        XCTAssertFalse(l.readyToFinish)
        l.stopCapture(now: 4)
        XCTAssertEqual(l.lastSeq, 2)
        XCTAssertEqual(l.state, .finishing)
        XCTAssertFalse(l.readyToFinish)
        l.acked(haveContiguous: 2, bytes: 100_000, now: 5)
        XCTAssertTrue(l.readyToFinish)
        // persisted as JSON
        let back = try JSONDecoder().decode(MeshMapLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
        // nothing captured
        var e = MeshMapLedger(uploadID: "mm-y", mapID: "site", created: 0)
        e.stopCapture(now: 1)
        XCTAssertEqual(e.lastSeq, -1)
        XCTAssertTrue(e.readyToFinish)
    }

    func testWording() {
        var l = MeshMapLedger(uploadID: "mm-x", mapID: "site", created: 0)
        for _ in 0..<12 { _ = l.add(.keyframe, bytes: 2_000_000, now: 0) }
        for _ in 0..<40 { _ = l.add(.depth, bytes: 250_000, now: 0) }
        l.acked(haveContiguous: 51, bytes: 0, now: 0)
        XCTAssertEqual(MeshMapText.line(capturing: true, paused: nil, ledger: l, online: true), "mapping · 32 MB · 12 kf")
        XCTAssertEqual(MeshMapText.line(capturing: true, paused: "too hot", ledger: l, online: true),
                       "mapping · paused (too hot) · 32 MB · 12 kf")
        _ = l.add(.depth, bytes: 1000, now: 0)
        XCTAssertEqual(MeshMapText.line(capturing: true, paused: nil, ledger: l, online: false),
                       "mapping · 32 MB · 12 kf · offline, 1 queued")
        l.stopCapture(now: 0)
        XCTAssertEqual(MeshMapText.line(capturing: false, paused: nil, ledger: l, online: true), "uploading map · 1 left")
        l.state = .done
        l.resultVersion = 11
        XCTAssertEqual(MeshMapText.line(capturing: false, paused: nil, ledger: l, online: true), "map updated v11 ✓")
        XCTAssertNil(MeshMapText.line(capturing: false, paused: nil, ledger: nil, online: true))
    }

    func testServerStatusDecode() throws {
        let json = """
        {"upload_id":"mm-20261015-142233-a1b2c3","agent_id":"phone-1","map_id":"site","state":"done","chunks":120,
         "have_contiguous":119,"bytes":35000000,"counts":{"depth":90,"keyframe":12,"mesh":15,"align":3},
         "job":{"job_id":412,"state":"done"},
         "result":{"map_id":"site","base_version":10,"version":11,"cells":[[0,-3],[1,-3]],"frames_used":98,
                   "keyframes_used":12,"frames_skipped":4,"triangles_added":180000,"refined":{"ok":10}},
         "error":null}
        """
        let s = try JSONDecoder().decode(MeshMapStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.result?.version, 11)
        XCTAssertEqual(s.job?.jobID, 412)
        XCTAssertEqual(MeshMapText.done(s), "House map updated · v11 · 2 areas re-meshed · 12 photos")
        let f = try JSONDecoder().decode(MeshMapStatus.self,
                                         from: Data(#"{"upload_id":"mm-x","state":"failed","error":"no base map"}"#.utf8))
        XCTAssertEqual(MeshMapText.done(f), "Map update failed: no base map")
    }
}
