import XCTest
@testable import SnailSightCore

final class UIShellTests: XCTestCase {
    func testSheetDetentsSettleNearestAndFling() {
        let h = 844.0
        XCTAssertEqual(SheetDetent.collapsed.height(container: h), 148)
        XCTAssertLessThan(SheetDetent.half.height(container: h), SheetDetent.full.height(container: h))
        XCTAssertEqual(SheetDetent.settle(height: 160, velocity: 0, container: h), .collapsed)
        XCTAssertEqual(SheetDetent.settle(height: SheetDetent.half.height(container: h) + 10, velocity: 0, container: h), .half)
        XCTAssertEqual(SheetDetent.settle(height: 800, velocity: 0, container: h), .full)
        // a downward fling from near half closes to collapsed; an upward one from collapsed opens to half
        XCTAssertEqual(SheetDetent.settle(height: SheetDetent.half.height(container: h) - 20, velocity: 900, container: h), .collapsed)
        XCTAssertEqual(SheetDetent.settle(height: 170, velocity: -900, container: h), .half)
    }

    func testQuickActionsAreTheFourFromC1WithLabels() {
        XCTAssertEqual(QuickAction.allCases.map(\.title), ["Spawn", "Room scan", "Live map", "Record"])
        XCTAssertEqual(QuickAction.record.accessibility(on: true), "Stop recording")
        XCTAssertTrue(QuickAction.liveMap.accessibility(on: false).contains("shared mesh"))
    }

    func testNearListSortsByDistanceAndFilters() {
        let items = [
            NearItem(id: "fox", kind: .animal, title: "Fox", subtitle: "Grazing", position: [3, 0, 0]),
            NearItem(id: "bob", kind: .robot, title: "RobosnailBob", subtitle: "Patrolling", position: [7, 0, 0]),
            NearItem(id: "cam", kind: .camera, title: "Downstairs camera", subtitle: "Ring", position: [1, 1, 3]),
            NearItem(id: "gym", kind: .place, title: "Gym"),
        ]
        let l = NearList.build(items, me: [0, 0, 0])
        XCTAssertEqual(l.map(\.id), ["cam", "fox", "bob", "gym"])          // cam: 1.41 + 1.5 (height) = 2.9 m
        XCTAssertEqual(l[1].primaryTitle, "Follow")
        XCTAssertEqual(l[2].primaryTitle, "Go to")
        XCTAssertEqual(l[0].primaryTitle, "Live")
        XCTAssertEqual(l[3].primaryTitle, "Locate")
        XCTAssertEqual(NearList.distanceText(l[1].distance), "3.0 m")
        XCTAssertEqual(NearList.distanceText(12.4), "12 m")
        XCTAssertEqual(NearList.filter(l, query: "down cam").map(\.id), ["cam"])
        XCTAssertEqual(NearList.filter(l, query: "robot").map(\.id), ["bob"])    // the kind matches too
        XCTAssertEqual(NearList.filter(l, query: "").count, 4)
        XCTAssertEqual(NearList.build(items, me: [0, 0, 0], limit: 2).count, 2)
        XCTAssertEqual(l[1].badge, "F")
    }

    func testLayerKeysCoverTheAgreedToggles() {
        XCTAssertEqual(MapLayerKey.allCases.map(\.title),
                       ["Mesh (live)", "Structure", "X-ray", "Objects", "Terrain", "Cameras", "Paths", "Other agents"])
    }

    func testRingCommandsFollowWhatTheBodyOffers() {
        let animal = SimCommand.offered(role: .animal, server: true)
        XCTAssertEqual(RingCommand.ring(offered: animal), [.goTo, .follow, .flee, .stay, .roam, .delete])
        let robot = SimCommand.offered(role: .robot, server: true)
        XCTAssertEqual(RingCommand.ring(offered: robot), [.goTo, .follow, .stay, .delete])
        XCTAssertEqual(RingCommand.command(.stay, offered: robot), .stop)
        XCTAssertEqual(RingCommand.command(.stay, offered: animal), .stay)
        let drone = SimCommand.offered(role: .robot, drone: true, server: true)
        XCTAssertEqual(RingCommand.ring(offered: drone), [.goTo, .stay, .delete])
    }

    func testRingLayoutStaysOnScreen() {
        let r = CommandRing.layout(center: V2(10, 10), count: 6, bounds: [0, 0, 390, 600])
        XCTAssertEqual(r.points.count, 6)
        for p in r.points {
            XCTAssertGreaterThanOrEqual(p.x - CommandRing.buttonSize / 2, 0)
            XCTAssertGreaterThanOrEqual(p.y - CommandRing.buttonSize / 2, 0)
            XCTAssertLessThanOrEqual(p.x + CommandRing.buttonSize / 2, 390)
        }
        XCTAssertEqual(r.points[0].x, r.center.x, accuracy: 1e-9)               // first button at the top
        XCTAssertLessThan(r.points[0].y, r.center.y)
        XCTAssertGreaterThanOrEqual(CommandRing.buttonSize, 44)
    }

    func testPlanTransformRoundTripZoomPan() {
        let t = PlanTransform.fit([-10, -5, 10, 5], size: V2(390, 600))
        let p = V2(3.5, -2)
        let v = t.toView(p)
        XCTAssertEqual(t.toMap(v).x, p.x, accuracy: 1e-9); XCTAssertEqual(t.toMap(v).y, p.y, accuracy: 1e-9)
        XCTAssertLessThan(t.toView(V2(0, 5)).y, t.toView(V2(0, -5)).y)        // north up
        let z = t.zoomed(by: 2, anchor: v)
        XCTAssertEqual(z.toMap(v).x, p.x, accuracy: 1e-6); XCTAssertEqual(z.ppm, t.ppm * 2, accuracy: 1e-9)
        let q = t.panned(by: V2(t.ppm, 0))                                      // drag right 1 m → map moves left
        XCTAssertEqual(q.center.x, t.center.x - 1, accuracy: 1e-9)
        let bar = PlanTransform(center: .zero, ppm: 40, size: V2(390, 600)).scaleBarMetres
        XCTAssertEqual(bar, 2)
    }

    func testPlanLevelsLabelsBasementAndYard() {
        let l = PlanLevels.make([(0, -1.34), (1, 1.36), (2, 3.96)], yard: true)
        XCTAssertEqual(l.map(\.label), ["B", "1", "2", "Yd"])
        XCTAssertEqual(l.map(\.title), ["Basement", "Main floor", "Upstairs", "Yard"])
        XCTAssertEqual(PlanLevels.level(ofZ: 0.2, in: l)?.label, "B")
        XCTAssertEqual(PlanLevels.level(ofZ: 1.5, in: l)?.label, "1")
        XCTAssertEqual(PlanLevels.level(ofZ: 5, in: l)?.label, "2")
        XCTAssertEqual(PlanLevels.entry(l)?.level, 1)
        XCTAssertEqual(PlanLevels.make([(0, nil)], yard: false).map(\.label), ["1"])
    }
}

final class PlacementTests: XCTestCase {
    func testRealCameraPlacementDecodes() {
        let j = #"{"map_id":"site","entities":[{"kind": "camera", "pose": {"x": 6.5, "y": 4.7, "z": 4.0, "yaw": -0.23}, "map_version": 14, "record": {"estimated": true, "source": "ring:back_cam", "camera_id": "ring_back_cam", "mount_h": 3.5, "pitch": -14.5, "hfov": 140, "vfov": 78, "near": 3.0, "far": 30.0, "level": 2, "enabled": true}, "name": "Back Camera (Ring)", "id": "cam-ring_back_cam"}, {"kind":"fox","pose":{"x":0,"y":0,"z":0,"yaw":0},"id":"fox-1"}]}"#
        let p = PlacementDoc.parse(Data(j.utf8))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].title, "Back Camera (Ring)")
        XCTAssertEqual(p[0].subtitle, "Ring · estimated spot")
        XCTAssertEqual(p[0].record?.level, 2)
        XCTAssertEqual(p[0].record?.hfov, 140)
    }
}
