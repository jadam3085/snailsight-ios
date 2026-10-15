import ARKit
import RealityKit
import UIKit
import SnailSightCore

/// Owns the AR session: configuration, delegate callbacks, tracking/fps HUD values, taps.
/// Configuration follows Apple's reconstructed-scene sample (scene mesh + occlusion, manual session config),
/// with `.gravity` world alignment (never the compass; plan §2) and people occlusion added.
/// 9.1.61 (2026-10-12 kill during an 8-min whole-house recording, footprint ~3 GB, Recon3D the busiest thread):
///  - while recording the configuration drops what the capture does not need (environment texturing, people
///    segmentation); scene reconstruction is stopped (and its memory released with .resetSceneReconstruction) as soon as
///    AdaptiveCapture says the mesh freezes (9.6: memory low / a memory warning / thermal serious / mesh vertex cap — no
///    longer at thermal fair) and stays off until Stop. The wireframe already drawn stays on screen, dimmed ("frozen").
///  - every HUD tick while recording: AdaptiveCapture.decide(thermal, os_proc_available_memory) → recorder rate/quality,
///    mesh shed, on-screen warning, clean auto-stop (thermal critical / memory nearly exhausted).
///  - ev "mem" every 10 s and on every thermal change / memory warning (footprint, available, limit).
final class ARSessionController: NSObject, ARSessionDelegate {
    let arView: ARView
    unowned let model: AppModel
    private let renderer: SceneRenderer
    private let meshOverlay = MeshOverlay()
    private var fpsMeter = FPSMeter(window: 1.0)
    private var lastHUD: TimeInterval = 0
    private var lastFPSLog: TimeInterval = 0
    private var lastMapping: ARFrame.WorldMappingStatus?
    private var started = false
    private var thermalObserver: NSObjectProtocol?
    private var shiftLogged: [UUID: TimeInterval] = [:]
    private var depthCapture = false            // .sceneDepth only while recording (P0 config otherwise unchanged)
    private(set) var meshShed = false           // mesh frozen: scene reconstruction off for the rest of this recording
    private var lastMemLog: TimeInterval = 0
    private var lastRecBytes: (Int, Double)?
    private var lastLevel = "normal"
    private var memoryObserver: NSObjectProtocol?
    private var lastCamLog: TimeInterval = 0
    private var camLoggedThisRecording = false
    /// 9.8 heat budget (SnailSightCore SimBudgets): what the AR view + sim may cost at the current iOS thermal state and
    /// the Settings ▸ Sim quality mode. Lighter shadows and slower mesh rebuilds first; the sim only pauses at CRITICAL.
    private(set) var heatBudget = SimBudgets.budget(mode: .auto, thermal: .nominal)
    private var thermalHistory: ThermalHistory?
    /// S1 simulated agents (Sources/Sim). Created on first use.
    private(set) lazy var sim: SimController = {
        let s = SimController(model: self.model, arView: self.arView)
        s.cubeSource = { [weak self] in self?.renderer.supportBodies() ?? [] }     // 9.5: cubes re-check support
        s.onEntitiesChanged = { [weak self] in self?.model.placeCtl.entitiesChanged() }   // P2a auto-save
        s.onObjectsDeleted = { [weak self] snaps, label in self?.recordDeletion(snaps.map { Deleted.object($0) }, label: label) }
        return s
    }()
    /// 9.9 easy cube delete: the last deletion (placed cubes and / or sim objects), undoable for 5 s.
    enum Deleted {
        case cube(SceneRenderer.CubeSnapshot)
        case object(SimController.ObjectSnapshot)
    }
    private var undo = UndoBuffer<Deleted>(window: 5)
    private var collecting: [Deleted]?
    /// 9.3 Quick LiDAR object scan: the AR box (Sources/ObjectScan). Created on first use.
    private(set) lazy var objectBox = ObjectBoxController(model: model, arView: arView)
    /// 10.1 AR 1:1: the house map's content in the map frame (Sources/AR/MapARLayer). Created on the first frame.
    private(set) lazy var mapLayer = MapARLayer(model: model, arView: arView)

    init(model: AppModel) {
        self.model = model
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        renderer = SceneRenderer(arView: arView)
        super.init()
        arView.session.delegate = self
        arView.scene.addAnchor(meshOverlay.root)
        setupCoachingOverlay(on: arView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))  // 9.9 delete
        long.minimumPressDuration = 0.5
        tap.require(toFail: long)
        arView.addGestureRecognizer(tap)
        arView.addGestureRecognizer(long)
        renderer.onPlaced = { [weak self] in self?.model.cubes = $0 }
        let lg = model.log
        CameraTuner.shared.log = { ev, data in lg.event(ev, data) }        // 9.4 camera settings (CameraTuner.swift)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateThermal(log: true)
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.memoryWarning()
        }
    }

    // MARK: configuration

    static var supportsMesh: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }
    static var supportsPeople: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) }
    static var supportsDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    /// `worldMap` (P2a): a saved place's ARWorldMap to relocalize into. Only for the run that loads it — a later re-run
    /// without reset options (people occlusion, recording depth) must not restart relocalization.
    func makeConfiguration(worldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity                 // y up; heading = phone's start heading (no compass)
        c.initialWorldMap = worldMap
        if Self.supportsMesh && !meshShed { c.sceneReconstruction = .mesh }      // no classification (cost)
        // recording: the capture needs only depth + poses; people segmentation and environment probes cost Neural Engine,
        // GPU, heat and (probes) memory that grows with the area walked
        // P2b: LiDAR depth also while localizing against the house map (MapLocalizer, the first minute or so)
        let wantDepth = depthCapture || model.mapLocalizer.wantsDepth || model.liveStreamer.wantsDepth   // 10.0 Live map
            || model.meshMapper.wantsDepth                                                               // 10.2 Map mesh
        if model.peopleOcclusion && Self.supportsPeople && !wantDepth { c.frameSemantics.insert(.personSegmentationWithDepth) }
        if wantDepth && Self.supportsDepth { c.frameSemantics.insert(.sceneDepth) }
        c.environmentTexturing = depthCapture ? .none : .automatic
        return c
    }

    func start() {
        guard !started else { return }
        started = true
        applyRenderSettings()
        // 10.3: always a clean session; the house map localizes it (a saved place only on evidence, PlaceController)
        model.placeCtl.launch { [weak self] map in
            guard let self else { return }
            self.arView.session.run(self.makeConfiguration(worldMap: map))
            CameraTuner.shared.apply(reason: "start")
        }
        updateThermal(log: false)
        model.log.event("boot", [
            "version": .string(model.version), "device": .string(DebugLog.deviceModel),
            "ios": .string(UIDevice.current.systemVersion),
            "mesh_supported": .bool(Self.supportsMesh), "people_supported": .bool(Self.supportsPeople),
            "alignment": .string("gravity"), "depth_supported": .bool(Self.supportsDepth),
            "agent_id": .string(model.agentID),
            "thermal": .string(model.thermal),           // P2b: the start state (changes are logged; this was not)
        ])
        if !Self.supportsMesh { model.error = "This device has no LiDAR scene mesh; occlusion and mesh are unavailable." }
    }

    /// Mesh style + occlusion toggles. Cheap; no session restart.
    func applyRenderSettings() {
        var su: ARView.Environment.SceneUnderstanding.Options = []
        if model.occlusion { su.insert(.occlusion) }
        if model.simOn && sim.needsCollision { su.insert(.collision) }   // sim raycasts / convex casts hit the mesh
        if model.simOn && sim.needsPhysics { su.insert(.physics) }       // 9.8: objects fall, roll and rest on the mesh
        arView.environment.sceneUnderstanding.options = su
        var ro: ARView.RenderOptions = [.disableDepthOfField, .disableMotionBlur]
        if !model.peopleOcclusion { ro.insert(.disablePersonOcclusion) }
        if !heatBudget.groundingShadows { ro.insert(.disableGroundingShadows) }   // 9.8 heat budget: lighter shadows
        arView.renderOptions = ro
        meshOverlay.idleEvery = heatBudget.meshRebuildS
        if model.meshStyle == .debug { arView.debugOptions.insert(.showSceneUnderstanding) }
        else { arView.debugOptions.remove(.showSceneUnderstanding) }
        meshOverlay.isEnabled = model.meshStyle == .wire
        guard started else { return }
        model.log.event("render", ["mesh": .string(model.meshStyle.rawValue), "occlusion": .bool(model.occlusion),
                                   "people": .bool(model.peopleOcclusion)])
    }

    /// Frame-semantics change (people occlusion): re-run WITHOUT reset options so tracking and anchors survive.
    func rerunConfiguration() {
        guard started else { return }
        applyRenderSettings()
        arView.session.run(makeConfiguration())
    }

    /// Recording needs LiDAR depth frames: re-run (no reset) with/without `.sceneDepth`; tracking and anchors survive.
    func setDepthCapture(_ on: Bool) {
        guard depthCapture != on else { return }
        depthCapture = on
        meshOverlay.recording = on
        lastLevel = "normal"
        if on && !Self.supportsDepth { model.flash("This device has no LiDAR depth: recording saves nothing") }
        if !on {
            meshOverlay.rebuildEvery = AdaptiveCapture.meshRebuildInterval(.live)
            model.meshMode = .live
            model.recNote = nil
        }
        if !on && meshShed {
            meshShed = false                        // Stop: mesh back on (it rebuilds from the live view)
            meshOverlay.thaw(now: CACurrentMediaTime())   // the frozen copy stays until the live mesh has rebuilt
            model.log.event("mesh_restored")
        }
        rerunConfiguration()
    }

    /// Freeze the mesh for the rest of this recording: stop ARKit scene reconstruction and free what it holds
    /// (Recon3D's volume, the mesh anchors, RealityKit's occlusion mesh) but KEEP our wireframe copy on screen, dimmed
    /// (9.6; 9.1.61 removed it, so the owner saw no mesh at all). Tracking and the recording continue.
    func shedMesh(reason: String) {
        guard depthCapture, !meshShed, Self.supportsMesh else { return }
        meshShed = true
        var ev = MemoryProbe.fields()
        ev["reason"] = .string(reason)
        ev["thermal"] = .string(model.thermal)
        ev["mesh_vertices"] = .int(meshOverlay.vertexCount)
        ev["kept_on_screen"] = .int(meshOverlay.count)
        meshOverlay.freeze()
        applyRenderSettings()
        arView.session.run(makeConfiguration(), options: [.resetSceneReconstruction])
        model.log.event("mesh_frozen", ev)
    }

    private func memoryWarning() {
        model.memoryWarnings += 1
        var ev = MemoryProbe.fields()
        ev["recording"] = .bool(model.recording)
        ev["warnings"] = .int(model.memoryWarnings)
        model.log.event("mem_warning", ev)
        if model.recording { evaluateCapturePolicy() }
    }

    /// Adaptive recording policy (HUD tick + memory warnings). Main thread.
    func evaluateCapturePolicy() {
        guard model.recorder.isRecording else { return }
        let d = AdaptiveCapture.decide(thermal: ThermalLevel(label: model.thermal), availableMB: MemoryProbe.availableMB(),
                                       memoryWarnings: model.memoryWarnings,
                                       meshVertices: meshShed ? nil : meshOverlay.vertexCount)
        if model.recWarning != d.warning { model.recWarning = d.warning }
        if d.note != nil, model.recNote != d.note { model.recNote = d.note }      // sticky until Stop (cap reached)
        let mode: MeshMode = meshShed ? .frozen : d.meshMode
        if model.meshMode != mode { model.meshMode = mode }
        if d.rateHz > 0, model.recRateHz != d.rateHz { model.recRateHz = d.rateHz }
        meshOverlay.rebuildEvery = AdaptiveCapture.meshRebuildInterval(mode)
        if d.level != lastLevel {
            lastLevel = d.level
            var ev = MemoryProbe.fields()
            ev["level"] = .string(d.level); ev["rate_hz"] = .double(d.rateHz); ev["jpeg_q"] = .double(d.jpegQuality)
            ev["thermal"] = .string(model.thermal); ev["mesh_shed"] = .bool(d.shedMesh || meshShed)
            ev["mesh_mode"] = .string(mode.rawValue); ev["mesh_vertices"] = .int(meshOverlay.vertexCount)
            model.log.event("rec_adapt", ev)
        }
        if d.meshMode == .frozen { shedMesh(reason: d.note != nil ? "mesh_cap" : d.level) }
        if let reason = d.stopReason {
            model.stopRecording(reason: reason)
            return
        }
        model.recorder.apply(d)
    }

    private func logMemory(_ why: String) {
        var ev = MemoryProbe.fields()
        ev["why"] = .string(why)
        ev["thermal"] = .string(model.thermal)
        ev["recording"] = .bool(model.recording)
        ev["mesh_anchors"] = .int(meshOverlay.count)
        ev["mesh_shed"] = .bool(meshShed)
        ev["mesh_vertices"] = .int(meshOverlay.vertexCount)
        if model.recording {
            let st = model.recStats
            ev["frames"] = .int(st.frames)
            ev["keyframes"] = .int(st.keyframes)
            ev["rate_hz"] = .double(model.recorder.rateHz)
            ev["rec_mb"] = .double((Double(st.bytes) / 1_048_576 * 10).rounded() / 10)
            if let last = lastRecBytes, st.elapsed > last.1 {      // capture write rate over the last window
                ev["rec_mb_per_min"] = .double((Double(st.bytes - last.0) / 1_048_576 / (st.elapsed - last.1) * 60 * 10).rounded() / 10)
            }
            lastRecBytes = (st.bytes, st.elapsed)
        } else { lastRecBytes = nil }
        model.log.event("mem", ev)
    }

    /// "Reset AR": start tracking again. With saved places it relocalizes into them (the place's animals come back
    /// from the last save once LOCALIZED); without, a clean session.
    /// 10.3: always a clean session; the house map finds the phone again (and brings the bodies back), a saved place is
    /// tried only on evidence (PlaceController / PlaceAssist).
    func resetSession() {
        model.log.event("reset", ["places": .int(model.placeCtl.store.manifests.count)])
        sim.removeAllBodies()
        model.placeCtl.sessionReset()
        runWorldMap(nil)
        model.flash("AR reset: move slowly; finding you on the house map", seconds: 3)
    }

    /// P2a: re-run the session from scratch with a saved place's world map (nil = an empty new place). Placed cubes,
    /// the mesh and every anchor go; sim bodies are restored by PlaceController once LOCALIZED.
    /// `carryLock` (10.3): an aborted saved map — keep the house-map lock across the reset (MapLocalizer carries it).
    func runWorldMap(_ map: ARWorldMap?, carryLock: Bool = false) {
        model.mapLocalizer.worldFrameChanged(map == nil ? (carryLock ? "place_abort" : "new_session") : "place_load",
                                             sessionRunFollows: true, carryLock: carryLock)
        renderer.clearAll(session: arView.session)
        model.cubeSel = nil
        meshOverlay.removeAll()
        model.measureText = nil
        applyRenderSettings()
        arView.session.run(makeConfiguration(worldMap: map),
                           options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
        CameraTuner.shared.apply(reason: "rerun")
        model.log.event("ar_rerun", ["world_map": .bool(map != nil)])
    }

    /// 9.3 Photo-quality object scan: Object Capture runs its own AR session, so ours pauses while it is on screen.
    func suspendForObjectCapture() {
        arView.session.pause()
        model.log.event("ar_paused", ["why": .string("object_capture")])
    }

    /// Back from Object Capture: our tracking is stale, so start clean (placed cubes and the mesh are rebuilt/cleared).
    func resumeAfterObjectCapture() {
        model.log.event("ar_resumed", ["why": .string("object_capture")])
        resetSession()                              // P2a: back into the saved place when there is one
    }

    /// 9.6 Scans screen: pause our session while it is up (its viewers render without AR, the dollhouse runs its own).
    func suspendForScans() {
        arView.session.pause()
        var ev = MemoryProbe.fields()
        ev["why"] = .string("scans")
        model.log.event("ar_paused", ev)
    }

    /// Back from Scans: resume without reset (tracking relocalizes; placed cubes and the mesh survive).
    func resumeAfterScans() {
        arView.session.run(makeConfiguration())
        var ev = MemoryProbe.fields()
        ev["why"] = .string("scans")
        model.log.event("ar_resumed", ev)
    }

    func clearPlaced() {
        renderer.clearAll(session: arView.session)
        model.cubeSel = nil
        model.measureText = nil
        model.log.event("clear")
    }

    // MARK: 9.9 cubes: select, delete (✕ / long-press / list / Clear cubes), undo

    /// Placed cubes in order (the Cubes list).
    var placedCubes: [(id: UUID, number: Int)] { renderer.cubes }

    func selectCube(_ id: UUID?) {
        renderer.selectCube(id)
        model.cubeSel = id.flatMap { i in renderer.number(of: i).map { CubeSelection(id: i, number: $0) } }
        if let c = model.cubeSel { model.log.event("cube_select", ["n": .int(c.number)]) }
    }

    func deleteCubes(_ ids: [UUID], via: String) {
        let snaps = renderer.removeCubes(ids, session: arView.session)
        guard !snaps.isEmpty else { return }
        if let sel = model.cubeSel, ids.contains(sel.id) { model.cubeSel = nil }
        model.log.event("cube_delete", ["numbers": .doubles(snaps.map { Double($0.number) }), "via": .string(via),
                                        "left": .int(renderer.cubes.count)])
        recordDeletion(snaps.map { Deleted.cube($0) },
                       label: snaps.count == 1 ? "Deleted cube #\(snaps[0].number)" : "Deleted \(snaps.count) cubes")
    }

    func deleteSelectedCube() {
        guard let c = model.cubeSel else { return }
        deleteCubes([c.id], via: "bar_x")
    }

    /// More ▸ Clear cubes: every placed cube and every sim cube (blocks, crates, boxes); measures and the rest of the
    /// sim stay. One Undo brings them all back.
    func clearCubes() {
        var items: [Deleted] = renderer.removeAllCubes(session: arView.session).map { Deleted.cube($0) }
        model.cubeSel = nil
        collecting = []
        sim.deleteObjects(sim.cubeObjects.map { $0.id }, via: "clear_cubes")
        items += collecting ?? []
        collecting = nil
        model.log.event("cube_clear", ["count": .int(items.count)])
        guard !items.isEmpty else { model.flash("No cubes to clear"); return }
        recordDeletion(items, label: "Cleared \(items.count) cube\(items.count == 1 ? "" : "s")")
    }

    func clearMeasures() {
        renderer.clearMeasures(session: arView.session)
        model.measureText = nil
        model.log.event("clear_measures")
    }

    func recordDeletion(_ items: [Deleted], label: String) {
        if collecting != nil { collecting! += items; return }
        undo.record(items, label: label, now: CACurrentMediaTime())
        model.showUndo(label)
    }

    func undoDeletion() {
        let items = undo.undo(now: CACurrentMediaTime())
        model.hideUndo()
        guard !items.isEmpty else { model.flash("Too late to undo (5 s)"); return }
        var cubes: [SceneRenderer.CubeSnapshot] = [], objs: [SimController.ObjectSnapshot] = []
        for it in items {
            switch it {
            case .cube(let c): cubes.append(c)
            case .object(let o): objs.append(o)
            }
        }
        renderer.restoreCubes(cubes, session: arView.session)
        if !objs.isEmpty {
            if !model.simOn { model.simOn = true }
            sim.restoreObjects(objs)
        }
        model.log.event("undo_delete", ["cubes": .int(cubes.count), "objects": .int(objs.count)])
        model.flash("Restored", seconds: 1.2)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, !model.objectScan.lidarActive else { return }
        let pt = g.location(in: arView)
        if let ray = arView.ray(through: pt), let id = renderer.pickCube(origin: ray.origin, direction: ray.direction) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            deleteCubes([id], via: "long_press")
            return
        }
        if model.simOn, let oid = sim.objectID(at: pt), sim.isCubeObject(oid) {     // cubes only: hold-then-throw a ball stays safe
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            sim.deleteObjects([oid], via: "long_press")
        }
    }

    // MARK: taps

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let pt = g.location(in: arView)
        if model.objectScan.lidarActive {                   // 9.3: taps place the object box (floor, then object)
            objectBox.handleTap(pt)
            return
        }
        // 9.9: a tap on a placed cube selects it (✕ on its bar); with one selected, a tap elsewhere just deselects
        if let ray = arView.ray(through: pt), let id = renderer.pickCube(origin: ray.origin, direction: ray.direction) {
            selectCube(model.cubeSel?.id == id ? nil : id)
            return
        }
        if model.cubeSel != nil { selectCube(nil); return }
        switch model.tool {                                 // 10.1 AR 1:1 tools act on the house map
        case .objects: _ = mapLayer.handleObjectTap(pt); return
        case .robotPath: _ = model.terrainLayer.handleTap(pt, arView: arView); return
        default: break
        }
        if model.simOn, model.serverSim.handleTap(pt, arView: arView) { return }   // 10.1 S2: shared sim bodies
        if model.simOn, sim.handleTap(pt) { return }        // 9.5: select / command sim bodies first
        // As in Apple's sample: `.estimatedPlane` + `.any` also hits the reconstructed mesh.
        guard let hit = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .any).first else {
            model.flash("No surface there yet: sweep the phone over it first")
            return
        }
        let cam = arView.cameraTransform
        let camPos = cam.translation
        let w = hit.worldTransform
        switch model.tool {
        case .cube:
            let (n, m) = renderer.placeCube(hit: w, cameraPosition: camPos, session: arView.session)
            let p = Geo.position(m)
            model.log.event("place_cube", ["n": .int(n), "pos": .doubles([Double(p.x), Double(p.y), Double(p.z)]),
                                           "tilt_deg": .double(Double(Geo.angleDegrees(Geo.normal(w), Geo.worldUp))),
                                           "range_m": .double(Double(Geo.distance(p, camPos)))])
        case .measure:
            let p = Geo.position(w)
            switch renderer.measureTap(at: p) {
            case .first:
                model.measureText = "A set: tap B"
            case .second(let a, let b, let d):
                model.measureText = Geo.centimetres(d)
                model.log.event("measure", ["cm": .double(Double(d * 100)),
                                            "a": .doubles([Double(a.x), Double(a.y), Double(a.z)]),
                                            "b": .doubles([Double(b.x), Double(b.y), Double(b.z)])])
            }
        case .objects, .robotPath:
            break
        case .ruler:
            let fwd = -SIMD3<Float>(cam.matrix.columns.2.x, cam.matrix.columns.2.y, cam.matrix.columns.2.z)
            if let f = renderer.placeRuler(hit: w, cameraForward: fwd, session: arView.session) {
                let o = Geo.position(f)
                model.log.event("ruler", ["origin": .doubles([Double(o.x), Double(o.y), Double(o.z)]),
                                          "dir": .doubles([Double(f.columns.0.x), Double(f.columns.0.y), Double(f.columns.0.z)])])
            } else {
                model.flash("Tilt the phone so you look along the surface, not straight at it")
            }
        }
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        autoreleasepool { handle(frame) }           // per-frame temporaries never pile up; the ARFrame is not kept
    }

    private func handle(_ frame: ARFrame) {
        let t = frame.timestamp
        fpsMeter.tick(t)
        if model.recorder.isRecording {
            model.recorder.process(frame: frame, thermalSerious: model.thermal == "SERIOUS" || model.thermal == "CRITICAL")
        }
        model.mapLocalizer.frame(frame)                  // P2b: keyframes to /v1/localize while finding / refining
        model.liveStreamer.frame(frame)                  // 10.0 Live map: keyframes to the live uplink while on
        model.meshMapper.frame(frame)                    // 10.2 Map mesh: depth / sharp keyframes to /v1/meshmap
        mapLayer.frame(frame)                            // 10.1 AR 1:1: blend the map alignment, labels face you
        model.serverSim.frame()                          // 10.1 S2: dead-reckoned shared-sim bodies + teleop
        renderer.updateBillboards(camera: Geo.position(frame.camera.transform))
        meshOverlay.tick(now: t)
        if lastMapping != frame.worldMappingStatus {
            lastMapping = frame.worldMappingStatus
            model.log.event("mapping", ["status": .string(Self.name(frame.worldMappingStatus))])
        }
        guard t - lastHUD >= 0.5 else { return }
        lastHUD = t
        model.fps = fpsMeter.fps
        model.mapping = Self.name(frame.worldMappingStatus)
        model.placeCtl.tick()
        model.mapLocalizer.tick()                        // 10.2: the localization pill (elapsed s, fix age)
        model.meshMapper.tick()                          // 10.2: mesh anchors, upload pump, mapping line
        model.liveMap.tick()                             // 10.1 L3: other agents, downlink
        model.serverSim.tick()                           // 10.1 S2: shared sim connection + authority
        model.meshAnchors = meshOverlay.count
        evaluateCapturePolicy()
        CameraTuner.shared.apply(reason: "tick")         // re-asserts the shutter cap after any session re-run
        if model.recording {                             // evidence: device exposure / ISO 1 s in, then every 30 s
            if !camLoggedThisRecording && model.recStats.elapsed >= 1 || t - lastCamLog >= 30 {
                camLoggedThisRecording = true
                lastCamLog = t
                CameraTuner.shared.logState("recording")
            }
        } else { camLoggedThisRecording = false }
        if t - lastMemLog >= 10 {
            lastMemLog = t
            logMemory("periodic")
        }
        if t - lastFPSLog >= 10 {
            lastFPSLog = t
            let p = Geo.position(frame.camera.transform)
            model.log.event("fps", ["fps": .double(fpsMeter.fps), "mesh_anchors": .int(meshOverlay.count),
                                    "thermal": .string(model.thermal), "tracking": .string(model.tracking.code),
                                    "cam": .doubles([Double(p.x), Double(p.y), Double(p.z)])])
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let s = Self.status(camera.trackingState)
        model.tracking = s
        model.log.event("tracking", ["state": .string(s.code)])
        model.recorder.trackingChanged(s.code)
        model.placeCtl.trackingChanged(s)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for a in anchors { if let m = a as? ARMeshAnchor { meshOverlay.update(m); if model.simOn { sim.meshChanged(m) } } }
        model.meshMapper.anchorsChanged(anchors.compactMap { $0 as? ARMeshAnchor })
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        model.meshMapper.anchorsChanged(anchors.compactMap { $0 as? ARMeshAnchor })
        for a in anchors {
            if let m = a as? ARMeshAnchor { meshOverlay.update(m); if model.simOn { sim.meshChanged(m) } }
            else if let shift = renderer.anchorShift(a), shift > 0.01,
                    Date().timeIntervalSince1970 - (shiftLogged[a.identifier] ?? 0) > 5 {
                shiftLogged[a.identifier] = Date().timeIntervalSince1970
                model.log.event("anchor_shift", ["name": .string(a.name ?? "?"), "cm": .double(Double(shift * 100))])
            }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for a in anchors where a is ARMeshAnchor {
            meshOverlay.remove(a.identifier)
            model.meshMapper.anchorRemoved(a.identifier)
            if model.simOn { sim.meshRemoved(a.identifier) }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) { model.log.event("interrupted") }
    func sessionInterruptionEnded(_ session: ARSession) { model.log.event("interruption_ended") }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let text = describe(error)
        model.error = text
        model.log.event("error", ["message": .string(text)])
        presentFailureAlert(text) { [weak self] in self?.resetSession() }
    }

    // MARK: helpers

    private func updateThermal(log: Bool) {
        let s: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s = "nominal"
        case .fair: s = "fair"
        case .serious: s = "SERIOUS"
        case .critical: s = "CRITICAL"
        @unknown default: s = "?"
        }
        model.thermal = s
        // 9.8: every transition with how long the previous state lasted (owner: "over-judging the heat")
        let level = ThermalLevel(label: s), now = CACurrentMediaTime()
        var change: (from: ThermalLevel, lasted: Double)?
        if thermalHistory == nil { thermalHistory = ThermalHistory(state: level, at: now) }
        else { change = thermalHistory?.change(to: level, at: now) }
        if log {
            var ev = MemoryProbe.fields()
            ev["state"] = .string(s)
            ev["recording"] = .bool(model.recording)
            ev["sim"] = .bool(model.simOn)
            ev["mesh"] = .string(model.meshStyle.rawValue)
            ev["people"] = .bool(model.peopleOcclusion)
            ev["fps"] = .double((model.fps * 10).rounded() / 10)
            if let c = change, let h = thermalHistory {
                ev["from"] = .string(Self.thermalName(c.from))
                ev["lasted_s"] = .double(c.lasted.rounded())
                ev["serious_total_s"] = .double(h.total(.serious, at: now).rounded())
                ev["serious_count"] = .int(h.entries[.serious] ?? 0)
            }
            model.log.event("thermal", ev)
            evaluateCapturePolicy()
        }
        refreshHeatBudget(reason: "thermal")
    }

    static func thermalName(_ t: ThermalLevel) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        }
    }

    /// Re-derive the heat budget (thermal change, Settings ▸ Sim quality); apply + log only when it changes.
    func refreshHeatBudget(reason: String) {
        let b = SimBudgets.budget(mode: model.simPerf, thermal: ThermalLevel(label: model.thermal))
        guard b != heatBudget else { return }
        let old = heatBudget
        heatBudget = b
        model.heatNote = b.note
        model.log.event("heat_budget", ["tier": .string(b.tier.rawValue), "from": .string(old.tier.rawValue),
                                        "thermal": .string(model.thermal), "mode": .string(model.simPerf.rawValue),
                                        "shadows": .bool(b.groundingShadows), "mesh_rebuild_s": .double(b.meshRebuildS),
                                        "sim_hz": .double(b.animalHz), "reason": .string(reason)])
        applyRenderSettings()
    }

    static func status(_ s: ARCamera.TrackingState) -> TrackingStatus {
        switch s {
        case .normal: return .normal
        case .notAvailable: return .notAvailable
        case .limited(let r):
            switch r {
            case .initializing: return .limited(.initializing)
            case .excessiveMotion: return .limited(.excessiveMotion)
            case .insufficientFeatures: return .limited(.insufficientFeatures)
            case .relocalizing: return .limited(.relocalizing)
            @unknown default: return .limited(.unknown)
            }
        }
    }

    static func name(_ m: ARFrame.WorldMappingStatus) -> String {
        switch m {
        case .notAvailable: return "none"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "?"
        }
    }
}
