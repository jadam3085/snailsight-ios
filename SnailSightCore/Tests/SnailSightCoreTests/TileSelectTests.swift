import XCTest
@testable import SnailSightCore

/// 11.0 tile streaming: TileSelect must give exactly what snailCOP services/snailsight/tileselect.py gives. The tree
/// below is built by the same generator as the Python fixture (two storeys, 24 × 12 m, 4 m leaves → 64 m roots) and the
/// expected key sets were produced by tileselect.select on it.
final class TileSelectTests: XCTestCase {

    static func fakeHash(_ key: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let s = String(h, radix: 16)
        return String(repeating: "0", count: 64 - s.count) + s
    }

    /// tileselect fixture generator (gen.py): leaves 4 m, parents 8/16/32/64 m, coverage x < 24, y < 12.
    static func node(_ level: Int, _ size: Int, _ tx: Int, _ ty: Int, _ z0: Double) -> TileNode {
        let key = size == 4 ? "\(level)/\(tx)/\(ty)" : "\(level)/\(size)/\(tx)/\(ty)"
        let lo = [Double(tx * size), Double(ty * size), z0], hi = [Double((tx + 1) * size), Double((ty + 1) * size), z0 + 2.6]
        let c = (0..<3).map { (lo[$0] + hi[$0]) / 2 }, e = (0..<3).map { (hi[$0] - lo[$0]) / 2 }
        var kids: [TileNode] = []
        if size > 4 {
            let s2 = size / 2
            for a in 0...1 {
                for b in 0...1 {
                    let cx = tx * 2 + a, cy = ty * 2 + b
                    if cx * s2 >= 24 || cy * s2 >= 12 { continue }
                    kids.append(node(level, s2, cx, cy, z0))
                }
            }
        }
        let mem = size == 4 ? 3_000_000 + (abs(tx * 7 + ty * 3) % 5) * 1_000_000 : 600_000 * size / 8
        return TileNode(key: key, level: level, size: size, box: [c[0], c[1], c[2], e[0], 0, 0, 0, e[1], 0, 0, 0, e[2]],
                        uri: "../../../blobs/\(fakeHash(key)).usdz", bytes: 100_000 + size * 1000, mem: mem,
                        children: kids)
    }

    static var roots: [TileNode] { [node(0, 64, 0, 0, -1.3), node(1, 64, 0, 0, 1.4)] }

    static let expected: [String: (String, String)] = [
        "still_l0": ("0/0/0 0/0/1 0/0/2 0/1/0 0/1/1 0/1/2 0/2/0 0/2/1 0/3/0 0/3/1 1/0/0 1/0/1 1/0/2 1/1/0 1/1/1 1/1/2 1/2/0 1/2/1 1/3/0 1/3/1", "0/8/1/1 0/8/2/0 0/8/2/1 1/8/1/1 1/8/2/0 1/8/2/1"),
        "still_l1": ("0/0/0 0/0/1 0/0/2 0/1/0 0/1/1 0/1/2 0/2/0 0/2/1 0/3/0 0/3/1 1/0/0 1/0/1 1/0/2 1/1/0 1/1/1 1/1/2 1/2/0 1/2/1 1/3/0 1/3/1", "0/8/1/1 0/8/2/0 0/8/2/1 1/8/1/1 1/8/2/0 1/8/2/1"),
        "far_end": ("0/2/0 0/2/1 0/2/2 0/3/0 0/3/1 0/3/2 0/4/0 0/4/1 0/4/2 0/5/0 0/5/1 0/5/2 1/2/0 1/2/1 1/2/2 1/3/0 1/3/1 1/3/2 1/4/0 1/4/1 1/4/2 1/5/0 1/5/1 1/5/2", "0/8/0/0 0/8/0/1 1/8/0/0 1/8/0/1"),
        "walk_east": ("0/0/0 0/0/1 0/0/2 0/1/0 0/1/1 0/1/2 0/2/0 0/2/1 0/2/2 0/3/0 0/3/1 0/3/2 0/4/0 0/4/1 0/4/2 0/5/0 0/5/1 0/5/2 1/0/0 1/0/1 1/0/2 1/1/0 1/1/1 1/1/2 1/2/0 1/2/1 1/2/2 1/3/0 1/3/1 1/3/2 1/4/0 1/4/1 1/4/2 1/5/0 1/5/1 1/5/2", ""),
        "walk_west": ("0/0/0 0/0/1 0/0/2 0/1/0 0/1/1 0/1/2 0/2/0 0/2/1 0/2/2 0/3/0 0/3/1 0/3/2 1/0/0 1/0/1 1/0/2 1/1/0 1/1/1 1/1/2 1/2/0 1/2/1 1/2/2 1/3/0 1/3/1 1/3/2", "0/8/2/0 0/8/2/1 1/8/2/0 1/8/2/1"),
        "tight_budget": ("0/0/0 0/0/1 0/1/1", "0/8/2/0 0/8/2/1"),
        "outside": ("", ""),
    ]

    func check(_ name: String, cam: [Double], heading: (Double, Double)? = nil, speed: Double = 0,
               near: Int = TileSelect.NEAR_BUDGET, mid: Int = TileSelect.MID_BUDGET, file: StaticString = #filePath,
               line: UInt = #line) {
        let w = TileSelect.select(Self.roots, cam: cam, heading: heading, speed: speed, nearBudget: near, midBudget: mid)
        let gotNear = w.values.filter { $0.band == .near }.map(\.node.key).sorted().joined(separator: " ")
        let gotMid = w.values.filter { $0.band == .mid }.map(\.node.key).sorted().joined(separator: " ")
        XCTAssertEqual(gotNear, Self.expected[name]!.0, "\(name) near", file: file, line: line)
        XCTAssertEqual(gotMid, Self.expected[name]!.1, "\(name) mid", file: file, line: line)
    }

    func testMatchesPythonReference() {
        check("still_l0", cam: [2, 2, 0.2])
        check("still_l1", cam: [2, 2, 2.9])
        check("far_end", cam: [22, 10, 0.2])
        check("walk_east", cam: [6, 6, 0.2], heading: (1, 0), speed: 1.2)
        check("walk_west", cam: [6, 6, 0.2], heading: (-1, 0), speed: 1.2)
        check("tight_budget", cam: [6, 6, 0.2], near: 12_000_000, mid: 1_500_000)
        check("outside", cam: [80, 80, 0.2])
    }

    func testDistances() {
        let n = Self.roots[0].children[0]                 // 0/32/0/0: x 0..32, y 0..32, z -1.3..1.3
        XCTAssertEqual(n.key, "0/32/0/0")
        XCTAssertEqual(TileSelect.boxDistance([2, 2, 3.0], n), 5.1, accuracy: 1e-9)      // 1.7 m above × VZ 3
        XCTAssertEqual(TileSelect.effDistance([-5, 2, 0], heading: (1, 0), speed: 1.0, n), 0.8397485283107811, accuracy: 1e-9)
        // slower than 5 cm/s: no lookahead
        XCTAssertEqual(TileSelect.effDistance([-5, 2, 0], heading: (1, 0), speed: 0.04, n), 5, accuracy: 1e-9)
        // walking away: never farther than the plain distance
        XCTAssertEqual(TileSelect.effDistance([-5, 2, 0], heading: (-1, 0), speed: 1.5, n), 5, accuracy: 1e-9)
    }

    func testBandsLeavesNearParentsMid() {
        let w = TileSelect.select(Self.roots, cam: [2, 2, 0.2])
        for x in w.values {
            XCTAssertEqual(x.band == .near, x.node.size == TileSelect.LEAF_M)
            XCTAssertLessThanOrEqual(x.distance, TileSelect.FAR_M)
        }
        // REPLACE: never a node together with one of its ancestors
        let par = TileSelect.ancestorsMap(Self.roots)
        for k in w.keys {
            var a = par[k]
            while let ak = a { XCTAssertNil(w[ak], "\(k) drawn with its ancestor \(ak)"); a = par[ak] }
        }
    }

    func testBudgetCutsFarthestFirst() {
        let all = TileSelect.select(Self.roots, cam: [6, 6, 0.2])
        let tight = TileSelect.select(Self.roots, cam: [6, 6, 0.2], nearBudget: 12_000_000, midBudget: 1_500_000)
        let nearMem = tight.values.filter { $0.band == .near }.reduce(0) { $0 + $1.node.mem }
        XCTAssertLessThanOrEqual(nearMem, 12_000_000)
        XCTAssertLessThan(tight.count, all.count)
        // the nearest leaf always stays; the farthest leaves are the ones cut
        let nearest = all.values.filter { $0.band == .near }.map(\.distance).min()!
        XCTAssertEqual(tight.values.filter { $0.band == .near }.map(\.distance).min()!, nearest)
        let farthest = all.values.filter { $0.band == .near }.max { $0.distance < $1.distance }!
        XCTAssertNil(tight[farthest.node.key])
    }

    func testHeadingPrefetchMovesTileForward() {
        let still = TileSelect.select(Self.roots, cam: [6, 6, 0.2])
        XCTAssertNil(still["0/5/1"])
        XCTAssertEqual(still["0/8/2/0"]?.band, .mid)
        let east = TileSelect.select(Self.roots, cam: [6, 6, 0.2], heading: (1, 0), speed: 1.2)
        XCTAssertEqual(east["0/5/1"]?.band, .near)          // 14 m ahead, lookahead 6 m: opened early
        XCTAssertNil(east["0/8/2/0"])
        let west = TileSelect.select(Self.roots, cam: [6, 6, 0.2], heading: (-1, 0), speed: 1.2)
        XCTAssertNil(west["0/5/1"])
    }

    func testDrawnKeepsParentUntilChildrenLoad() {
        let par = TileSelect.ancestorsMap(Self.roots)
        let w = TileSelect.select(Self.roots, cam: [6, 6, 0.2])
        XCTAssertNotNil(w["0/1/1"])
        XCTAssertNil(w["0/8/0/0"])
        // nothing drawn before: no hole filler appears out of nowhere
        XCTAssertEqual(TileSelect.drawn(want: w, loaded: [], parents: par, prevDrawn: ["0/8/0/0"]), [])
        // the parent was drawn and is loaded: it stays while its children load
        XCTAssertEqual(TileSelect.drawn(want: w, loaded: ["0/8/0/0"], parents: par, prevDrawn: ["0/8/0/0"]), ["0/8/0/0"])
        // all four children loaded: the parent goes
        let kids: Set<String> = ["0/0/0", "0/0/1", "0/1/0", "0/1/1", "0/8/0/0"]
        let d = TileSelect.drawn(want: w, loaded: kids, parents: par, prevDrawn: ["0/8/0/0"])
        XCTAssertFalse(d.contains("0/8/0/0"))
        XCTAssertTrue(d.isSuperset(of: ["0/0/0", "0/0/1", "0/1/0", "0/1/1"]))
        // eviction keeps the hole filler, drops what is neither wanted nor drawn
        let filler = TileSelect.drawn(want: w, loaded: ["0/8/0/0", "0/16/1/0"], parents: par, prevDrawn: ["0/8/0/0"])
        XCTAssertEqual(TileSelect.evictable(loaded: ["0/8/0/0", "0/16/1/0"], want: w, drawn: filler), ["0/16/1/0"])
    }

    func testFetchOrderNearestFirst() {
        let w = TileSelect.select(Self.roots, cam: [2, 2, 0.2])
        let order = TileSelect.fetchOrder(w, loaded: ["0/0/0"])
        XCTAssertFalse(order.contains { $0.node.key == "0/0/0" })
        XCTAssertEqual(order.first?.node.key, "0/0/1")
        XCTAssertEqual(order.map(\.distance), order.map(\.distance).sorted())
    }

    func testMotion() {
        var m = TileMotion()
        XCTAssertEqual(m.speed, 0)
        for i in 0...6 { m.add(t: Double(i) * 0.5, x: Double(i) * 0.5, y: 0) }       // 1 m/s
        XCTAssertEqual(m.speed, 1, accuracy: 1e-9)
        let h = TileMotion.heading(forward: [0, 2, -0.5])!
        XCTAssertEqual(h.0, 0, accuracy: 1e-9)
        XCTAssertEqual(h.1, 1, accuracy: 1e-9)
        XCTAssertNil(TileMotion.heading(forward: [0, 0, -1]))
    }

    // MARK: tileset parsing + URLs

    static let tilesetJSON = """
    {"asset":{"version":"1.1","gltfUpAxis":"Y"},"geometricError":5,"extras":{"map_id":"site","rev":14,"variant":"structure"},
     "root":{"boundingVolume":{"box":[8,4,0,8,0,0,0,4,0,0,0,1.3]},"geometricError":4.5,"refine":"REPLACE","children":[
      {"boundingVolume":{"box":[8,4,0,8,0,0,0,4,0,0,0,1.3]},"geometricError":0.06,"refine":"REPLACE",
       "extras":{"key":"0/64/0/0","level":0,"size_m":64,"rev":14,"triangles":0,"mem":0},
       "children":[
        {"boundingVolume":{"box":[2,2,0,2,0,0,0,2,0,0,0,1.3]},"geometricError":0.0,"refine":"REPLACE",
         "content":{"uri":"../../../blobs/\(String(repeating: "a", count: 64)).glb"},
         "extras":{"key":"0/0/0","level":0,"size_m":4,"rev":14,"triangles":5000,"mem":4200000,
                   "usdz":{"uri":"../../../blobs/\(String(repeating: "b", count: 64)).usdz","bytes":812345},"glb_bytes":700000}}
       ]}]}}
    """

    func testParseTileset() throws {
        let roots = try TileSet.parse(Data(Self.tilesetJSON.utf8))
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].key, "0/64/0/0")
        XCTAssertNil(roots[0].uri)                            // a parent without content of its own
        let leaf = roots[0].children[0]
        XCTAssertEqual(leaf.key, "0/0/0")
        XCTAssertEqual(leaf.size, 4)
        XCTAssertEqual(leaf.mem, 4_200_000)
        XCTAssertEqual(leaf.bytes, 812_345)
        XCTAssertEqual(leaf.hash, String(repeating: "b", count: 64))
        XCTAssertEqual(leaf.half.0, 2)
        XCTAssertEqual(TileSet.info(Data(Self.tilesetJSON.utf8)).rev, 14)
        XCTAssertEqual(TileSet.flatten(roots).map(\.key), ["0/64/0/0", "0/0/0"])
        // the content-less root is refined (8 m away < 64 m), the leaf drawn
        let w = TileSelect.select(roots, cam: [1, 1, 0])
        XCTAssertEqual(Array(w.keys), ["0/0/0"])
    }

    func testResolveURLs() {
        let b = String(repeating: "b", count: 64)
        XCTAssertEqual(TileURL.resolve("../../../blobs/\(b).usdz", against: "/v1/maps/site/tiles/tileset.json?variant=structure"),
                       "/v1/blobs/\(b).usdz")
        XCTAssertEqual(TileURL.resolve("\(b).usdz", against: "/v1/blobs/\(String(repeating: "c", count: 64)).json"),
                       "/v1/blobs/\(b).usdz")
        XCTAssertEqual(TileURL.resolve("../../../blobs/x.usdz", against: "http://host:8904/v1/maps/site/tiles/tileset.json"),
                       "http://host:8904/v1/blobs/x.usdz")
        XCTAssertEqual(TileURL.resolve("/v1/blobs/x.usdz", against: "/v1/maps/site/tiles/tileset.json"), "/v1/blobs/x.usdz")
        XCTAssertEqual(TileURL.resolve("./a/../b.usdz", against: "/v1/x/"), "/v1/x/b.usdz")
        XCTAssertNil(TileURL.blobHash("../../../blobs/notahash.usdz"))
    }

    func testHeadTilesBlock() {
        let j = #"""
        {"map_id":"site","rev":14,"ready":true,"version":14,"scene":"site@14","etag":"14-1",
         "tiles":{"rev":15,"base":14,"tilesets":{"raw":{"hash":"aa","bytes":10,"url":"/v1/blobs/aa.json","stable_url":"/v1/maps/site/tiles/tileset.json?variant=raw"},
                                                  "structure":{"hash":"bb","bytes":12,"url":"/v1/blobs/bb.json","stable_url":"/v1/maps/site/tiles/tileset.json?variant=structure"}},
                  "default_variant":"structure","weird":[1,2]}}
        """#
        let h = MapHead.decode(Data(j.utf8))!
        XCTAssertEqual(h.tiles?.rev, 15)
        XCTAssertEqual(h.tiles?.variant(raw: false), "structure")
        XCTAssertEqual(h.tiles?.variant(raw: true), "raw")
        XCTAssertEqual(h.tiles?.tilesetPath("structure"), "/v1/maps/site/tiles/tileset.json?variant=structure")
        // tiles null (today's server before the build) and absent both decode
        XCTAssertNil(MapHead.decode(Data(#"{"map_id":"site","rev":14,"ready":true,"tiles":null}"#.utf8))!.tiles)
        XCTAssertNil(MapHead.decode(Data(#"{"map_id":"site","rev":14,"ready":true}"#.utf8))!.tiles)
        // only raw: the structure toggle falls back to what exists
        let only = MapTiles(rev: 1, tilesets: ["raw": .init(hash: "aa")], defaultVariant: "raw")
        XCTAssertEqual(only.variant(raw: false), "raw")
        XCTAssertEqual(only.tilesetPath("raw"), "/v1/blobs/aa.json")
        // round trip through the UserDefaults cache
        let back = MapHead.decode(try! JSONEncoder().encode(h))
        XCTAssertEqual(back?.tiles, h.tiles)
    }
}

final class TileCacheTests: XCTestCase {
    func testDiskLRUEvictsOldestUnpinned() {
        var c = TileDiskLRU(capBytes: 100)
        c.seed("a", bytes: 40, lastUse: 1)
        c.seed("b", bytes: 40, lastUse: 2)
        XCTAssertEqual(c.totalBytes, 80)
        c.touch("a", now: 3)                                   // a is now newer than b
        let gone = c.insert("c", bytes: 40, now: 4)
        XCTAssertEqual(gone, ["b"])
        XCTAssertEqual(c.totalBytes, 80)
        XCTAssertTrue(c.contains("a") && c.contains("c") && !c.contains("b"))
        // pinned blobs survive even when oldest
        let gone2 = c.insert("d", bytes: 40, now: 5, pinned: ["a"])
        XCTAssertEqual(gone2, ["c"])
        XCTAssertEqual(c.totalBytes, 80)
        // the blob just written is never its own victim
        var one = TileDiskLRU(capBytes: 10)
        XCTAssertEqual(one.insert("big", bytes: 50, now: 1), [])
        XCTAssertEqual(TileDiskLRU.defaultCap, 2_147_483_648)
        one.remove("big")
        XCTAssertEqual(one.totalBytes, 0)
    }

    func testMemLedger() {
        var m = TileMemLedger()
        m.add("0/0/0", .init(hash: "h1", mem: 10, near: true))
        m.add("0/8/0/0", .init(hash: "h2", mem: 5, near: false))
        XCTAssertEqual(m.totalMem, 15)
        XCTAssertEqual(m.nearMem, 10)
        XCTAssertEqual(m.midMem, 5)
        m.add("0/0/0", .init(hash: "h3", mem: 12, near: true))   // replaced (new rev): not counted twice
        XCTAssertEqual(m.totalMem, 17)
        XCTAssertEqual(m.current(hashes: ["0/0/0": "h3", "0/8/0/0": "hX"]), ["0/0/0"])
        XCTAssertEqual(m.remove("0/8/0/0")?.mem, 5)
        XCTAssertEqual(m.totalMem, 12)
        m.removeAll()
        XCTAssertEqual(m.totalMem, 0)
    }
}

final class LocHintTests: XCTestCase {
    func testHintBody() {
        let h = LocHint.from(answer: "0/1/-2", level: 0, cameraMap: [5.12345, -6.5, 0.3], fallbackMap: [0, 0, 0],
                             mapID: "site", now: 1000)
        XCTAssertEqual(h.xy, [5.123, -6.5])
        let b = h.body(mapID: "site", now: 1012.34)!
        XCTAssertEqual(b["last_tile"] as? String, "0/1/-2")
        XCTAssertEqual(b["last_level"] as? Int, 0)
        XCTAssertEqual(b["last_xy"] as? [Double], [5.123, -6.5])
        XCTAssertEqual(b["last_pose_age_s"] as? Double, 12.3)
        XCTAssertNil(h.body(mapID: "other", now: 1010))
        XCTAssertNil(h.body(mapID: "site", now: 1000 + LocHint.maxAgeS + 1))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(b))
    }

    func testHintFallsBackToOwnPosition() {
        let h = LocHint.from(answer: nil, level: 1, cameraMap: nil, fallbackMap: [-0.5, 9.0, 2.8], mapID: "site", now: 5)
        XCTAssertEqual(h.tile, "1/-1/2")
        XCTAssertEqual(h.xy, [-0.5, 9.0])
        let none = LocHint.from(answer: nil, level: nil, cameraMap: nil, fallbackMap: [1, 2, 3], mapID: "site", now: 5)
        XCTAssertNil(none.tile)
        XCTAssertEqual(none.body(mapID: "site", now: 6)?["last_xy"] as? [Double], [1, 2])
    }

    func testLocalizeAnswerTileFields() throws {
        let j = #"""
        {"map_id":"site","map_version":14,"locked":true,"events":[],"frames":[],"tile":"0/2/-1","level":0,
         "camera_map":[9.1,-2.2,0.4],"confidence":{"sigma_cm":3.2,"sigma_deg":0.8,"source":"both","fixes":3}}
        """#
        let a = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(j.utf8))
        XCTAssertEqual(a.tile, "0/2/-1")
        XCTAssertEqual(a.level, 0)
        XCTAssertEqual(a.cameraMap, [9.1, -2.2, 0.4])
        XCTAssertEqual(a.confidence?.sigmaCm, 3.2)
        XCTAssertEqual(a.confidence?.fixes, 3)
    }
}
