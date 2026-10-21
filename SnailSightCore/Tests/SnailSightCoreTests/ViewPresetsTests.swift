import XCTest
@testable import SnailSightCore

final class ViewPresetsTests: XCTestCase {
    func testCameraAnimalsTurnsEverythingOffAndRemembersTheFullSet() {
        var st = ViewPresetState()
        let mine = LayerSnapshot(house: "Ghost", meshLive: true, objects: false, terrain: true, cameras: true, agents: false)
        let applied = st.select(.cameraAnimals, current: mine)
        XCTAssertEqual(applied, .cameraOnly)
        XCTAssertEqual(applied?.house, "Off")
        XCTAssertEqual(st.preset, .cameraAnimals)
        XCTAssertEqual(st.fullSet, mine)
        // Full world restores exactly what they had
        XCTAssertEqual(st.select(.fullWorld, current: .cameraOnly), mine)
        XCTAssertEqual(st.preset, .fullWorld)
    }

    func testFullWorldNeverRestoresAnEmptyWorld() {
        var st = ViewPresetState()
        _ = st.select(.cameraAnimals, current: .cameraOnly)       // nothing was ever on
        XCTAssertEqual(st.select(.fullWorld, current: .cameraOnly), .fullDefault)
    }

    func testManualChangeSwitchesToCustomAndFullSetFollows() {
        var st = ViewPresetState()
        var cur = LayerSnapshot.fullDefault
        cur.terrain = true
        st.manualChange(current: cur)
        XCTAssertEqual(st.preset, .custom)
        XCTAssertEqual(st.fullSet.terrain, true)                  // changed on Full world: the set follows
        // from camera+animals a manual toggle keeps the saved full set
        var s2 = ViewPresetState()
        _ = s2.select(.cameraAnimals, current: .fullDefault)
        var c2 = LayerSnapshot.cameraOnly; c2.cameras = true
        s2.manualChange(current: c2)
        XCTAssertEqual(s2.preset, .custom)
        XCTAssertEqual(s2.fullSet, .fullDefault)
    }

    func testCustomSelectChangesNothing() {
        var st = ViewPresetState()
        XCTAssertNil(st.select(.custom, current: .fullDefault))
        XCTAssertEqual(st.preset, .custom)
    }

    func testPersistenceRoundTripAndBadData() {
        var st = ViewPresetState()
        st.worldOn = false
        _ = st.select(.cameraAnimals, current: .fullDefault)
        XCTAssertEqual(ViewPresetState.decode(st.encoded()), st)
        XCTAssertEqual(ViewPresetState.decode(Data("junk".utf8)), ViewPresetState())
        XCTAssertEqual(ViewPresetState.decode(nil), ViewPresetState())
    }

    func testReconcileDowngradesStalePreset() {
        var st = ViewPresetState()
        _ = st.select(.cameraAnimals, current: .fullDefault)
        var c = LayerSnapshot.cameraOnly; c.agents = true
        st.reconcile(current: c)
        XCTAssertEqual(st.preset, .custom)
        var f = ViewPresetState()
        f.reconcile(current: .fullDefault)
        XCTAssertEqual(f.preset, .fullWorld)
    }

    func testWorldGateMasksWithoutChangingSettings() {
        let s = LayerSnapshot(house: "Wire", meshLive: true, objects: true, terrain: true, cameras: true, agents: true)
        XCTAssertEqual(WorldGate.house(s, worldOn: false), "Off")
        XCTAssertEqual(WorldGate.house(s, worldOn: true), "Wire")
        XCTAssertFalse(WorldGate.meshLive(s, worldOn: false))
        XCTAssertFalse(WorldGate.objects(s, worldOn: false))
        XCTAssertFalse(WorldGate.terrain(s, worldOn: false))
        XCTAssertFalse(WorldGate.estimated(worldOn: false))
        XCTAssertTrue(WorldGate.meshLive(s, worldOn: true) && WorldGate.terrain(s, worldOn: true) && WorldGate.objects(s, worldOn: true))
        XCTAssertEqual(s.house, "Wire")                            // untouched
    }

    func testFetchGatingAndDownlink() {
        let model = LayerSnapshot(house: "Model")
        XCTAssertTrue(WorldGate.fetchesHouse(model, worldOn: true))
        XCTAssertFalse(WorldGate.fetchesHouse(model, worldOn: false))
        XCTAssertFalse(WorldGate.fetchesHouse(LayerSnapshot(house: "Labels"), worldOn: true))
        XCTAssertFalse(WorldGate.fetchesHouse(LayerSnapshot(house: "Off"), worldOn: true))
        var noAgents = LayerSnapshot.fullDefault; noAgents.agents = false
        XCTAssertFalse(WorldGate.downlinkWanted(noAgents, worldOn: false))
        XCTAssertTrue(WorldGate.downlinkWanted(noAgents, worldOn: true))
        XCTAssertFalse(WorldGate.downlinkWanted(.cameraOnly, worldOn: true))
        XCTAssertTrue(WorldGate.downlinkWanted(.fullDefault, worldOn: false))   // agents are not world
    }
}
