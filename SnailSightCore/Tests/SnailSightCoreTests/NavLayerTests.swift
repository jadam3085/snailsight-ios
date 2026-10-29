import XCTest
@testable import SnailSightCore

final class NavLayerTests: XCTestCase {
    private func b64(_ v: [UInt64]) -> String {
        var d = Data()
        for x in v { for b in 0..<8 { d.append(UInt8((x >> (8 * UInt64(b))) & 0xff)) } }
        return d.base64EncodedString()
    }

    func testDecodeAndClasses() throws {
        let n = 2
        // column 0: a box 0.3–0.6 m above the floor (bins (0.30+0.30)/0.05 = 12 … 17); column 1: free in the band;
        // column 2: only the floor occupied (bin 6, below the band) + free above; column 3: nothing known
        var occ = [UInt64](repeating: 0, count: n * n), free = occ
        for b in 12..<18 { occ[0] |= 1 << UInt64(b) }
        for b in 8..<26 { free[1] |= 1 << UInt64(b) }
        occ[2] = 1 << 6
        free[2] = 1 << 10
        let json = """
        {"map_id":"site","live":true,"rev":12,"tiles":[{"key":"0/1/-2","level":0,"tx":1,"ty":-2,"rev":3,"z0":-1.64,
         "vox":0.05,"nz":58,"nc":\(n),"t":1.0,"occ":"\(b64(occ))","free":"\(b64(free))"}]}
        """
        let doc = try JSONDecoder().decode(LiveNavDoc.self, from: Data(json.utf8))
        XCTAssertEqual(doc.rev, 12)
        let t = try XCTUnwrap(doc.tiles.first)
        XCTAssertEqual(t.occ, occ)
        XCTAssertEqual(t.floorZ, -1.34, accuracy: 1e-9)
        XCTAssertEqual(t.square, [0.1, -0.2, 0.2, -0.1])
        XCTAssertEqual(NavBand.classes(t), [NavBand.blocked, NavBand.free, NavBand.free, NavBand.unknown])
        let px = NavBand.rgba(NavBand.classes(t), n: n)
        // row 0 of the image = max y = class row 1 (columns 2, 3): free then unknown
        XCTAssertEqual(px[3], 70)
        XCTAssertEqual(px[7], 0)
        XCTAssertEqual(px[8 + 3], 220)                    // image row 1 col 0 = class row 0 col 0 = blocked
    }

    func testBandMask() {
        let m = NavBand.mask(vox: 0.05, nz: 58)
        XCTAssertEqual(m & (1 << 7), 0)                   // floor + 0.05 m: below the band
        XCTAssertNotEqual(m & (1 << 8), 0)                // floor + 0.10 m
        XCTAssertNotEqual(m & (1 << 25), 0)               // floor + 0.95 m
        XCTAssertEqual(m & (1 << 26), 0)                  // floor + 1.00 m
    }

    func testStateAppliesOnlyChanges() throws {
        var st = LiveNavState()
        let t = LiveNavTile(key: "0/0/0", level: 0, tx: 0, ty: 0, rev: 1, z0: 0, nc: 1, occ: [1 << 10], free: [0])
        let doc = try JSONDecoder().decode(LiveNavDoc.self, from: Data(#"{"rev":5,"tiles":[]}"#.utf8))
        XCTAssertEqual(st.apply(doc, now: 0), [])
        XCTAssertEqual(st.rev, 5)
        var d2 = doc
        d2.tiles = [t]
        XCTAssertEqual(st.apply(d2, now: 1), ["0/0/0"])
        XCTAssertEqual(st.apply(d2, now: 2), [])
        XCTAssertTrue(st.summary(now: 3, blocked: 400).contains("1.0 m² blocked"))
    }
}

/// A real `GET /v1/live/nav` answer decodes into the robot band pictures. Skipped unless SNAILSIGHT_NAV_REPLAY is set.
final class NavLayerReplayTests: XCTestCase {
    func testLiveAnswer() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAILSIGHT_NAV_REPLAY"] else {
            throw XCTSkip("set SNAILSIGHT_NAV_REPLAY to a saved /v1/live/nav answer")
        }
        let doc = try JSONDecoder().decode(LiveNavDoc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var st = LiveNavState()
        let changed = st.apply(doc, now: 0)
        XCTAssertEqual(changed.count, doc.tiles.count)
        var blocked = 0, free = 0
        for t in doc.tiles {
            XCTAssertEqual(t.occ.count, t.nc * t.nc, t.key)
            XCTAssertEqual(t.free.count, t.nc * t.nc, t.key)
            let c = NavBand.counts(NavBand.classes(t))
            blocked += c.blocked
            free += c.free
            XCTAssertEqual(NavBand.rgba(NavBand.classes(t), n: t.nc).count, t.nc * t.nc * 4)
        }
        XCTAssertGreaterThan(blocked + free, 0)
        print("NAV_REPLAY rev \(doc.rev ?? -1) tiles \(doc.tiles.count) blocked \(blocked) free \(free) · \(st.summary(now: 1, blocked: blocked))")
    }
}
