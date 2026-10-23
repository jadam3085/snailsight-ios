import XCTest
@testable import SnailSightCore

/// 12.9 live models: catalog diff, blob cache eviction + fetch plan, fallback to the minimal bundle, served low-poly
/// agents, the catalog WS event.
final class SimLiveTests: XCTestCase {
    static func sha(_ c: Character) -> String { String(repeating: c, count: 64) }

    /// An animal with idle+walk files (+ thumb), blobs by the given hash letters.
    static func animal(_ key: String, idle: Character, walk: Character, thumb: Character = "7", bytes: Int = 100,
                       size: [Double] = [1, 1, 1], label: String? = nil) -> SimCatalogItem {
        var it = SimCatalogItem(key: key, label: label ?? key.capitalized, category: .animal, group: "Wild", symbol: "pawprint",
                                sizeM: size, files: ["idle": "\(key)_idle.usdz", "walk": "\(key)_walk.usdz"], thumb: "\(key).png")
        it.blobs = ["\(key)_idle.usdz": SimBlobRef(sha256: sha(idle), bytes: bytes), "\(key)_walk.usdz": SimBlobRef(sha256: sha(walk), bytes: bytes),
                    "\(key).png": SimBlobRef(sha256: sha(thumb), bytes: 10), "\(key).glb": SimBlobRef(sha256: sha("8"), bytes: 5)]
        return it
    }

    // MARK: diff

    func testDiffAddedRemovedChanged() {
        let a = Self.animal("fox", idle: "a", walk: "b"), b = Self.animal("deer", idle: "c", walk: "d")
        let fox2 = Self.animal("fox", idle: "a", walk: "b", size: [1, 1, 1.5])          // size changed
        let rabbit = Self.animal("rabbit", idle: "e", walk: "f")
        let d = SimContentDiff.diff(old: [a, b], new: [fox2, rabbit])
        XCTAssertEqual(d.added, ["rabbit"]); XCTAssertEqual(d.removed, ["deer"]); XCTAssertEqual(d.changed, ["fox"])
        XCTAssertEqual(d.redraw, ["fox", "rabbit"])
        XCTAssertTrue(SimContentDiff.diff(old: [a, b], new: [b, a]).isEmpty)               // order is not a change
    }

    func testOnlyBlobChangeIsAChange() {
        let a = Self.animal("fox", idle: "a", walk: "b")
        let re = Self.animal("fox", idle: "9", walk: "b")                                  // same file names, new bytes
        XCTAssertEqual(SimContentDiff.diff(old: [a], new: [re]).changed, ["fox"])
        var lbl = a; lbl.label = "Red fox"
        XCTAssertEqual(SimContentDiff.diff(old: [a], new: [lbl]).changed, ["fox"])
        var web = a                                                                        // the portal's glb alone: not for the phone
        web.blobs?["fox.glb"] = SimBlobRef(sha256: Self.sha("0"), bytes: 6)
        XCTAssertEqual(SimContentDiff.diff(old: [a], new: [web]).changed, ["fox"])         // the fingerprint covers every blob
    }

    func testAgentsDiff() {
        let r1 = SimAgentModel(frame: "model", parts: RobotModel.parts().map(SimPartSpec.init))
        var parts = r1.parts; parts[0].size[0] += 0.1
        let r2 = SimAgentModel(frame: "model", parts: parts)
        XCTAssertEqual(SimAgents.changed(["robot": r1], ["robot": r2]), ["robot"])
        XCTAssertEqual(SimAgents.changed(nil, ["robot": r1]), ["robot"])
        XCTAssertEqual(SimAgents.changed(["robot": r1], ["robot": r1]), [])
        let d = SimContentDiff.diff(old: [], new: [], oldAgents: ["robot": r1], newAgents: ["robot": r2, "drone": r1])
        XCTAssertEqual(d.agents, ["drone", "robot"]); XCTAssertFalse(d.isEmpty)
        XCTAssertEqual(d.redraw, ["drone", "robot"])
    }

    // MARK: cache eviction

    func testEvictFreesOrphansAndPreviousRevBlobs() {
        let e = [SimBlobEntry(name: "old.usdz", bytes: 50, lastUse: 1), SimBlobEntry(name: "cur.usdz", bytes: 50, lastUse: 2)]
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: ["cur.usdz"], protected: [], budget: 1000), ["old.usdz"])
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: ["cur.usdz", "old.usdz"], protected: [], budget: 1000), [])
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: [], protected: ["old.usdz"], budget: 1000), ["cur.usdz"])
    }

    func testEvictOverBudgetIsLRUAndNeverTouchesProtected() {
        let e = (1...5).map { SimBlobEntry(name: "b\($0).usdz", bytes: 100, lastUse: Double($0)) }
        let all = Set(e.map(\.name))
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: all, protected: [], budget: 300), ["b1.usdz", "b2.usdz"])
        // b1 is protected (a spawned body): the next least recent go instead
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: all, protected: ["b1.usdz"], budget: 300), ["b2.usdz", "b3.usdz"])
        // protected alone can exceed the budget: nothing else to give
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: all, protected: all, budget: 10), [])
        XCTAssertEqual(SimBlobCache.evict(entries: e, inUse: all, protected: [], budget: 500), [])
    }

    func testFetchPlanOrderAndBudget() {
        let items = ["a", "b", "c", "d"].enumerated().map { Self.animal($0.element, idle: Character(String($0.offset + 1)), walk: Character(String($0.offset + 5)), bytes: 100) }
        let have: Set<String> = []
        let p = SimBlobCache.fetchPlan(items: items, have: have, haveBytes: 0, spawned: ["d"], changed: ["c"], recents: ["b"], budget: 10_000)
        let keys = p.map(\.key)
        XCTAssertEqual(keys.first, "d")                                                    // spawned bodies first
        XCTAssertEqual(keys.reduce(into: [String]()) { if $1 != $0.last { $0.append($1) } }, ["d", "c", "b", "a"])
        XCTAssertEqual(Set(p.map(\.blob)).count, p.count)                                  // unique
        XCTAssertTrue(p.allSatisfy { !$0.blob.hasSuffix(".glb") })                         // the portal's twin is not fetched
        // budget 450: spawned + changed + recents always come; "the rest" is all-or-nothing and skipped when it would not fit
        let tight = SimBlobCache.fetchPlan(items: items, have: have, haveBytes: 0, spawned: ["d"], changed: [], recents: [], budget: 450)
        XCTAssertEqual(Set(tight.map(\.key)), ["d", "a"])                                  // 210 each: only one more fits
        XCTAssertEqual(SimBlobCache.fetchPlan(items: items, have: Set(p.map(\.blob)), haveBytes: 800, spawned: [], changed: [], recents: [], budget: 1000).count, 0)
    }

    // MARK: fallback

    func testSourcePrefersVerifiedCacheOverBundle() {
        var fox = Self.animal("fox", idle: "a", walk: "b")
        fox.blobs?["fox_idle.usdz"] = SimBlobRef(sha256: Self.sha("a"), bytes: 1)
        let bundled: Set<String> = ["fox_idle.usdz", "fox_walk.usdz"]
        XCTAssertEqual(SimContent.source(for: "fox_idle.usdz", runtimeItems: [fox], have: ["\(Self.sha("a")).usdz"], bundledFiles: bundled),
                       .runtime("\(Self.sha("a")).usdz"))
        // blob not on disk (no server yet): the bundle
        XCTAssertEqual(SimContent.source(for: "fox_idle.usdz", runtimeItems: [fox], have: [], bundledFiles: bundled), .bundled("fox_idle.usdz"))
        // neither: none (the body draws a box placeholder)
        XCTAssertEqual(SimContent.source(for: "toycar.usdz", runtimeItems: [fox], have: [], bundledFiles: bundled), .none)
    }

    func testFallbackCatalogIsTheMinimalBundleOffline() {
        let fox = SimCatalogItem(key: "fox", label: "Fox", category: .animal, group: "Wild", symbol: "pawprint", sizeM: [0.8, 0.45, 0.25],
                                 files: ["idle": "fox_idle.usdz", "walk": "fox_walk.usdz"])
        let broken = SimCatalogItem(key: "deer", label: "Deer", category: .animal, group: "Wild", symbol: "hare", sizeM: [1, 1, 1],
                                    files: ["idle": "deer_idle.usdz"])
        let fb = SimContent.fallbackCatalog(bundled: SimCatalog(items: [fox, broken]), bundledFiles: ["fox_idle.usdz", "fox_walk.usdz"])
        XCTAssertEqual(fb.items.map(\.key), ["fox"])                                        // no server + empty cache: fox is usable
        // merge with nothing runtime = the fallback itself
        XCTAssertEqual(SimContent.merge(bundled: fb, runtime: []).items.map(\.key), ["fox"])
        // once the server's catalog arrives, runtime items replace the fox in place and add the rest
        let live = Self.animal("fox", idle: "a", walk: "b", size: [0.9, 0.5, 0.3])
        let m = SimContent.merge(bundled: fb, runtime: [live, Self.animal("deer", idle: "c", walk: "d")])
        XCTAssertEqual(m.items.map(\.key), ["fox", "deer"]); XCTAssertEqual(m.item("fox")?.sizeM, [0.9, 0.5, 0.3])
    }

    func testRuntimeItemMissingABlobIsHiddenButOldVersionStays() {
        let v1 = Self.animal("fox", idle: "a", walk: "b")
        let v2 = Self.animal("fox", idle: "c", walk: "d")
        let allV1 = SimContent.referenced(items: [v1])
        // v2 still downloading: the old version stays exposed
        XCTAssertEqual(SimContent.reconcile(previous: [v1], doc: [v2], have: allV1).first, v1)
        // v2's files all arrived: the new one
        XCTAssertEqual(SimContent.reconcile(previous: [v1], doc: [v2], have: allV1.union(SimContent.referenced(items: [v2]))).first, v2)
        // brand new item without its blobs: hidden; removed from the doc: dropped
        XCTAssertTrue(SimContent.reconcile(previous: [], doc: [v2], have: []).isEmpty)
        XCTAssertTrue(SimContent.reconcile(previous: [v1], doc: [], have: allV1).isEmpty)
        // the old version whose blobs were evicted is not resurrected
        XCTAssertTrue(SimContent.reconcile(previous: [v1], doc: [v2], have: []).isEmpty)
    }

    // MARK: served agents

    func testAgentsPartsDecodeEqualsCompiledInRobotParts() throws {
        let compiled = RobotModel.parts()
        let json = try JSONEncoder().encode(["robot": SimAgentModel(frame: "model", parts: compiled.map(SimPartSpec.init))])
        let agents = try JSONDecoder().decode([String: SimAgentModel].self, from: json)
        XCTAssertEqual(SimAgents.robotParts(agents), compiled)
        XCTAssertEqual(RobotModel.parts(served: SimAgents.robotParts(agents)), compiled)
    }

    func testAgentsDefaultsWhenAbsentOrMalformed() throws {
        XCTAssertNil(SimAgents.robotParts(nil)); XCTAssertNil(SimAgents.droneParts(nil))
        XCTAssertNil(SimAgents.robotParts([:]))
        XCTAssertEqual(RobotModel.parts(served: SimAgents.robotParts(nil)), RobotModel.parts())
        // a robot without wheels would break the rig: refused
        let hullOnly = SimAgentModel(frame: "model", parts: [SimPartSpec(name: "hull", shape: "box", center: [0, 0.2, 0], size: [0.8, 0.3, 0.5], material: "body")])
        XCTAssertNil(SimAgents.robotParts(["robot": hullOnly]))
        let bad = SimAgentModel(parts: [SimPartSpec(name: "x", shape: "torus", center: [0, 0, 0], size: [1, 1, 1])])
        XCTAssertNil(bad.bodyParts); XCTAssertNil(SimAgents.droneParts(["drone": bad]))
        let neg = SimPartSpec(name: "x", shape: "box", center: [0, 0, 0], size: [1, -1, 1])
        XCTAssertNil(neg.bodyPart)
    }

    func testDocDecodesAgentsAndSkipsMalformedItems() throws {
        let j = """
        {"version":1,"rev":"r9","items":[
          {"key":"ok","label":"Ok","category":"animal","group":"g","symbol":"s","size_m":[1,1,1],"files":{"idle":"ok_idle.usdz"}},
          {"key":"weird","label":"W","category":"vehicle","group":"g","symbol":"s"}],
         "agents":{"drone":{"frame":"map","parts":[{"name":"body","shape":"box","corner":0.02,"center":[0,0,0],"size":[0.18,0.18,0.06],"color":[0.9,0.9,0.95]}]},
                   "robot":{"parts":[{"name":"x"}]}}}
        """
        let d = try SimContentDoc.decode(Data(j.utf8))
        XCTAssertEqual(d.items.map(\.key), ["ok"])                                          // a bad item never kills the document
        XCTAssertEqual(d.agents?["drone"]?.parts.first?.rgb, SIMD3(0.9, 0.9, 0.95))
        XCTAssertNil(d.agents?["robot"])                                                    // malformed agent entry skipped
        XCTAssertEqual(SimAgents.droneParts(d.agents)?.count, 1)
        // an old server without agents / the bundled shape
        XCTAssertNil(try SimContentDoc.decode(Data(#"{"version":1,"rev":"a","items":[]}"#.utf8)).agents)
    }

    // MARK: catalog event

    func testCatalogEventAndHello() throws {
        let e = try XCTUnwrap(SimCatalogEvent.parse(Data(#"{"type":"catalog","rev":"abc","items":41,"changed":["fox"],"removed":["yak"]}"#.utf8)))
        XCTAssertEqual(e.rev, "abc"); XCTAssertEqual(e.changed, ["fox"]); XCTAssertEqual(e.removed, ["yak"]); XCTAssertFalse(e.fromHello)
        XCTAssertTrue(e.isNews(known: "old")); XCTAssertFalse(e.isNews(known: "abc"))
        let h = try XCTUnwrap(SimCatalogEvent.parse(Data(#"{"type":"hello","catalog_rev":"zz","entities":[]}"#.utf8)))
        XCTAssertTrue(h.fromHello); XCTAssertEqual(h.rev, "zz")
        XCTAssertNil(SimCatalogEvent.parse(Data(#"{"type":"hello","entities":[]}"#.utf8)))      // an older server
        XCTAssertNil(SimCatalogEvent.parse(Data(#"{"type":"snapshot","entities":[]}"#.utf8)))
        // the existing parser keeps ignoring it (older code paths)
        XCTAssertEqual(SimStreamMessage.parse(Data(#"{"type":"catalog","rev":"abc"}"#.utf8)), .other("catalog"))
    }
}
