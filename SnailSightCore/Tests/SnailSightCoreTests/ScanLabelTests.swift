import XCTest
import simd
@testable import SnailSightCore

/// 9.8 Scans labeling: rooms doc + polygon editing, HA areas, objects doc round-trip, phone labels, corrections
/// (rename / delete / merge), search, map-frame labels and transforms.
final class ScanLabelTests: XCTestCase {
    let roomsJSON = """
    {"scene":"site@5","revision":3,"updated":1791000000.5,"frame":"map/site v5 (Z-up, metres)",
     "rooms":[{"id":"r1","name":"Kitchen","ha_area_id":"kitchen","polygon":[[0,0],[4,0],[4,3],[0,3]],"floor_z":-1.28,
               "height":2.4,"color":"#4363d8","area_m2":12.0,"notes":""},
              {"id":"r2","name":"Hall","ha_area_id":null,"polygon":[[4,0],[6,0],[6,3],[4,3]],"floor_z":-1.28,
               "height":2.4,"color":"#3cb44b","area_m2":6.0,"notes":"by the door"}],
     "carried_from":null}
    """

    let objectsJSON = """
    {"scene":"site@5","revision":7,"updated":1791000001,"detector":"yoloe-v1","frame":"map/site v5 (Z-up, metres)",
     "objects":[
      {"id":"o1","label":"sofa","category":"furniture","static":true,"room_id":null,"ha_area_id":null,
       "centroid":[1,1,-0.9],"box":{"center":[1,1,-0.9],"size":[2,0.9,0.8],"yaw":0.0},"confidence":0.8,
       "first_seen":100,"last_seen":200,"observations":3,"state":"present","session_ids":["s-a"],"source":"yoloe-v1",
       "attributes":{"color":"grey","nested":{"k":[1,"two",null,true]}}},
      {"id":"o2","label":"couch","category":"furniture","static":true,"room_id":null,"ha_area_id":null,
       "centroid":[2,1,-0.9],"box":{"center":[2,1,-0.9],"size":[1,1,0.8],"yaw":0.0},"confidence":0.6,
       "first_seen":50,"last_seen":300,"observations":1,"state":"present","session_ids":["s-b","s-a"],"source":"yoloe-v1",
       "attributes":{}},
      {"id":"m-1","label":"Spare keys","category":"movable","static":false,"room_id":"r2","ha_area_id":null,
       "centroid":[5,1,-0.3],"box":{"center":[5,1,-0.3],"size":[0.2,0.2,0.2],"yaw":0},"confidence":1,
       "first_seen":10,"last_seen":10,"observations":1,"state":"present","session_ids":[],"source":"manual",
       "attributes":{"notes":"hook left of the door"}}]}
    """

    func testRoomsDocDecodePutAndLookup() throws {
        let doc = try RoomsDoc.decode(Data(roomsJSON.utf8))
        XCTAssertEqual(doc.revision, 3); XCTAssertEqual(doc.rooms.count, 2)
        XCTAssertEqual(doc.rooms[0].haAreaID, "kitchen"); XCTAssertNil(doc.rooms[1].haAreaID)
        XCTAssertEqual(doc.room(containing: SIMD3(1, 1, -0.5))?.id, "r1")
        XCTAssertEqual(doc.room(containing: SIMD3(5, 1, -0.5))?.id, "r2")
        XCTAssertNil(doc.room(containing: SIMD3(1, 1, 5)))                 // the floor above
        XCTAssertNil(doc.room(containing: SIMD3(9, 1, -1)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.putBody()) as? [String: Any])
        XCTAssertEqual(body["base_revision"] as? Int, 3)
        let rooms = try XCTUnwrap(body["rooms"] as? [[String: Any]])
        XCTAssertEqual(rooms[0]["ha_area_id"] as? String, "kitchen")
        XCTAssertEqual((rooms[0]["polygon"] as? [[Double]])?.count, 4)
        XCTAssertEqual(rooms[1]["notes"] as? String, "by the door")
        XCTAssertEqual(doc.newRoomID(), "r3")
        XCTAssertEqual(doc.nextColor(), RoomsDoc.palette[2])
    }

    func testHAAreas() {
        let d = Data(#"{"ok":true,"areas":[{"area_id":"office","name":"Office","floor_id":"up","floor":"Upstairs"},{"area_id":"kitchen","name":"Kitchen","floor_id":null,"floor":""}]}"#.utf8)
        let a = HAArea.decodeList(d)
        XCTAssertEqual(a.map(\.areaID), ["kitchen", "office"])
        XCTAssertTrue(HAArea.decodeList(Data("garbage".utf8)).isEmpty)
        let rooms = [RoomRecord(id: "r1", name: "Kitchen", polygon: [], floorZ: nil, haAreaID: "kitchen")]
        XCTAssertEqual(HAArea.suggestions(a, rooms: rooms, editing: nil).map(\.areaID), ["office", "kitchen"])
        XCTAssertEqual(HAArea.suggestions(a, rooms: rooms, editing: "r1").map(\.areaID), ["kitchen", "office"])
    }

    func testPolygonMaths() {
        let sq: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(2, 0), SIMD2(2, 1), SIMD2(0, 1)]
        XCTAssertEqual(Polygon2D.signedArea(sq), 2, accuracy: 1e-12)
        XCTAssertEqual(Polygon2D.signedArea(Array(sq.reversed())), -2, accuracy: 1e-12)
        XCTAssertEqual(Polygon2D.ccw(Array(sq.reversed())), sq)
        XCTAssertTrue(Polygon2D.contains(sq, SIMD2(1, 0.5)))
        XCTAssertFalse(Polygon2D.contains(sq, SIMD2(3, 0.5)))
        let c = Polygon2D.centroid(sq)
        XCTAssertEqual(c.x, 1, accuracy: 1e-12); XCTAssertEqual(c.y, 0.5, accuracy: 1e-12)
        let bow: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(2, 2), SIMD2(2, 0), SIMD2(0, 2)]
        XCTAssertTrue(Polygon2D.selfIntersects(bow))
        XCTAssertFalse(Polygon2D.selfIntersects(sq))
        // L-shaped room: centroid inside the L's mass
        let L: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 1), SIMD2(1, 1), SIMD2(1, 4), SIMD2(0, 4)]
        XCTAssertEqual(Polygon2D.area(L), 7, accuracy: 1e-12)
        XCTAssertFalse(Polygon2D.selfIntersects(L))
    }

    func testPolygonEditorDrawAndEdit() {
        var ed = RoomPolygonEditor()
        // drawn clockwise (the server stores CCW: polygon() reverses)
        XCTAssertEqual(ed.tap(SIMD2(0, 0), snap: 0.2), .added)
        XCTAssertEqual(ed.tap(SIMD2(0, 3), snap: 0.2), .added)
        XCTAssertEqual(ed.problem(), "A room needs at least 3 corners")
        XCTAssertEqual(ed.tap(SIMD2(4, 3), snap: 0.2), .added)
        XCTAssertEqual(ed.tap(SIMD2(4, 0), snap: 0.2), .added)
        XCTAssertEqual(ed.problem(), "Close the outline (tap the first corner)")
        XCTAssertEqual(ed.tap(SIMD2(0.1, 0.05), snap: 0.2), .closed)           // tap near the first corner
        XCTAssertTrue(ed.closed); XCTAssertNil(ed.problem())
        let poly = ed.polygon()
        XCTAssertGreaterThan(Polygon2D.signedArea(poly.map { SIMD2($0[0], $0[1]) }), 0)
        // tap near an edge: a corner is inserted there and selected
        XCTAssertEqual(ed.tap(SIMD2(2, 3.1), snap: 0.2), .inserted(2))
        XCTAssertEqual(ed.points.count, 5); XCTAssertEqual(ed.points[2], SIMD2(2, 3)); XCTAssertEqual(ed.selected, 2)
        // drag it out (a bay window), still valid
        ed.move(2, to: SIMD2(2, 4))
        XCTAssertNil(ed.problem())
        XCTAssertEqual(Polygon2D.area(ed.points), 14, accuracy: 1e-9)
        // tap a corner: selected
        XCTAssertEqual(ed.tap(SIMD2(3.95, 0.02), snap: 0.2), .selected(4))
        // tap empty space: deselect
        XCTAssertEqual(ed.tap(SIMD2(10, 10), snap: 0.2), .deselected)
        XCTAssertEqual(ed.tap(SIMD2(10, 10), snap: 0.2), .none)
        // delete down to 3, never below
        XCTAssertTrue(ed.delete(2)); XCTAssertTrue(ed.delete(0))
        XCTAssertEqual(ed.points.count, 3)
        XCTAssertFalse(ed.delete(0))
        // crossing outline rejected; tiny outline rejected
        var x = RoomPolygonEditor(points: [SIMD2(0, 0), SIMD2(2, 2), SIMD2(2, 0), SIMD2(0, 2)], closed: true)
        XCTAssertEqual(x.problem(), "The outline crosses itself")
        x = RoomPolygonEditor(points: [SIMD2(0, 0), SIMD2(0.1, 0), SIMD2(0.1, 0.1)], closed: true)
        XCTAssertEqual(x.problem(), "The outline is too small")
        // open outline: undo, close()
        var o = RoomPolygonEditor()
        _ = o.tap(SIMD2(0, 0), snap: 0.1); _ = o.tap(SIMD2(1, 0), snap: 0.1); _ = o.tap(SIMD2(1, 1), snap: 0.1)
        o.undoLast(); XCTAssertEqual(o.points.count, 2); XCTAssertFalse(o.close())
        _ = o.tap(SIMD2(1, 1), snap: 0.1); XCTAssertTrue(o.close())
        // from a room
        let r = RoomRecord(id: "r1", name: "K", polygon: [[0, 0], [1, 0], [1, 1]], floorZ: 0)
        XCTAssertEqual(RoomPolygonEditor(room: r).points.count, 3)
        XCTAssertTrue(RoomPolygonEditor(room: r).closed)
    }

    func testObjectsDocRoundTrip() throws {
        let doc = try ObjectsDoc.decode(Data(objectsJSON.utf8))
        XCTAssertEqual(doc.revision, 7); XCTAssertEqual(doc.objects.count, 3)
        XCTAssertFalse(doc.objects[0].isManual); XCTAssertTrue(doc.objects[2].isManual)
        XCTAssertEqual(doc.objects[2].notes, "hook left of the door")
        XCTAssertEqual(doc.objects[0].attributes?["nested"], .object(["k": .array([.number(1), .string("two"), .null, .bool(true)])]))
        let again = try ObjectsDoc.decode(JSONEncoder().encode(doc))
        XCTAssertEqual(again, doc)                                         // attributes survive untouched
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.putBody()) as? [String: Any])
        XCTAssertEqual(body["base_revision"] as? Int, 7)
        XCTAssertNil(body["detector"])                                     // a phone edit is not a detector run
        let o0 = try XCTUnwrap((body["objects"] as? [[String: Any]])?.first)
        XCTAssertEqual(o0["static"] as? Bool, true); XCTAssertEqual(o0["source"] as? String, "yoloe-v1")
        // the pin of a detected object sits on top of its box; a manual pin at its point
        XCTAssertEqual(doc.objects[0].pinPoint?.z ?? 0, -0.5, accuracy: 1e-9)
        XCTAssertEqual(doc.objects[2].pinPoint?.z ?? 0, -0.3, accuracy: 1e-9)
    }

    func testP4FieldsRoundTrip() throws {
        let j = #"{"revision":4,"objects":[{"id":"d1","label":"stool","det_label":"chair","name":"Mom's chair","category":"furniture","static":true,"centroid":[0,0,0],"source":"yoloe-v1+owner","corrections":["c-1a2b3c4d"],"attributes":{"note":"wobbly"}}],"deleted":[{"id":"d2"}],"deleted_count":1,"corrections_revision":3}"#
        let doc = try ObjectsDoc.decode(Data(j.utf8))
        let o = doc.objects[0]
        XCTAssertEqual(o.detLabel, "chair"); XCTAssertEqual(o.name, "Mom's chair"); XCTAssertEqual(o.displayName, "Mom's chair")
        XCTAssertEqual(o.corrections, ["c-1a2b3c4d"]); XCTAssertEqual(o.notes, "wobbly"); XCTAssertFalse(o.isManual)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.putBody()) as? [String: Any])
        let b0 = try XCTUnwrap((body["objects"] as? [[String: Any]])?.first)
        XCTAssertEqual(b0["det_label"] as? String, "chair"); XCTAssertEqual(b0["name"] as? String, "Mom's chair")
        XCTAssertEqual(b0["corrections"] as? [String], ["c-1a2b3c4d"])
        XCTAssertEqual(LabelSearch.filter(doc.objects, query: "mom", category: nil, source: .all).count, 1)
    }

    func testNewLabelAndEdits() throws {
        let doc = try ObjectsDoc.decode(Data(objectsJSON.utf8))
        let l = ObjectEdits.newLabel(id: "m-2", name: "Router", category: .appliance, notes: "ISP box",
                                     at: SIMD3(1.234567, -2, 0.5), roomID: "r1", haAreaID: "kitchen",
                                     photoThumbBase64: "AAAA", by: "snailsight-test", now: 1000)
        XCTAssertEqual(l.source, "manual"); XCTAssertEqual(l.isStatic, true); XCTAssertEqual(l.centroid, [1.2346, -2, 0.5])
        XCTAssertEqual(l.box?.size, [0.2, 0.2, 0.2]); XCTAssertEqual(l.notes, "ISP box"); XCTAssertEqual(l.photoThumbBase64, "AAAA")
        XCTAssertEqual(l.name, "Router"); XCTAssertEqual(l.attributes?["note"], .string("ISP box"))
        XCTAssertEqual(l.roomID, "r1")
        // rename a detected object: correction recorded; editing my own label: none recorded
        var objs = ObjectEdits.edit(doc.objects, id: "o1", label: "Sofa (grey)", category: .furniture, notes: nil, by: "t", now: 5)
        XCTAssertEqual(objs[0].label, "Sofa (grey)")
        let corr = try XCTUnwrap(objs[0].attributes?["phone_corrections"]?.arrayValue)
        XCTAssertEqual(corr.count, 1)
        XCTAssertEqual(objs[0].attributes?["color"], .string("grey"))         // other attributes kept
        objs = ObjectEdits.edit(objs, id: "o2", label: nil, category: .movable, notes: nil, by: "t", now: 6)
        XCTAssertEqual(objs[1].category, "movable"); XCTAssertEqual(objs[1].isStatic, false)
        objs = ObjectEdits.edit(objs, id: "m-1", label: "Keys", category: nil, notes: "", by: "t", now: 7)
        XCTAssertEqual(objs[2].label, "Keys"); XCTAssertNil(objs[2].attributes?["phone_corrections"]); XCTAssertEqual(objs[2].notes, "")
        XCTAssertNil(objs[2].attributes?["notes"]); XCTAssertNil(objs[2].attributes?["note"])
        // owner name on a detected object (P4 field), class kept
        let named = ObjectEdits.edit(doc.objects, id: "o1", name: "Mom's sofa", label: nil, category: nil, notes: "comfy", by: "t", now: 9)
        XCTAssertEqual(named[0].displayName, "Mom's sofa"); XCTAssertEqual(named[0].label, "sofa")
        XCTAssertEqual(named[0].attributes?["note"], .string("comfy"))
        XCTAssertEqual(named[0].attributes?["phone_corrections"]?.arrayValue?.count, 1)
        // a phone label: the name is its label too
        let mine = ObjectEdits.edit(doc.objects, id: "m-1", name: "House keys", label: nil, category: nil, notes: nil, by: "t", now: 9)
        XCTAssertEqual(mine[2].label, "House keys"); XCTAssertEqual(mine[2].displayName, "House keys")
        // unchanged label on a detected object: nothing recorded
        let same = ObjectEdits.edit(doc.objects, id: "o2", label: "couch", category: nil, notes: nil, by: "t", now: 8)
        XCTAssertNil(same[1].attributes?["phone_corrections"])
        XCTAssertEqual(ObjectEdits.delete(doc.objects, ids: ["o1", "m-1"]).map(\.id), ["o2"])
    }

    func testMerge() throws {
        let doc = try ObjectsDoc.decode(Data(objectsJSON.utf8))
        let m = ObjectEdits.merge(doc.objects, ids: ["o1", "o2"], into: "o1", by: "t", now: 9)
        XCTAssertEqual(m.map(\.id), ["o1", "m-1"])
        let o = m[0]
        XCTAssertEqual(o.label, "sofa")
        XCTAssertEqual(o.observations, 4)
        XCTAssertEqual(o.centroid[0], 1.25, accuracy: 1e-9)                 // (1·3 + 2·1) / 4
        XCTAssertEqual(o.box?.center[0] ?? 0, 1.25, accuracy: 1e-9)          // x from 0 … 2.5
        XCTAssertEqual(o.box?.size[0] ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(o.confidence, 0.8)
        XCTAssertEqual(o.sessionIDs, ["s-a", "s-b"])
        XCTAssertEqual(o.firstSeen, .number(50)); XCTAssertEqual(o.lastSeen, .number(300))
        XCTAssertEqual(o.attributes?["merged_from"], .array([.string("o2")]))
        XCTAssertEqual(o.attributes?["phone_corrections"]?.arrayValue?.count, 1)
        XCTAssertEqual(ObjectEdits.merge(doc.objects, ids: ["o1"], into: "o1", by: "t", now: 9), doc.objects)   // nothing to merge
        XCTAssertEqual(ObjectEdits.merge(doc.objects, ids: ["o1", "o2"], into: "zz", by: "t", now: 9), doc.objects)
    }

    func testAssignRoomsIDsAndSearch() throws {
        let rooms = try RoomsDoc.decode(Data(roomsJSON.utf8))
        let doc = try ObjectsDoc.decode(Data(objectsJSON.utf8))
        let a = ObjectEdits.assignRooms(doc.objects, rooms: rooms)
        XCTAssertEqual(a[0].roomID, "r1"); XCTAssertEqual(a[0].haAreaID, "kitchen")
        XCTAssertEqual(a[2].roomID, "r2")                                   // already set: kept
        var seq: [UInt32] = [1, 1, 2]
        let id = ObjectEdits.newID([SceneObject(id: "m-00000001", label: "x", category: "other", centroid: [0, 0, 0])],
                                   random: { seq.removeFirst() })
        XCTAssertEqual(id, "m-00000002")
        let all = LabelSearch.filter(a, query: "", category: nil, source: .all)
        XCTAssertEqual(all.map(\.label), ["couch", "sofa", "Spare keys"])
        XCTAssertEqual(LabelSearch.filter(a, query: "", category: nil, source: .manual).map(\.id), ["m-1"])
        XCTAssertEqual(LabelSearch.filter(a, query: "", category: nil, source: .detected).count, 2)
        XCTAssertEqual(LabelSearch.filter(a, query: "HOOK", category: nil, source: .all).map(\.id), ["m-1"])   // notes
        XCTAssertEqual(LabelSearch.filter(a, query: "kitchen", category: nil, source: .all, rooms: rooms.rooms).count, 2)
        XCTAssertEqual(LabelSearch.filter(a, query: "", category: .movable, source: .all).map(\.id), ["m-1"])
    }

    func testMapLabelsAndTransforms() throws {
        let rooms = try RoomsDoc.decode(Data(roomsJSON.utf8))
        let objs = try ObjectsDoc.decode(Data(objectsJSON.utf8))
        let set = MapLabels.build(scene: "site@5", rooms: rooms, objects: objs, defaultFloorZ: nil)
        XCTAssertEqual(set.labels.count, 5)
        XCTAssertEqual(set.roomsRevision, 3); XCTAssertEqual(set.objectsRevision, 7)
        let k = try XCTUnwrap(set.labels.first { $0.id == "room:r1" })
        XCTAssertEqual(k.position[0], 2, accuracy: 1e-9); XCTAssertEqual(k.position[1], 1.5, accuracy: 1e-9)
        XCTAssertEqual(k.position[2], -1.28 + 1.2, accuracy: 1e-9)
        // viewer frame: map (x, y, z) → (x, z, −y)
        XCTAssertEqual(k.yUp.y, Float(-0.08), accuracy: 1e-5); XCTAssertEqual(k.yUp.z, -1.5, accuracy: 1e-5)
        // the JSON the AR side reads
        let back = try JSONDecoder().decode(MapLabelSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(back, set)
        // map → AR: yaw 90° about Z + translation
        let T = simd_double4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(10, 20, 0, 1)))
        let p = MapLabels.transform([MapLabel(id: "x", kind: "object", name: "x", category: nil, position: [1, 0, 2], roomID: nil)], by: T)
        XCTAssertEqual(p[0].x, 10, accuracy: 1e-12); XCTAssertEqual(p[0].y, 21, accuracy: 1e-12); XCTAssertEqual(p[0].z, 2, accuracy: 1e-12)
        // a viewer-frame mesh hit → map frame
        let m = MapLabels.mapPoint(fromYUp: SIMD3(1, 2, -3))
        XCTAssertEqual(m, SIMD3(1, 3, 2))
        // missing objects are not labelled
        var gone = objs; gone.objects[0].state = "missing"
        XCTAssertEqual(MapLabels.build(scene: "s", rooms: RoomsDoc(), objects: gone, defaultFloorZ: 0).labels.count, 2)
    }
}
