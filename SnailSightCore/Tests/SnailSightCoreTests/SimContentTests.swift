import XCTest
@testable import SnailSightCore

/// 12.8 runtime sim content (GET /v1/sim/content): decode, merge with the bundled catalog, blob planning, gestures, sha256.
final class SimContentTests: XCTestCase {
    static let shaA = String(repeating: "a", count: 64)
    static let shaB = String(repeating: "b", count: 64)
    static let shaT = String(repeating: "c", count: 64)
    static let shaG = String(repeating: "d", count: 64)
    static let shaW = String(repeating: "e", count: 64)

    static let doc = """
    {"version": 1, "rev": "r1", "updated": "2026-10-23T12:00:00Z", "blob_path": "/v1/sim/content/blobs/",
     "items": [
      {"key": "helix_robo", "label": "robo", "category": "animal", "group": "Helix lab", "symbol": "figure.stand",
       "nominal": {"height_m": 1.7}, "size_m": [0.4, 1.7, 0.5], "tris": 40000, "origin": "helix-lab",
       "behaviour": {"calm": "stopgo", "walk_speed": 0.7, "flee_speed": 2.0, "scare_person": 0.0, "scare_robot": 1.2,
                     "flee_dist": 1.5, "run_above": 1.0},
       "files": {"idle": "helix_robo_idle.usdz", "walk": "helix_robo_walk.usdz", "wave": "helix_robo_wave.usdz"},
       "clip_actions": {"idle": "idle_look", "walk": "Walking_inplace", "wave": "wave"},
       "thumb": "helix_robo.png",
       "clip_info": {"idle": {"action": "idle_look", "loop": true, "duration_s": 4.0},
                     "walk": {"action": "Walking_inplace", "loop": true, "duration_s": 1.1},
                     "wave": {"action": "wave", "loop": false, "duration_s": 2.5}},
       "blobs": {"helix_robo_idle.usdz": {"sha256": "\(shaA)", "bytes": 10},
                 "helix_robo_walk.usdz": {"sha256": "\(shaB)", "bytes": 11},
                 "helix_robo_wave.usdz": {"sha256": "\(shaW)", "bytes": 12},
                 "helix_robo.png": {"sha256": "\(shaT)", "bytes": 5},
                 "helix_robo.glb": {"sha256": "\(shaG)", "bytes": 99}}},
      {"key": "helix_broken", "label": "broken", "category": "animal", "group": "Helix lab", "symbol": "figure.stand",
       "size_m": [0.4, 1.7, 0.5], "files": {"idle": "helix_broken_idle.usdz"},
       "blobs": {"helix_broken_idle.usdz": {"sha256": "nothex"}}}
     ],
     "rejected": [{"key": "helix_test001", "label": "test001", "reasons": ["no head"], "warnings": []}]}
    """

    func doc() throws -> SimContentDoc { try SimContentDoc.decode(Data(Self.doc.utf8)) }

    func testDecodesRuntimeFieldsAndBundledShapeStillDecodes() throws {
        let d = try doc()
        XCTAssertEqual(d.rev, "r1")
        XCTAssertEqual(d.items.count, 2)
        XCTAssertEqual(d.rejected?.first?.reasons, ["no head"])
        let it = d.items[0]
        XCTAssertEqual(it.origin, "helix-lab")
        XCTAssertEqual(it.clipInfo?["wave"]?.loop, false)
        XCTAssertEqual(it.clipInfo?["walk"]?.durationS, 1.1)
        XCTAssertEqual(it.blobs?["helix_robo.png"]?.bytes, 5)
        // the bundled shape (no runtime fields) still decodes
        let c = try SimCatalog.decode(Data(SimCatalogTests.sample.utf8))
        XCTAssertNil(c.items[0].blobs)
        XCTAssertNil(c.items[0].clipInfo)
    }

    func testPhoneFilesSkipWebTwinAndRejectBadRefs() throws {
        let d = try doc()
        let fs = try XCTUnwrap(SimContent.phoneFiles(d.items[0]))
        XCTAssertEqual(fs.map(\.file), ["helix_robo.png", "helix_robo_idle.usdz", "helix_robo_walk.usdz", "helix_robo_wave.usdz"])
        XCTAssertEqual(fs[0].blob, "\(Self.shaT).png")
        XCTAssertFalse(fs.contains { $0.blob.hasSuffix(".glb") })
        XCTAssertNil(SimContent.phoneFiles(d.items[1]), "a malformed hash makes the item unusable, never half-shown")
    }

    func testMissingAndReady() throws {
        let d = try doc()
        let miss = SimContent.missing(d.items, have: ["\(Self.shaA).usdz"])
        XCTAssertEqual(Set(miss.map(\.blob)), ["\(Self.shaB).usdz", "\(Self.shaW).usdz", "\(Self.shaT).png"])
        XCTAssertTrue(SimContent.ready(d.items, have: ["\(Self.shaA).usdz"]).isEmpty)
        let all: Set<String> = ["\(Self.shaA).usdz", "\(Self.shaB).usdz", "\(Self.shaW).usdz", "\(Self.shaT).png"]
        XCTAssertEqual(SimContent.ready(d.items, have: all).map(\.key), ["helix_robo"])
        XCTAssertTrue(SimContent.missing(d.items, have: all).isEmpty)
        XCTAssertEqual(SimContent.referenced([d]), all)
        XCTAssertEqual(SimContent.blob(for: "helix_robo_walk.usdz", in: d.items), "\(Self.shaB).usdz")
        XCTAssertNil(SimContent.blob(for: "deer_idle.usdz", in: d.items))
        XCTAssertEqual(SimContent.blobPath("x.usdz", base: nil), "/v1/sim/content/blobs/x.usdz")
        XCTAssertEqual(SimContent.blobPath("x.usdz", base: "/b"), "/b/x.usdz")
    }

    func testMergeReplacesSameKeyInPlaceAndAppendsNew() throws {
        let bundled = try SimCatalog.decode(Data(SimCatalogTests.sample.utf8))
        var dog = try XCTUnwrap(bundled.item("dog"))
        dog.label = "Runtime dog"
        let robo = try doc().items[0]
        let m = SimContent.merge(bundled: bundled, runtime: [dog, robo])
        XCTAssertEqual(m.items.map(\.key), ["deer", "dog", "ball", "beachball", "mug", "helix_robo"])
        XCTAssertEqual(m.item("dog")?.label, "Runtime dog")
        XCTAssertEqual(SimContent.merge(bundled: bundled, runtime: []).items, bundled.items)
    }

    func testGestures() throws {
        let robo = try doc().items[0]
        XCTAssertEqual(SimContent.gestures(robo), ["wave"])
        XCTAssertTrue(SimContent.isGesture(robo, clip: "wave"))
        XCTAssertFalse(SimContent.isGesture(robo, clip: "walk"))
        XCTAssertEqual(SimContent.gestureLabel("thumbs_up"), "Thumbs up")
        // the shared clip plays a gesture as itself once its file is loaded; locomotion keeps the gait mapping
        XCTAssertEqual(SimSharedClip.key("wave", available: ["idle", "walk", "wave"]), "wave")
        XCTAssertEqual(SimSharedClip.key("wave", available: ["idle", "walk"]), "idle")
        XCTAssertEqual(SimSharedClip.key("walk", available: ["idle", "walk", "wave"]), "walk")
    }

    func testGestureCommandWire() throws {
        let b = SimServerAPI.body(.gesture("wave"), agentID: "phone-1")
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: b) as? [String: Any])
        XCTAssertEqual(o["gesture"] as? String, "wave")
        XCTAssertEqual(o["owner"] as? String, "phone-1")
        let ws = try XCTUnwrap(JSONSerialization.jsonObject(with: SimServerAPI.wsCommand(.gesture("bow"), id: "e1", agentID: "a",
                                                                                          ref: "r")) as? [String: Any])
        XCTAssertEqual(ws["type"] as? String, "cmd")
        XCTAssertEqual(ws["gesture"] as? String, "bow")
        XCTAssertEqual(SimServerAPI.Command.gesture("x").name, "gesture")
    }

    func testSHA256() {
        XCTAssertEqual(SimContent.sha256HexPortable(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SimContent.sha256HexPortable(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data((0..<1000).map { UInt8($0 % 251) })
        XCTAssertEqual(SimContent.sha256Hex(long), SimContent.sha256HexPortable(long))
        let ref = SimBlobRef(sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", bytes: 3)
        XCTAssertTrue(SimContent.verify(Data("abc".utf8), ref: ref))
        XCTAssertFalse(SimContent.verify(Data("abd".utf8), ref: ref))
        XCTAssertFalse(SimContent.verify(Data("abc".utf8), ref: SimBlobRef(sha256: ref.sha256, bytes: 4)))
    }
}
