import SwiftUI
import UIKit
import SnailSightCore

enum ToolMode: String, CaseIterable, Identifiable {
    // 12.5: Select / Inspect is the launch default (owner: accidental cubes); Cube only when picked, never remembered
    case select = "Select / Inspect"
    case cube = "Cube", measure = "Measure", ruler = "1 m ruler"
    case objects = "Objects", robotPath = "Robot path"           // 10.1 AR 1:1 (Sources/AR)
    var id: String { rawValue }
    var kind: TapToolKind {
        switch self {
        case .select: return .select
        case .cube: return .cube
        case .measure: return .measure
        case .ruler: return .ruler
        case .objects: return .objects
        case .robotPath: return .robotPath
        }
    }
    init(_ k: TapToolKind) { self = ToolMode.allCases.first { $0.kind == k } ?? .select }
    var help: String {
        switch self {
        case .select: return "Tap a body to command it · tap a surface for a measure point"
        case .cube: return "Tap a surface to drop a 10 cm cube"
        case .measure: return "Tap point A, then point B"
        case .ruler: return "Tap where the 0 end goes; it points away from you"
        case .objects: return "Tap a detected object to rename it or delete a wrong one"
        case .robotPath: return "Tap the floor: can the robot get there?"
        }
    }
}

enum MeshStyle: String, CaseIterable, Identifiable {
    case off = "Off", wire = "Wire", debug = "Debug"
    var id: String { rawValue }
}

/// UI state. Mutated on the main thread only (ARSession delegate callbacks arrive on main; network actors report
/// through DispatchQueue.main).
final class AppModel: ObservableObject {
    // MARK: 12.25 app modes (core CopMode.swift): AR explore (camera, ARSession, localizer, Live map) or snailCOP (the
    // cop.snail portal in a web view, no camera). nil = the launch chooser. AR starts only when the owner switches to it.
    @Published private(set) var appMode: AppMode?
    @Published var askModeAtLaunch: Bool = UserDefaults.standard.bool(forKey: LaunchMode.askKey) {
        didSet {
            UserDefaults.standard.set(askModeAtLaunch, forKey: LaunchMode.askKey)
            if askModeAtLaunch != oldValue { log.event("app_mode_ask", ["on": .bool(askModeAtLaunch)]) }
        }
    }
    var rememberedMode: AppMode? { AppMode(rawValue: UserDefaults.standard.string(forKey: LaunchMode.rememberedKey) ?? "") }
    @Published var showCopAddress = false
    /// The AR stack has been started this run (camera + session + localizer); paused while snailCOP is up.
    private(set) var arStarted = false
    private(set) var arPausedForCop = false
    private(set) lazy var cop = CopController(model: self)
    /// "Open AR here" from snailCOP: the spot to walk to and the HUD line that guides there.
    @Published var arTarget: ARHandoffTarget?
    @Published var arTargetText: String?
    /// The phone's last localized camera pose in the map frame (for snailCOP's "you are here").
    private(set) var lastMapPose: (cam: [Double], ahead: [Double], t: Double)?
    private var launchDone = false
    private var pendingLink: AppDeepLink?

    /// 12.5: every launch starts on Select / Inspect (TapToolState); not persisted.
    private(set) var toolState = TapToolState()
    @Published var tool: ToolMode = ToolMode(TapToolState.launchDefault) {
        didSet {
            guard tool != oldValue else { return }
            toolState.pick(tool.kind)
            log.event("tap_tool", ["tool": .string(tool.kind.rawValue), "from": .string(oldValue.kind.rawValue),
                                   "explicit": .bool(toolState.explicitPick)])
            if tool != .robotPath { terrainLayer.clearPath() }       // its footprint + path belong to the tool
        }
    }
    /// 12.5 drive: the joystick for the selected drivable body (robot / rc_car) — hidden with its ✕ until reselected.
    @Published var driveHidden = true                     // 12.7: drive mode replaced the single joystick
    @Published var driveTank = false
    @Published var meshStyle: MeshStyle = .wire { didSet { controller.applyRenderSettings() } }
    @Published var occlusion = true { didSet { controller.applyRenderSettings() } }
    @Published var peopleOcclusion = true { didSet { controller.rerunConfiguration() } }
    @Published var hudCollapsed = false
    // S1 simulated agents in AR (plan §7 S): off by default, paused while recording unless allowed
    @Published var simOn = false { didSet { if simOn != oldValue { controller.sim.setEnabled(simOn) } } }
    @Published var simAllowWhileRecording = UserDefaults.standard.bool(forKey: "sim.allowWhileRecording") {
        didSet { UserDefaults.standard.set(simAllowWhileRecording, forKey: "sim.allowWhileRecording") }
    }
    @Published var simStatus = ""
    @Published var simRobot = false
    /// 9.8 Sim scale (owner: "everything cut in half"): 25–100 %, default 50 %, remembered. Every body without its own
    /// override follows it (visuals, collision, navigation footprint, speeds).
    @Published var simScale: Double = {
        let v = UserDefaults.standard.object(forKey: "sim.scale") as? Double
        return SimScale.clampGlobal(v ?? SimScale.defaultGlobal)
    }() {
        didSet {
            UserDefaults.standard.set(simScale, forKey: "sim.scale")
            if abs(simScale - oldValue) > 1e-6 { controller.sim.globalScaleChanged() }
        }
    }
    /// 9.8 Settings ▸ Sim quality: auto (by heat) / full / battery saver.
    @Published var simPerf: SimPerfMode = SimPerfMode(rawValue: UserDefaults.standard.string(forKey: "sim.perf") ?? "") ?? .auto {
        didSet {
            UserDefaults.standard.set(simPerf.rawValue, forKey: "sim.perf")
            controller.refreshHeatBudget(reason: "settings")
        }
    }
    /// Spawn picker "Recent" row (P2a's "last species", generalised).
    @Published var simRecents = SimRecents(keys: UserDefaults.standard.stringArray(forKey: "sim.recents") ?? [])
    @Published var showSpawn = false
    // 10.6 Spawn mode: Spawn → pick an animal / object (or the robot) → tap the floor to place (repeatable) → ✕ ends
    @Published var spawnMode = false
    @Published var spawnPick: String?                // catalog key, or "robot"
    // 10.6 drag a body onto the trash can (bottom centre) to delete it
    @Published var simDragging = false
    @Published var simDragHot = false

    func startSpawnMode() {
        spawnMode = true
        showSpawn = true
        log.event("sim_spawn_mode", ["on": .bool(true)])
    }

    func endSpawnMode() {
        guard spawnMode else { return }
        spawnMode = false
        spawnPick = nil
        log.event("sim_spawn_mode", ["on": .bool(false)])
    }

    /// Spawn mode: a floor tap places the picked kind there (shared server sim when it is in charge, else local).
    func spawnPicked(at pt: CGPoint) {
        guard let k = spawnPick else { showSpawn = true; return }
        if serverSim.isActive {
            serverSim.spawn(k == "robot" ? "robot" : k, arView: controller.arView, at: pt)
        } else if k == RCCar.key {
            flash("The RC car drives in the shared sim: needs the map server and LOCALIZED", seconds: 3)
            return
        } else if k == "robot" {
            controller.sim.spawnRobot(at: pt)
        } else if let it = controller.sim.catalog.item(k) {
            controller.sim.spawn(it, at: pt)
        }
        noteSpawned(k)
    }
    // 9.9 easy cube delete: the selected placed cube (its floating bar), the Cubes list, the 5 s Undo toast
    @Published var cubeSel: CubeSelection?
    @Published var showCubes = false
    @Published var undoText: String?
    /// One-line reason the heat budget eased something off (nil = full quality).
    @Published var heatNote: String?
    /// Slim status pill expanded into the detail card.
    @Published var statusExpanded = false

    func noteSpawned(_ key: String) {
        simRecents.used(key)
        UserDefaults.standard.set(simRecents.keys, forKey: "sim.recents")
    }
    // P2a persistent places (Sources/Places): HUD state, the saved list, the Places sheet
    @Published var place = PlaceHUD()
    @Published var places: [PlaceManifest] = []
    @Published var showPlaces = false
    /// P2b localization against the master `site` map (Sources/Places/MapLocalizer); folded into `place` for the HUD.
    @Published var mapLoc = MapLocState()
    /// 10.2 the top "am I localized?" pill (LocPill via MapLocalizer) and its detail card.
    @Published var locPill = LocPillState(tone: .idle, text: "OFFLINE", rows: [])
    @Published var locExpanded = false
    /// 10.2 "Map mesh" (Sources/MeshMap): off at launch; "Auto when localized" is remembered (default off).
    @Published var meshMapOn = false { didSet { if meshMapOn != oldValue { meshMapper.update() } } }
    @Published var meshMapAuto: Bool = UserDefaults.standard.bool(forKey: "meshmap.auto") {
        didSet {
            UserDefaults.standard.set(meshMapAuto, forKey: "meshmap.auto")
            if meshMapAuto != oldValue { meshMapper.update() }
        }
    }
    /// "mapping · 34 MB · 12 kf" under the pill (nil = hidden); live = capturing right now (not paused).
    @Published var meshMapText: String?
    /// 11.3 Room scan (Sources/RoomScan, RoomPlan → structure layer S4): capturing now + the HUD line (nil = hidden).
    @Published var roomScanOn = false
    @Published var roomScanText: String?
    @Published var meshMapLive = false
    @Published var showSettings = false
    /// 10.0 Live map (Sources/Live/LiveStreamer, API §6b): stream keyframes to the map server while on. Off at launch.
    @Published var liveOn = false {
        didSet {
            if liveOn != oldValue {
                // 12.23: every change of the Live map state is logged with its cause (setLive sets it; anything else
                // shows up as "unattributed", which is a bug to find)
                log.event("live_state", ["on": .bool(liveOn), "cause": .string(liveCause ?? "unattributed"),
                                         "recording": .bool(recording)])
                let cause = liveCause ?? "unattributed"
                liveCause = nil
                if !liveOn { walker.liveTurnedOff(cause: cause) }                // 12.26: the walk ends with Live map
                geo.setEnabled(liveOn)                                          // 12.22 GPS / compass / baro priors
                islands.liveChanged(liveOn)
                liveStreamer.setEnabled(liveOn)
            }
            if liveOn && !oldValue { warmLocalizer(reason: "live_on") }        // 12.21
        }
    }
    @Published var liveRateHz: Double = LiveGate.clampRate(UserDefaults.standard.object(forKey: "live.rateHz") as? Double ?? 2) {
        didSet {
            UserDefaults.standard.set(liveRateHz, forKey: "live.rateHz")
            if liveRateHz != oldValue { liveStreamer.rateChanged() }
        }
    }
    @Published var liveMapID: String = UserDefaults.standard.string(forKey: "live.mapID") ?? "site" {
        didSet { UserDefaults.standard.set(liveMapID, forKey: "live.mapID") }
    }
    /// HUD line while Live map is on (or draining after off); nil = hidden.
    @Published var liveText: String?
    @Published var liveGood = false

    // 12.0 UI shell (concepts C + A2 + B2 + O1/O2): one pull-up sheet, the Map, the layers button
    @Published var sheetDetent: SheetDetent = .collapsed
    @Published var sheetQuery = ""
    /// 12.19 the sheet's chip row: ONE category shown at a time (Near / View / Mapping / Sim / Device), remembered.
    @Published var sheetCategory: SheetCategory = SheetCategory.restore(UserDefaults.standard.string(forKey: "sheet.category")) {
        didSet {
            UserDefaults.standard.set(sheetCategory.rawValue, forKey: "sheet.category")
            if sheetCategory.isSettings { lastSettingsCategory = sheetCategory }
        }
    }
    var lastSettingsCategory: SheetCategory?
    /// 12.19 the Settings quick action / "All tools and settings": open the sheet on a settings category.
    func openSettings(from: String, category: SheetCategory? = nil) {
        sheetCategory = category ?? SheetCategory.settingsTarget(current: sheetCategory, last: lastSettingsCategory)
        sheetDetent = .full
        log.event("sheet_category", ["category": .string(sheetCategory.rawValue), "from": .string(from)])
    }
    @Published var showMap = false
    /// 12.3 Map ▸ 3D: the full-screen non-AR 3D viewer of the whole colour map (over the Map). The AR session is paused
    /// while it is up (one renderer at a time; resume = the Scans path: no reset, normal relocalization).
    @Published var showMap3D = false {
        didSet { if oldValue && !showMap3D { map3DClosed() } }
    }
    /// 12.7 drive mode FPV / Chase (Sources/Drive/DriveViewer): the non-AR 3D view from the driven body is up.
    @Published var showDriveViewer = false
    /// Our AR session is paused (Scans, the 3D map, the drive FPV / Chase view or snailCOP is on screen): nothing may re-run it.
    var arSuspended: Bool { showScans || showMap3D || showDriveViewer || arPausedForCop || !arStarted }
    @Published var showLayers = false
    /// Where the Map should centre when it opens (map frame x, y, z) — set by a sheet row's Show / a room chip.
    @Published var mapFocus: [Double]?
    /// Layers ▸ Mesh (live): the mesh as it is being made — this phone's LiDAR mesh (wire) plus the shared live tiles
    /// of every agent, fresh tiles glowing. On by default (owner 2026-10-18: "retain ability to see the 3d mesh as it's
    /// made … updated with explorations").
    @Published var meshLive: Bool = UserDefaults.standard.object(forKey: "layers.meshLive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(meshLive, forKey: "layers.meshLive")
            guard meshLive != oldValue else { return }
            if meshLive, meshStyle == .off { meshStyle = .wire }
            if !meshLive, meshStyle == .wire { meshStyle = .off }
            log.event("layer", ["name": .string("mesh_live"), "on": .bool(meshLive)])
            layerEdited(true)
        }
    }
    /// 12.1 Layers ▸ Mesh colour: live tiles in their photo colour (server live 0.5 vertex colour) or the wireframe look.
    @Published var meshColour: MeshColour = MeshColour(rawValue: UserDefaults.standard.string(forKey: "layers.meshColour") ?? "") ?? .photo {
        didSet {
            UserDefaults.standard.set(meshColour.rawValue, forKey: "layers.meshColour")
            if meshColour != oldValue { log.event("layer", ["name": .string("mesh_colour"), "mode": .string(meshColour.rawValue)]) }
        }
    }
    /// Layers ▸ Cameras / Paths (Map + AR markers).
    @Published var showCameras: Bool = UserDefaults.standard.object(forKey: "layers.cameras") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCameras, forKey: "layers.cameras"); layerEdited(showCameras != oldValue) }
    }
    @Published var showPaths: Bool = UserDefaults.standard.object(forKey: "layers.paths") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPaths, forKey: "layers.paths") }
    }
    /// 12.18 Layers ▸ Device surface near you (default on): stored map faces this phone has seen this session are
    /// hidden in AR, so the real room (camera + the phone's own scene mesh) is what you see near you.
    @Published var deviceTruth: Bool = UserDefaults.standard.object(forKey: "layers.deviceTruth") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(deviceTruth, forKey: "layers.deviceTruth")
            if deviceTruth != oldValue { log.event("layer", ["name": .string("device_truth"), "on": .bool(deviceTruth)]) }
        }
    }
    /// 12.18 Layers ▸ Robot obstacles (live nav layer A, API §6b.6): what the robots plan around, on the Map and in AR.
    @Published var showNav: Bool = UserDefaults.standard.bool(forKey: "layers.nav") {
        didSet {
            UserDefaults.standard.set(showNav, forKey: "layers.nav")
            if showNav != oldValue { log.event("layer", ["name": .string("nav"), "on": .bool(showNav)]) }
        }
    }
    let meshStore = LiveMeshStore()
    private(set) lazy var planData = MapPlanData(model: self)

    // 10.1 AR 1:1 (Sources/AR): the house map drawn where it really is once LOCALIZED
    // 11.0: Model (the streamed textured tiles) is the default, once for everyone (key ar.house.v11), then the owner's pick.
    @Published var houseStyle: HouseStyle = AppModel.initialHouseStyle() {
        didSet { UserDefaults.standard.set(houseStyle.rawValue, forKey: "ar.house"); layerEdited(houseStyle != oldValue) }
    }
    /// 11.0 Settings ▸ Raw scan: draw the raw scan mesh tiles instead of the structure variant (walls / floors /
    /// ceilings + furniture), which is the default.
    @Published var rawScan: Bool = UserDefaults.standard.bool(forKey: "ar.tiles.raw") {
        didSet { UserDefaults.standard.set(rawScan, forKey: "ar.tiles.raw") }
    }
    /// 12.16 Clean look: the server's `clean` variant (de-lit planes, smoothed furniture; visual only), drawn LIT.
    @Published var cleanLook: Bool = UserDefaults.standard.bool(forKey: "ar.tiles.clean") {
        didSet { UserDefaults.standard.set(cleanLook, forKey: "ar.tiles.clean") }
    }

    // 12.4 View presets + the "3D world" master switch (core: ViewPresets.swift). Individual settings stay as they are;
    // `worldOn` only masks what is drawn / fetched, so switching it back on restores everything.
    @Published var viewPresets = ViewPresetState.decode(UserDefaults.standard.data(forKey: "view.presets")) {
        didSet {
            UserDefaults.standard.set(viewPresets.encoded(), forKey: "view.presets")
            if viewPresets.worldOn != oldValue.worldOn {
                log.event("world_toggle", ["on": .bool(viewPresets.worldOn), "preset": .string(viewPresets.preset.rawValue),
                                           "house": .string(houseStyle.rawValue), "mesh_live": .bool(meshLive)])
                controller.applyRenderSettings()
            }
        }
    }
    private var applyingPreset = false
    var worldOn: Bool { viewPresets.worldOn }
    var worldBinding: Binding<Bool> { Binding(get: { self.viewPresets.worldOn }, set: { self.viewPresets.worldOn = $0 }) }
    var layerSnapshot: LayerSnapshot {
        LayerSnapshot(house: houseStyle.rawValue, meshLive: meshLive, objects: arObjects, terrain: arTerrain,
                      cameras: showCameras, agents: arAgents, doors: arDoors)
    }
    /// What actually draws / streams (settings masked by the master switch).
    var drawHouse: HouseStyle { HouseStyle(rawValue: WorldGate.house(layerSnapshot, worldOn: worldOn)) ?? .off }
    var drawMeshLive: Bool { WorldGate.meshLive(layerSnapshot, worldOn: worldOn) }
    var drawObjects: Bool { WorldGate.objects(layerSnapshot, worldOn: worldOn) }
    var drawDoors: Bool { WorldGate.doors(layerSnapshot, worldOn: worldOn) }
    var drawTerrain: Bool { WorldGate.terrain(layerSnapshot, worldOn: worldOn) }
    var downlinkLayersOn: Bool { WorldGate.downlinkWanted(layerSnapshot, worldOn: worldOn) }

    /// An individual toggle changed (not by a preset): the row becomes Custom.
    func layerEdited(_ changed: Bool) {
        guard changed, !applyingPreset else { return }
        var st = viewPresets
        st.manualChange(current: layerSnapshot)
        if st != viewPresets { viewPresets = st }
    }

    func selectPreset(_ p: ViewPreset) {
        var st = viewPresets
        let snap = st.select(p, current: layerSnapshot)
        if let snap {
            applyingPreset = true
            houseStyle = HouseStyle(rawValue: snap.house) ?? .model
            meshLive = snap.meshLive
            arObjects = snap.objects
            arTerrain = snap.terrain
            showCameras = snap.cameras
            arAgents = snap.agents
            arDoors = snap.doors
            applyingPreset = false
        }
        viewPresets = st
        log.event("layers_preset", ["preset": .string(p.rawValue), "house": .string(houseStyle.rawValue),
                                    "mesh_live": .bool(meshLive), "objects": .bool(arObjects), "terrain": .bool(arTerrain),
                                    "cameras": .bool(showCameras), "agents": .bool(arAgents), "doors": .bool(arDoors), "world": .bool(worldOn)])
    }

    /// Launch: a stored preset whose settings drifted (arTerrain is not persisted) reads as Custom.
    func reconcilePresets() {
        var st = viewPresets
        st.reconcile(current: layerSnapshot)
        if st != viewPresets { viewPresets = st }
    }

    static func initialHouseStyle() -> HouseStyle {
        let d = UserDefaults.standard
        if !d.bool(forKey: "ar.house.v11") {
            d.set(true, forKey: "ar.house.v11")
            d.set(HouseStyle.model.rawValue, forKey: "ar.house")
            return .model
        }
        return HouseStyle(rawValue: d.string(forKey: "ar.house") ?? "") ?? .model
    }
    @Published var arObjects: Bool = UserDefaults.standard.object(forKey: "ar.objects") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arObjects, forKey: "ar.objects"); layerEdited(arObjects != oldValue) }
    }
    /// 12.6 Doors layer: articulated door leaves at their latest angle (AR, Map, Map 3D); part of the 3D world switch.
    @Published var arDoors: Bool = UserDefaults.standard.object(forKey: "ar.doors") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arDoors, forKey: "ar.doors"); layerEdited(arDoors != oldValue) }
    }
    private(set) lazy var doorStore = DoorStore(model: self)
    @Published var arTerrain = false {                      // P3 robot terrain overlay (off at launch: it is busy)
        didSet { layerEdited(arTerrain != oldValue) }
    }
    @Published var arAgents: Bool = UserDefaults.standard.object(forKey: "ar.agents") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arAgents, forKey: "ar.agents"); layerEdited(arAgents != oldValue) }
    }
    @Published var arStatus = ARMapStatus(tone: .neutral, title: "", detail: "", opacity: 0)
    @Published var arObjectEdit: ARObjectEdit?
    /// L3: other agents in the live map (AR + Scans) and the live head's base version.
    @Published var liveAgents: [AgentMark] = []
    @Published var liveBaseVersion: Int?
    /// GET /v1 `features` (feature flags for L3 downlink / S2 shared sim) + the Settings overrides.
    @Published var serverFeatures = ServerFeatures([])
    @Published var forceLiveDownlink = UserDefaults.standard.bool(forKey: "flag.liveDownlink") {
        didSet { UserDefaults.standard.set(forceLiveDownlink, forKey: "flag.liveDownlink") }
    }
    @Published var forceServerSim = UserDefaults.standard.bool(forKey: "flag.serverSim") {
        didSet { UserDefaults.standard.set(forceServerSim, forKey: "flag.serverSim") }
    }
    /// More ▸ Sim ▸ Shared sim: use the map server's sim when it offers one (S2); off = always the local sim.
    @Published var sharedSim: Bool = UserDefaults.standard.object(forKey: "sim.shared") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sharedSim, forKey: "sim.shared") }
    }
    /// 10.8 More ▸ Sim ▸ X-ray: sim bodies hidden behind walls / on another storey draw as a see-through ghost with a
    /// distance / storey badge (per device).
    @Published var simXRay: Bool = UserDefaults.standard.bool(forKey: SimXRay.defaultsKey) {
        didSet { UserDefaults.standard.set(simXRay, forKey: SimXRay.defaultsKey) }
    }

    @Published var tracking: TrackingStatus = .notAvailable
    @Published var mapping = "—"
    @Published var fps: Double = 0
    @Published var meshAnchors = 0
    @Published var thermal = "nominal"
    @Published var cubes = 0
    @Published var measureText: String?
    @Published var toast: String?
    @Published var error: String?
    @Published var logURL: URL?

    // P1: server, logs, recording, uploads
    @Published var serverBase: String?
    @Published var serverLabel = "offline"
    @Published var sendingLog = false
    @Published var lastLogResult: String?
    @Published var recording = false {
        didSet { if recording != oldValue { lastRecordToggleAt = Date().timeIntervalSince1970 } }
    }
    /// 12.23 Live map tap guard (SnailSightCore LiveTapGuard): when Record last started / stopped, and a pending
    /// "tap again to stop Live map".
    var lastRecordToggleAt: Double?
    var liveOffConfirmAt: Double?
    private var liveCause: String?

    /// The ONLY way to change Live map (12.23): `cause` is logged with the change ("owner_tap", ...).
    func setLive(_ on: Bool, cause: String) {
        guard on != liveOn else { return }
        liveCause = cause
        liveOn = on
    }
    @Published var recStats = RecordStats()
    @Published var recWarning: String?                 // adaptive-recording notice (hot / low memory), 9.1.61
    @Published var recNote: String?                    // 9.6 neutral notice (mesh memory cap reached)
    @Published var recRateHz: Double = AdaptiveCapture.baseRateHz   // 9.6 HUD "REC n fps" (capture rate, not AR fps)
    @Published var meshMode: MeshMode = .live          // 9.6 live / slow updates / frozen (kept on screen, dimmed)
    @Published var showScans = false {                 // 9.6 Scans screen (Sources/Scans); closing resumes AR
        didSet { if oldValue && !showScans { scansClosed() } }
    }
    var memoryWarnings = 0                             // memory warnings during the current recording
    /// 12.20: what may be held / done at the current memory level + thermal state (ARSessionController's governor).
    var memPlan = MemPlan.plan(level: .normal, thermal: .nominal)
    /// 12.21 AR look: Camera + device surface (12.18) or Live map view (the server's live world drawn solid). One tap on
    /// the right rail, remembered.
    @Published var arLook: ARLook = ARLook(rawValue: UserDefaults.standard.string(forKey: "view.arLook") ?? "") ?? .device {
        didSet {
            guard arLook != oldValue else { return }
            UserDefaults.standard.set(arLook.rawValue, forKey: "view.arLook")
            log.event("ar_look", ["look": .string(arLook.rawValue), "from": .string(oldValue.rawValue)])
            controller.mapLayer.lookChanged()
        }
    }
    /// The live map is the visible overlay now (and the 3D world is shown).
    var liveMapView: Bool { arLook == .live && worldOn }
    private var warmGate = WarmDebounce(minS: 60)

    /// 12.21 warm on open (API §5.6e): the server pages its localizer engines in, in the background, so the first
    /// localize of a walk is fast. Fire-and-forget, ≤ once per 60 s; log loc_warm with the answer.
    func warmLocalizer(reason: String) {
        guard let link else { return }
        let now = Date().timeIntervalSince1970
        guard warmGate.shouldFire(now: now) else { return }
        let t0 = Date()
        Task { [weak self] in
            var ev: [String: LogValue] = ["reason": .string(reason)]
            do {
                let (d, st) = try await link.request("POST", "/v1/localizer/warm", body: Data("{}".utf8), timeout: 10)
                ev["status"] = .int(st)
                if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    for (k, v) in o.prefix(12) {
                        if let n = v as? NSNumber {
                            let isBool = CFGetTypeID(n) == CFBooleanGetTypeID()
                            let lv: LogValue = isBool ? LogValue.bool(n.boolValue) : LogValue.double(n.doubleValue)
                            ev[k] = lv
                        }
                        else if let s = v as? String { ev[k] = .string(String(s.prefix(120))) }
                    }
                } else {
                    ev["body"] = .string(String(decoding: d.prefix(200), as: UTF8.self))
                }
            } catch {
                ev["error"] = .string(error.localizedDescription)
            }
            ev["ms"] = .int(Int(Date().timeIntervalSince(t0) * 1000))
            let failed = ev["error"] != nil
            await MainActor.run {
                guard let self else { return }
                if failed { self.warmGate.failed() }
                self.log.event("loc_warm", ev)
            }
        }
    }
    @Published var uploads: [UploadItem] = [] { didSet { uploadsChanged(from: oldValue) } }
    @Published var uploadRate: Double?
    @Published var hiddenUploadPanel: String?          // capture id whose finished panel the user dismissed

    let services = AppServices.shared
    var log: DebugLog { services.log }
    let agentID = Identity.agentID
    let recorder = CaptureRecorder()
    let objectScan = ObjectScanState()                  // 9.3 object scan (Sources/ObjectScan, API §9)
    private(set) lazy var controller = ARSessionController(model: self)
    private(set) lazy var placeCtl = PlaceController(model: self)
    private(set) lazy var mapLocalizer = MapLocalizer(model: self)
    private(set) lazy var liveStreamer = LiveStreamer(model: self)
    /// 12.26 one-tap walk (Sources/Live/WalkController): AR + localize + Live map + status line + summary.
    private(set) lazy var walker = WalkController(model: self)
    private(set) lazy var meshMapper = MeshMapper(model: self)
    private(set) lazy var roomScanner = RoomScanner(model: self)
    private(set) lazy var terrainLayer = TerrainARLayer(model: self)
    private(set) lazy var liveMap = LiveMapClient(model: self)
    /// 12.18 Layer A: the robots' obstacle view (Layers ▸ Robot obstacles).
    private(set) lazy var navStore = NavLayerClient(model: self)
    /// 12.18 Layer B: live block-mesh deltas (server Layer B wire, API §6b).
    private(set) lazy var blocks = LayerBClient(model: self)
    /// 12.22 GPS / compass / barometer as weak priors in every live keyframe (API §6b.13 `geo`).
    private(set) lazy var geo = GeoSensor(model: self)
    /// 12.22 islands: new areas mapped in their own frames, joined later (API §6b.13).
    private(set) lazy var islands = IslandsClient(model: self)
    /// 12.18 Map ▸ 3D tile loader while the viewer is open (Layer B cube changes re-mask its base tiles).
    weak var map3DTiles: Map3DTileLoader?
    /// 12.18 M0: server stage timestamps (uplink acks) + this phone's receive / draw of its own keyframes.
    var liveStages = LiveStages()
    /// Short + detail lines under the live line (nil = hidden).
    @Published var liveStagesText: String?
    @Published var liveStagesDetail: String?
    @Published var liveStagesOpen = false

    func liveStagesChanged() {
        let s = liveStages.short, d = liveStages.detail
        if liveStagesText != s { liveStagesText = s }
        if liveStagesDetail != d { liveStagesDetail = d }
    }

    func map3DBlocksChanged(squares: [[Double]]) {
        guard let t = map3DTiles else { return }
        MainActor.assumeIsolated { t.blocksChanged(squares: squares) }
    }
    private(set) lazy var serverSim = ServerSimClient(model: self)
    /// 12.7 drive mode: twin sticks, turret, gamepad, FPV (Sources/Drive).
    private(set) lazy var drive = DriveController(model: self)
    /// 12.2 Mark camera (point-at triangulation) + Camera check (walk FOV tracking): Sources/CameraMark.
    private(set) lazy var cameraMark = CameraMarkController(model: self)
    private(set) lazy var cameraCheck = CameraCheck(model: self)
    /// 10.7 the main AR view follows the house map's newest READY version (Sources/AR/MapFollower, plan M1).
    private(set) lazy var mapFollower = MapFollower(model: self)
    private var scanStoreShared: ScanStore?

    /// ONE Scans catalogue + offline cache for the Scans screen and the 10.7 background prefetch (one index.json writer).
    @MainActor func sharedScanStore() -> ScanStore {
        if let s = scanStoreShared { return s }
        let s = ScanStore(link: services.link, log: services.log)
        scanStoreShared = s
        return s
    }
    var link: ServerLink! { services.link }
    var logs: LogUploader! { services.logs }
    var queue: UploadQueue! { services.queue }
    private var toastWork: DispatchWorkItem?
    private var undoWork: DispatchWorkItem?
    private var timer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var packTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    var version: String { services.version }

    var pendingUploads: Int { uploads.filter { !$0.serverHasAll }.count }

    /// The capture the main-screen upload panel is about: the oldest one still uploading, else the newest one
    /// being processed / just processed (until dismissed).
    var panelItem: UploadItem? {
        if let u = uploads.first(where: { !$0.serverHasAll && !$0.finished }) { return u }
        guard let last = uploads.last, last.id != hiddenUploadPanel, last.sessionID != nil,
              Date().timeIntervalSince1970 - last.created < 6 * 3600 else { return nil }
        return last
    }

    /// "Uploading 42 % · 110/253 MB · ~3 min" (main screen).
    func uploadLine(_ it: UploadItem) -> String {
        if it.serverHasAll {
            switch it.state {
            case "processed": return it.report.map { "Processed ✓ \($0)" } ?? "Processed on the map server ✓"
            case "failed": return "Processing failed on the map server"
            default: return "Uploaded ✓ · processing on the map server…"
            }
        }
        if it.parts.isEmpty { return "Preparing upload…" }
        let packed = it.parts.filter { $0.packaged || $0.done }.count
        if serverBase == nil && it.sentBytes == 0 {
            if CopState.isCopLabel(serverLabel) {       // 10.9: the owner switched the COP off; this upload waits
                return "Queued: \(serverLabel) · uploads when it is back · \(packed)/\(it.parts.count) parts ready"
            }
            return "Waiting for the map server (offline) · \(packed)/\(it.parts.count) parts ready"
        }
        return UploadText.progressLine(sent: it.sentBytes, total: it.bytesTotal, bytesPerSecond: uploadRate)
    }

    func uploadHint(_ it: UploadItem) -> String {
        if it.serverHasAll { return it.state == "processed" ? "Tap × to hide" : "You can close the app; the result shows here" }
        if it.backgroundSafe { return "Safe to leave the app ✓ the upload continues in the background" }
        if it.sessionID == nil { return "Keep SnailSight open until this says safe to leave" }
        let packed = it.parts.filter { $0.packaged || $0.done }.count
        return "Packing \(packed)/\(it.parts.count) · keep SnailSight open a moment"
    }

    /// HUD text: "srv tailnet ✓" / "srv offline · 2 queued" / "srv lan ✓ · ↑ 40 %".
    var serverText: String {
        var s = serverBase == nil ? (CopState.isCopLabel(serverLabel) ? serverLabel : "srv offline") : "srv \(serverLabel) ✓"
        if let up = uploads.first(where: { !$0.serverHasAll }), serverBase != nil, up.bytesTotal > 0 {
            s += String(format: " · ↑ %.0f %%", up.progress * 100)
        }
        if pendingUploads > 0 { s += " · \(pendingUploads) queued" }
        return s
    }

    init() {
        logURL = log.fileURL
        reconcilePresets()
        services.onLink = { [weak self] base, label in
            self?.serverBase = base
            self?.serverLabel = label
            if base != nil { self?.placeCtl.online(); self?.refreshFeatures(); self?.meshMapper.pump(); self?.roomScanner.pump() }   // places / mapping saved offline go up now
        }
        services.onUploads = { [weak self] items, rate in
            self?.uploads = items
            self?.uploadRate = rate
        }
        recorder.onStats = { [weak self] s in self?.recStats = s }
        let lg = services.log
        recorder.onEvent = { ev, data in lg.event(ev, data) }
        UIApplication.shared.isIdleTimerDisabled = true
        // 12.18 Layer A poller (idle unless shown): started with AR (12.25; it touches the AR layer)
    }

    /// Screen stays awake while AR runs and while a capture uploads in front (set at launch and re-asserted here,
    /// in case anything ever turns it off).
    private func uploadsChanged(from old: [UploadItem]) {
        if uploads.contains(where: { !$0.serverHasAll }) { UIApplication.shared.isIdleTimerDisabled = true }
        for it in uploads {
            let was = old.first(where: { $0.id == it.id })
            if it.state == "processed", was?.state != "processed", was != nil {
                flash("\(it.id) processed ✓ \(it.report ?? "")", seconds: 8)
            } else if it.serverHasAll, was.map({ !$0.serverHasAll }) == true {
                flash("Upload complete ✓ the map server is processing it", seconds: 4)
            }
        }
    }

    /// Called once the UI is up: probe the server, start the periodic sync, hook app lifecycle.
    func startNetworking() {
        guard timer == nil else { return }
        let q = queue!, lg = logs!
        Task { await link.whenOnline { Task { try? await lg.syncAll(); await q.kick(reason: "online") } } }
        Task { await link.startMonitoring() }
        Task { [weak self] in
            guard let self else { return }
            await q.start()
            let items = await q.current()
            await MainActor.run { self.uploads = items }
            await self.link.probe(force: true)
            await MainActor.run { if self.arStarted { self.warmLocalizer(reason: "launch") } }   // 12.21 warm on open (AR only, 12.25)
            await q.kick(reason: "launch")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.periodicSync() }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.backgroundFlush()
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log.event("foreground", ["mode": .string(self.appMode?.rawValue ?? "chooser")])
            let q = self.queue!
            let ar = self.arActive                          // 12.25: the AR loops only while AR explore is up
            if ar {
                // 10.6.x: every server loop resumes at once (owner: one timeout + background and it never placed him)
                self.mapLocalizer.resume(why: "foreground")
                self.mapFollower.resume(why: "foreground")
                self.liveMap.resume(why: "foreground")
                self.serverSim.resume(why: "foreground")
                self.placeCtl.publish()
            } else if self.appMode == .cop {
                self.cop.foreground()
            }
            Task {
                await self.link.probe(force: true)
                await MainActor.run {                       // the server answered again (or still not): resume again
                    guard self.arActive else { return }
                    self.warmLocalizer(reason: "foreground")                 // 12.21
                    if self.serverBase != nil { self.mapLocalizer.resume(why: "network") }
                }
                await q.kick(reason: "foreground")
            }
        })
    }

    /// GET /v1 `features`: which planned server parts exist (L3 downlink, S2 shared sim) — the feature flags.
    func refreshFeatures() {
        let lk = link!
        Task { [weak self] in
            guard let r = try? await lk.request("GET", "/v1", timeout: 8), r.1 == 200 else { return }
            let f = ServerFeatures.parse(r.0)
            await MainActor.run {
                guard let self, self.serverFeatures != f else { return }
                self.serverFeatures = f
                self.log.event("features", ["list": .string(f.list.sorted().joined(separator: ","))])
            }
        }
    }

    func periodicSync() {
        let q = queue!, lg = logs!
        if appMode == .ar { cop.arMemory(level: memPlan.level) }      // 12.25: an unused hidden snailCOP view goes after 10 min
        Task {
            try? await lg.syncAll()
            await q.kick()
        }
    }

    private func backgroundFlush() {
        log.event("background", ["mode": .string(appMode?.rawValue ?? "chooser")])
        if arStarted {
            mapLocalizer.enteredBackground()
            mapFollower.enteredBackground()
        }
        // ARKit stops in the background and iOS may end a suspended app: finish the capture cleanly now
        if recorder.isRecording { stopRecording(reason: "background") }
        if arStarted {
            roomScanner.appBackground()                 // 11.3: RoomPlan stops with ARKit; the room is built + spooled
            meshMapper.appBackground()                  // 10.2: ARKit stops; the mapping upload finishes
        }
        guard bgTask == .invalid else { return }
        // short work only (log sync, packing any unpacked parts, handing them to the background session);
        // the capture bytes themselves travel on the background URLSession, which needs no background task
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "snailsight.upload") { [weak self] in
            self?.log.event("bg_task_expired", ["what": .string("background flush")])
            self?.endBackground()
        }
        let q = queue!, lg = logs!
        Task { [weak self] in
            await q.kick(reason: "background")
            try? await lg.syncAll()
            await MainActor.run { self?.endBackground() }
        }
    }

    private func endPackTask() {
        guard packTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(packTask)
        packTask = .invalid
    }

    private func endBackground() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: 12.25 modes

    /// AR explore is on screen and its session runs.
    var arActive: Bool { appMode == .ar && arStarted && !arPausedForCop }

    /// Once the UI is up: the launch decision (deep link > remembered > chooser).
    func launch() {
        guard !launchDone else { return }
        launchDone = true
        let d = LaunchMode.decide(remembered: UserDefaults.standard.string(forKey: LaunchMode.rememberedKey),
                                  askEveryLaunch: askModeAtLaunch, deepLink: pendingLink)
        log.event("app_launch_mode", ["mode": .string(d.mode?.rawValue ?? "chooser"), "reason": .string(d.reason)])
        if let m = d.mode {
            let link = pendingLink
            pendingLink = nil
            setMode(m, cause: "launch_\(d.reason)")
            if let link { apply(link) }
        }
    }

    /// The ONE way to switch modes (logged `app_mode` with its cause). AR starts on demand; snailCOP pauses it.
    func setMode(_ m: AppMode, cause: String) {
        if m == .cop, appMode == .ar, !ModeRules.canLeaveAR(recording: recording) {
            flash("Stop recording first: snailCOP turns the camera off", seconds: 3)
            log.event("app_mode_refused", ["to": .string(m.rawValue), "why": .string("recording")])
            return
        }
        let from = appMode
        UserDefaults.standard.set(m.rawValue, forKey: LaunchMode.rememberedKey)
        guard m != from else { return }
        var ev: [String: LogValue] = ["mode": .string(m.rawValue), "from": .string(from?.rawValue ?? "chooser"),
                                      "cause": .string(cause), "ar_started": .bool(arStarted)]
        for (k, v) in MemoryProbe.fields() where k == "footprint_mb" { ev[k] = v }
        log.event("app_mode", ev)
        switch m {
        case .cop:
            leaveAR()
            appMode = .cop
            UIApplication.shared.isIdleTimerDisabled = pendingUploads > 0      // no camera: the screen may dim
            cop.show(why: cause)
        case .ar:
            if from == .cop { cop.hide(why: "mode_ar") }
            appMode = .ar
            UIApplication.shared.isIdleTimerDisabled = true
            startOrResumeAR(cause: cause)
        }
    }

    /// Leaving AR for snailCOP: Live map off, full-screen AR tools closed, the session paused (camera off).
    private func leaveAR() {
        guard arStarted, !arPausedForCop else { return }
        if liveOn { setLive(false, cause: "mode_cop") }
        if meshMapOn { meshMapOn = false }
        if roomScanOn { roomScanner.stop(reason: "mode_cop") }
        if drive.ui.active { drive.exit(why: "mode_cop") }
        showMap = false
        showMap3D = false
        showScans = false
        showDriveViewer = false
        showSettings = false
        arPausedForCop = true
        controller.suspendForMap3D(why: "cop")
    }

    private func startOrResumeAR(cause: String) {
        if !arStarted {
            arStarted = true
            controller.start()
            let slog = services.log
            SimContentStore.shared.inUse = { [weak self] in
                guard let self else { return ([], []) }
                return (self.serverSim.activeKinds.union(self.controller.sim.activeKinds), self.simRecents.keys)
            }
            SimContentStore.shared.attach(link: link, log: { e, d in slog.event(e, d) })   // 12.8 runtime sim content, 12.9 all models
            mapFollower.start()                             // 10.7: cached head now, the server's head in the background
            navStore.start()                                // 12.18 Layer A poller (idle unless shown)
            warmLocalizer(reason: cause.hasPrefix("launch") ? "launch" : "mode_ar")     // 12.21 warm on open
            return
        }
        guard arPausedForCop else { return }
        arPausedForCop = false
        controller.resumeAfterMap3D(why: "cop")
        mapLocalizer.resume(why: "mode_ar")
        mapFollower.resume(why: "mode_ar")
        liveMap.resume(why: "mode_ar")
        serverSim.resume(why: "mode_ar")
        warmLocalizer(reason: "mode_ar")
    }

    /// The AR governor's level (ARSessionController): a hidden snailCOP web view goes when memory is tight.
    func arMemLevel(_ l: MemLevel) { if appMode == .ar { cop.arMemory(level: l) } }

    // MARK: 12.25 deep links + Open AR here

    func openDeepLink(_ url: URL) {
        guard let d = AppDeepLink.parse(url.absoluteString) else {
            log.event("deep_link", ["ok": .bool(false), "scheme": .string(url.scheme ?? "")])
            return
        }
        log.event("deep_link", ["ok": .bool(true), "mode": .string(d.mode.rawValue), "at": .bool(d.view != nil),
                                "target": .bool(d.target != nil)])
        guard launchDone else { pendingLink = d; return }
        setMode(d.mode, cause: "deep_link")
        apply(d)
    }

    private func apply(_ d: AppDeepLink) {
        if d.walk { walker.start(cause: "deep_link") }                  // 12.26 snailsight://walk
        if let v = d.view { cop.goTo(v) }
        if let t = d.target { openARHere(target: t, label: d.label ?? "Target") }
    }

    /// snailCOP's "Open AR here" (or a deep link): AR explore with a guide to the spot until you get there.
    func openARHere(target: [Double], label: String) {
        arTarget = ARHandoffTarget(target: target, label: label, since: Date().timeIntervalSince1970)
        arTargetText = arTarget.map { "\($0.label): finding you first…" }
        log.event("ar_target", ["source": .string("cop"), "label_len": .int(label.count)])
        if appMode != .ar { setMode(.ar, cause: "open_ar_here") }
    }

    func clearARTarget(why: String) {
        guard arTarget != nil else { return }
        log.event("ar_target_clear", ["why": .string(why)])
        arTarget = nil
        arTargetText = nil
    }

    /// MapARLayer (2 Hz, while aligned): the camera in the map frame → snailCOP's "you are here" + the target guide.
    func notePose(cam: [Double], ahead: [Double]) {
        let now = Date().timeIntervalSince1970
        lastMapPose = (cam, ahead, now)
        guard let t = arTarget else { return }
        if now - t.since > ARHandoffTarget.maxAgeS { clearARTarget(why: "age"); return }
        let g = t.guide(camera: cam, forward: [ahead[0] - cam[0], ahead[1] - cam[1], ahead[2] - cam[2]])
        if arTargetText != g.text { arTargetText = g.text }
        if g.arrived, !arTargetArrived { arTargetArrived = true; log.event("ar_target_arrived", ["m": .double((g.distanceM * 100).rounded() / 100)]) }
        if !g.arrived { arTargetArrived = false }
    }
    private var arTargetArrived = false

    /// The pose snailCOP shows: live while AR explore is localized, else the last one with its age (nil = never localized).
    func copPose(now: Double) -> PhonePose? {
        guard let p = lastMapPose else { return nil }
        let live = arActive && now - p.t < 3
        return PhonePose.from(camera: p.cam, ahead: p.ahead, at: p.t, now: now, live: live)
    }

    /// "Send log": upload now and confirm with the path on the map server.
    /// 12.26: upload the session log quietly (a walk's end: the scorer reads it on the server).
    func syncLogs() {
        let lg = logs!
        Task { try? await lg.syncAll() }
    }

    func sendLog() {
        guard !sendingLog else { return }
        sendingLog = true
        log.event("send_log", ["server": .string(serverBase ?? "none")])
        let focus = log.fileURL?.lastPathComponent
        let lg = logs!, lk = link!
        Task { [weak self] in
            let text: String
            do {
                await lk.probe()
                var r = try await lg.syncAll(focus: focus)
                var tries = 0
                while r.path == nil && tries < 5 {      // a background sync was mid-flight; let it finish
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    r = try await lg.syncAll(focus: focus)
                    tries += 1
                }
                text = r.path.map { "Log saved on the map server ✓\n\($0)" } ?? "Log sent ✓ (\(r.files) file(s))"
            } catch {
                text = "Log not sent: \(error.localizedDescription). It stays queued and uploads automatically."
            }
            await MainActor.run {
                self?.sendingLog = false
                self?.lastLogResult = text
                self?.flash(text, seconds: 4)
            }
        }
    }

    // MARK: recording

    func toggleRecording() {
        if recorder.isRecording { stopRecording(reason: "user") } else { startRecording() }
    }

    /// Stop + save + queue the upload. `reason`: user | thermal_critical | memory_low | background (record_stop log,
    /// capture.json stop_reason).
    func stopRecording(reason: String) {
        guard recorder.isRecording else { return }
        let isObjectScan = ObjectNaming.mode(of: CaptureRecorder.activeCaptureID ?? "") == .lidar
        recorder.stop(reason: reason) { [weak self] summary in
            guard let self else { return }
            self.recording = false
            self.recorder.keyframeProfileScale = 1
            if isObjectScan { self.lidarObjectRecordingStopped() }
            self.recWarning = nil
            self.controller.setDepthCapture(false)
            self.controller.sim.recordingChanged(false)
            self.mapLocalizer.recordingStopped()            // 10.2: a lock found while recording places the bodies now
            guard let s = summary else { return }
            var ev: [String: LogValue] = ["id": .string(s.clientSessionID), "frames": .int(s.frames),
                                          "mb": .double(Double(s.bytes) / 1_048_576), "dropped": .int(s.dropped)]
            for (k, v) in s.stats { ev[k] = v }
            for (k, v) in MemoryProbe.fields() { ev[k] = v }
            self.log.event("record_stop", ev)
            switch reason {
            case "thermal_critical": self.flash("Phone too hot: recording stopped and saved (\(s.frames) frames) · uploading", seconds: 8)
            case "memory_low": self.flash("Memory almost full: recording stopped and saved (\(s.frames) frames) · uploading", seconds: 8)
            default: self.flash(isObjectScan ? "Object scan saved (\(s.frames) frames) · uploading to the map server"
                                           : "Saved \(s.frames) frames · uploading to the map server")
            }
            // Stop → plan + pack + hand parts to the background session at once. A background task covers this
            // short phase in case the app is left right after Stop (owner run 2026-10-12: backgrounded 8 s later).
            if self.packTask == .invalid {
                self.packTask = UIApplication.shared.beginBackgroundTask(withName: "snailsight.pack") { [weak self] in
                    self?.log.event("bg_task_expired", ["what": .string("pack after stop")])
                    self?.endPackTask()
                }
            }
            let q = self.queue!
            Task { [weak self] in
                await q.enqueue(s)
                await q.kick(reason: "stop")
                await MainActor.run { self?.endPackTask() }
            }
        }
    }

    /// `object` = a 9.3 LiDAR object scan (objl-… id, object profile keyframes, object_box in capture.json → /v1/objects).
    func startRecording(object: ObjectRecordingSpec? = nil) {
        let id = object?.id ?? CaptureNaming.clientSessionID(start: Date())
        controller.sim.recordingChanged(true)               // sim pauses first: the capture owns the thermal budget
        controller.setDepthCapture(true)
        var meta: [String: Any] = ["agent_id": agentID, "agent_type": Identity.agentType, "app_version": version,
                                   "device": DebugLog.deviceModel]
        for (k, v) in object?.meta ?? [:] { meta[k] = v }
        recorder.keyframeProfileScale = object == nil ? 1 : ObjectProfile.keyframeScale
        do {
            _ = try recorder.start(clientSessionID: id, meta: meta)
            recStats = RecordStats()
            recording = true
            recWarning = nil
            recNote = nil
            recRateHz = AdaptiveCapture.baseRateHz
            memoryWarnings = 0
            var ev = MemoryProbe.fields()
            ev["id"] = .string(id)
            ev["thermal"] = .string(thermal)
            if object != nil { ev["object"] = .bool(true) }
            log.event("record_start", ev)
            flash(object == nil ? "Recording: walk slowly, cover walls at three heights"
                                : "Object scan: walk slowly round it, low pass then high pass")
        } catch {
            controller.setDepthCapture(false)
            controller.sim.recordingChanged(false)
            flash("Could not record: \(error.localizedDescription)")
        }
    }

    // MARK: Scans screen (9.6)

    /// Open the native scan browser/viewer: the main AR session pauses (one AR session at a time; the dollhouse runs
    /// its own). Not while recording (the button is hidden then).
    func openScans() {
        guard !recording else { return }
        controller.suspendForScans()
        showScans = true
    }

    /// 12.3 Map ▸ 3D.
    func openMap3D() {
        guard !recording, !showScans, !showMap3D else { return }
        controller.suspendForMap3D()
        showMap3D = true
    }

    func map3DClosed() {
        controller.resumeAfterMap3D()
        mapLocalizer.resume(why: "map3d_closed")
        mapFollower.resume(why: "map3d_closed")
        liveMap.resume(why: "map3d_closed")
    }

    func scansClosed() {
        controller.resumeAfterScans()
        mapLocalizer.resume(why: "scans_closed")
        mapFollower.resume(why: "scans_closed")
        liveMap.resume(why: "scans_closed")
    }

    /// 9.9: "Deleted … [Undo]" for 5 s (the deletion itself is kept in ARSessionController's UndoBuffer).
    /// 12.5: what the Undo button runs (nil = undo the last deletion, the 9.9 behaviour).
    private(set) var undoAction: (() -> Void)?
    private(set) var undoIcon = "trash"

    func showUndo(_ text: String, seconds: Double = 5, icon: String = "trash", action: (() -> Void)? = nil) {
        undoAction = action
        undoIcon = icon
        undoText = text
        undoWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.undoText = nil }
        undoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func hideUndo() {
        undoWork?.cancel()
        undoText = nil
        undoAction = nil
    }

    func runUndo() {
        if let a = undoAction { hideUndo(); a() } else { controller.undoDeletion() }
    }

    /// 12.5 selection-scoped overlays (owner on 12.4: the robot's path overlay stayed when the chicken was selected).
    private(set) var overlays = SelectionOverlays()

    /// Any selection change (server "server.<id>", local "local.<id>", nil = none): clear what the previous one drew.
    func selectionChanged(_ id: String?) {
        let gone = overlays.select(id)
        driveHidden = true                                   // 12.7: Drive opens drive mode (the twin sticks)
        guard !gone.isEmpty else { return }
        if gone.contains(.robotPathResult) { terrainLayer.clearPath() }
        if gone.contains(.goalMarkers) || gone.contains(.pathPreview) {
            serverSim.clearSelectionOverlays()
            controller.sim.clearSelectionMarkers()
        }
        log.event("selection_overlays", ["to": .string(id ?? ""), "cleared": .string(gone.map(\.rawValue).sorted().joined(separator: ","))])
    }

    /// An overlay was drawn for whatever is selected right now.
    func overlayDrawn(_ o: SelectionOverlay) { overlays.drew(o, for: overlays.selected) }

    /// Drive (ring / bar / gamepad L3) on a drivable body: 12.7 full-screen drive mode (Sources/Drive).
    func openDrive() {
        guard !recording else { return }
        log.event("drive_open", ["tank": .bool(driveTank)])
        drive.enter()
    }

    /// 12.7 FPV / Chase: snapshot the AR view (the last-frame PiP), pause AR, show the 3D drive view.
    func beginDriveViewer(pip: @escaping (UIImage?) -> Void) {
        guard !showDriveViewer, !showScans, !showMap3D else { return }
        controller.arView.snapshot(saveToHDR: false) { [weak self] img in
            pip(img.flatMap { AppModel.thumbnail($0, width: 168) })
            guard let self, self.drive.active, self.drive.view.pausesAR, !self.showDriveViewer else { return }
            self.controller.suspendForMap3D(why: "drive_fpv")
            var tr = Transaction()
            tr.disablesAnimations = true                       // straight into the 3D view, no sheet slide
            withTransaction(tr) { self.showDriveViewer = true }
        }
    }

    func endDriveViewer() {
        guard showDriveViewer else { return }
        var tr = Transaction()
        tr.disablesAnimations = true
        withTransaction(tr) { showDriveViewer = false }
        controller.resumeAfterMap3D(why: "drive_fpv")
        mapLocalizer.resume(why: "drive_fpv_closed")
        mapFollower.resume(why: "drive_fpv_closed")
        liveMap.resume(why: "drive_fpv_closed")
    }

    static func thumbnail(_ img: UIImage, width: CGFloat) -> UIImage {
        let h = img.size.width > 0 ? img.size.height * width / img.size.width : width
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: h)).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: width, height: h))
        }
    }

    func flash(_ text: String, seconds: Double = 2.5) {
        toast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}


/// 9.9 the placed cube that is selected (tap a cube): its floating bar shows ✕.
struct CubeSelection: Equatable {
    let id: UUID
    let number: Int
}
