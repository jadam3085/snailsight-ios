import SwiftUI
import UIKit
import SnailSightCore

enum ToolMode: String, CaseIterable, Identifiable {
    case cube = "Cube", measure = "Measure", ruler = "1 m ruler"
    case objects = "Objects", robotPath = "Robot path"           // 10.1 AR 1:1 (Sources/AR)
    var id: String { rawValue }
    var help: String {
        switch self {
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
    @Published var tool: ToolMode = .cube
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
    @Published var meshMapLive = false
    @Published var showSettings = false
    /// 10.0 Live map (Sources/Live/LiveStreamer, API §6b): stream keyframes to the map server while on. Off at launch.
    @Published var liveOn = false { didSet { if liveOn != oldValue { liveStreamer.setEnabled(liveOn) } } }
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

    // 10.1 AR 1:1 (Sources/AR): the house map drawn where it really is once LOCALIZED
    @Published var houseStyle: HouseStyle = HouseStyle(rawValue: UserDefaults.standard.string(forKey: "ar.house") ?? "") ?? .wire {
        didSet { UserDefaults.standard.set(houseStyle.rawValue, forKey: "ar.house") }
    }
    @Published var arObjects: Bool = UserDefaults.standard.object(forKey: "ar.objects") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arObjects, forKey: "ar.objects") }
    }
    @Published var arTerrain = false                        // P3 robot terrain overlay (off at launch: it is busy)
    @Published var arAgents: Bool = UserDefaults.standard.object(forKey: "ar.agents") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arAgents, forKey: "ar.agents") }
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
    @Published var recording = false
    @Published var recStats = RecordStats()
    @Published var recWarning: String?                 // adaptive-recording notice (hot / low memory), 9.1.61
    @Published var recNote: String?                    // 9.6 neutral notice (mesh memory cap reached)
    @Published var recRateHz: Double = AdaptiveCapture.baseRateHz   // 9.6 HUD "REC n fps" (capture rate, not AR fps)
    @Published var meshMode: MeshMode = .live          // 9.6 live / slow updates / frozen (kept on screen, dimmed)
    @Published var showScans = false {                 // 9.6 Scans screen (Sources/Scans); closing resumes AR
        didSet { if oldValue && !showScans { scansClosed() } }
    }
    var memoryWarnings = 0                             // memory warnings during the current recording
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
    private(set) lazy var meshMapper = MeshMapper(model: self)
    private(set) lazy var terrainLayer = TerrainARLayer(model: self)
    private(set) lazy var liveMap = LiveMapClient(model: self)
    private(set) lazy var serverSim = ServerSimClient(model: self)
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
        if serverBase == nil && it.sentBytes == 0 { return "Waiting for the map server (offline) · \(packed)/\(it.parts.count) parts ready" }
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
        var s = serverBase == nil ? "srv offline" : "srv \(serverLabel) ✓"
        if let up = uploads.first(where: { !$0.serverHasAll }), serverBase != nil, up.bytesTotal > 0 {
            s += String(format: " · ↑ %.0f %%", up.progress * 100)
        }
        if pendingUploads > 0 { s += " · \(pendingUploads) queued" }
        return s
    }

    init() {
        logURL = log.fileURL
        services.onLink = { [weak self] base, label in
            self?.serverBase = base
            self?.serverLabel = label
            if base != nil { self?.placeCtl.online(); self?.refreshFeatures(); self?.meshMapper.pump() }   // places / mapping saved offline go up now
        }
        services.onUploads = { [weak self] items, rate in
            self?.uploads = items
            self?.uploadRate = rate
        }
        recorder.onStats = { [weak self] s in self?.recStats = s }
        let lg = services.log
        recorder.onEvent = { ev, data in lg.event(ev, data) }
        UIApplication.shared.isIdleTimerDisabled = true
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
            await q.kick(reason: "launch")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.periodicSync() }
        mapFollower.start()                                 // 10.7: cached head now, the server's head in the background
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.backgroundFlush()
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log.event("foreground")
            let q = self.queue!
            // 10.6.x: every server loop resumes at once (owner: one timeout + background and it never placed him)
            self.mapLocalizer.resume(why: "foreground")
            self.mapFollower.resume(why: "foreground")
            self.liveMap.resume(why: "foreground")
            self.serverSim.resume(why: "foreground")
            self.placeCtl.publish()
            Task {
                await self.link.probe(force: true)
                await MainActor.run {                       // the server answered again (or still not): resume again
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
        Task {
            try? await lg.syncAll()
            await q.kick()
        }
    }

    private func backgroundFlush() {
        log.event("background")
        mapLocalizer.enteredBackground()
        mapFollower.enteredBackground()
        // ARKit stops in the background and iOS may end a suspended app: finish the capture cleanly now
        if recorder.isRecording { stopRecording(reason: "background") }
        meshMapper.appBackground()                      // 10.2: ARKit stops; the mapping upload finishes
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

    /// "Send log": upload now and confirm with the path on the map server.
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

    func scansClosed() {
        controller.resumeAfterScans()
        mapLocalizer.resume(why: "scans_closed")
        mapFollower.resume(why: "scans_closed")
        liveMap.resume(why: "scans_closed")
    }

    /// 9.9: "Deleted … [Undo]" for 5 s (the deletion itself is kept in ARSessionController's UndoBuffer).
    func showUndo(_ text: String, seconds: Double = 5) {
        undoText = text
        undoWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.undoText = nil }
        undoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func hideUndo() {
        undoWork?.cancel()
        undoText = nil
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
