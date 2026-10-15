// 9.6 Scans viewer: one scan (house map version, walk or object) in Mesh | Splat | Hybrid | AR dollhouse | AR 1:1 (stub).
// Orbit / Walk / Drone camera shared by every view, walk points ◀ n/N ▶ (as the web viewer, §8.7), Measure on the mesh,
// double-tap = focus (orbit) / walk there (walk, drone). Memory is logged like the recorder does (ev "scan_mem" every
// 10 s with footprint / available / limit) and shown in the top bar.
// 9.8: Drone mode (DroneController.swift: dual sticks, altitude, speed, mesh collision, levels, Home, minimap),
// Hybrid view (splat drawn, mesh = geometry for collision / picking / labels, as the web viewer §8.8), labels: tap the
// scan with the Label tool to pin an object label or name the room, room outlines on the floor plan
// (RoomEditorView), label billboards + list (LabelViews), all synced with the server (ScanLabelStore).
import SwiftUI
import RealityKit
import Combine
import SnailSightCore

enum ScanViewMode: String, CaseIterable, Identifiable {
    case mesh = "Mesh", splat = "Splat", hybrid = "Hybrid", dollhouse = "Dollhouse", overlay = "AR 1:1"
    var id: String { rawValue }
    /// Splat drawn (Splat, Hybrid).
    var drawsSplat: Bool { self == .splat || self == .hybrid }
    /// The mesh answers position questions (Measure, labels, collision): Mesh and Hybrid (§8.8: never the splat).
    var meshGeometry: Bool { self == .mesh || self == .hybrid }
    var is3D: Bool { self == .mesh || self == .splat || self == .hybrid }
}

/// 9.9: Orbit | Fly. Fly = the drone driver (mesh collision, glides, levels, Home, minimap) with two control schemes
/// (FlyScheme): Simple (default, the 9.6 walk / web Fly: one stick, drag to look, ▲▼) or Advanced (dual sticks).
enum NavMode: String, CaseIterable, Identifiable {
    case orbit = "Orbit", fly = "Fly"
    var id: String { rawValue }
    var icon: String { self == .orbit ? "rotate.3d" : "figure.walk" }
}

struct RoomEditorRequest: Identifiable {
    let id = UUID()
    let start: RoomEditorView.Start
    let level: Int
}

@MainActor
final class ScanViewerModel: ObservableObject {
    let item: ScanItem
    let store: ScanStore
    let log: DebugLog
    let camera = ViewerCamera()
    let markers = MeasureMarkers()
    let dollhouse = DollhouseState()
    let tracker = CameraTracker()
    let drone: DroneDriver
    let plans: ScanPlans
    let labels: ScanLabelStore
    let overlay = LabelOverlayModel()

    @Published var mode: ScanViewMode = .mesh
    @Published var status: String?
    @Published var progress: Double?
    @Published var error: String?
    @Published var meshEntity: Entity?
    @Published var dollhouseModel: Entity?
    @Published var splatReady = false
    @Published var splatInfo = ""
    @Published var measuring = false { didSet { if !measuring { markers.clear(); measureText = nil } else { labeling = false } } }
    @Published var measureText: String?
    @Published var walkPoints: [WalkPoint] = []
    @Published var walkIndex: Int?
    @Published var nav: NavMode = .orbit { didSet { if nav != oldValue { navChanged(from: oldValue) } } }
    @Published var memText = ""
    // 9.8 labels / drone
    @Published var labeling = false { didSet { if labeling { measuring = false; flash("Tap the scan to label that spot") } } }
    @Published var labelTarget: LabelTarget?
    @Published var detail: SceneObject?
    @Published var roomDetails: RoomRecord?
    @Published var showList = false
    @Published var roomEditor: RoomEditorRequest?
    @Published var showMinimap = UserDefaults.standard.object(forKey: "scan.minimap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMinimap, forKey: "scan.minimap") }
    }
    @Published var flyScheme = FlyScheme(rawValue: UserDefaults.standard.string(forKey: "scan.flyScheme") ?? "") ?? .minimal {
        didSet {
            UserDefaults.standard.set(flyScheme.rawValue, forKey: "scan.flyScheme")
            drone.input = DroneInput()
            log.event("scan_fly_scheme", ["scheme": .string(flyScheme.rawValue)])
        }
    }
    @Published var levelIndex: Int?
    @Published var hint: String?
    @Published private(set) var hasCollider = false

    private(set) var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    private var tri: TriangleIndex?
    private(set) var splatRenderer: SplatSceneRenderer?
    private var splatLoading = false
    private var memTimer: Timer?
    private var lastMemLog = Date.distantPast
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var listener: UUID?
    private var subs: Set<AnyCancellable> = []
    private var hintTask: Task<Void, Never>?

    init(item: ScanItem, store: ScanStore, log: DebugLog) {
        self.item = item
        self.store = store
        self.log = log
        drone = DroneDriver(camera: camera)
        plans = ScanPlans(log: log)
        labels = ScanLabelStore(item: item, store: store, log: log)
        if item.mesh == nil && item.splat != nil { mode = .splat }
    }

    var floorY: Float? { item.type == .object ? 0 : item.floorZ.map { Float($0) } }
    var labelsEnabled: Bool { labels.enabled }

    func start() {
        guard !started else { return }
        started = true
        store.touch(item.id)
        var ev = MemoryProbe.fields()
        ev["id"] = .string(item.id); ev["type"] = .string(item.type.rawValue)
        ev["mesh_state"] = .string(item.mesh?.state ?? "none"); ev["splat_count"] = .int(item.splat?.count ?? 0)
        log.event("scan_open", ev)
        if let b = item.boundsYUp { bounds = b; camera.frame(min: b.min, max: b.max) }
        camera.onTap = { [weak self] p, s in self?.tapped(p, s) }
        camera.onDoubleTap = { [weak self] p, s in self?.doubleTapped(p, s) }
        camera.walkCollider = { [weak self] a, b in self?.drone.sweep(a, b) ?? b }
        overlay.camera = camera
        listener = camera.listen { [weak self] in self?.cameraMoved() }
        labels.$mapLabels.sink { [weak self] l in self?.overlay.labels = l + (self?.agentLabels ?? []) }.store(in: &subs)
        // the viewer's own controls show label / plan state (the overlay and the HUD observe their own models)
        labels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
        plans.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
        labels.$notice.compactMap { $0 }.sink { [weak self] n in self?.flash(n) }.store(in: &subs)
        tasks.append(Task { await self.loadMesh() })
        tasks.append(Task { await self.loadWalkPoints() })
        if labels.enabled { tasks.append(Task { await self.labels.load() }) }
        if mode.drawsSplat { tasks.append(Task { await self.loadSplat() }) }
        memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.memTick() }
        }
        memTick()
    }

    func stop() {
        memTimer?.invalidate()
        memTimer = nil
        drone.stop()
        if let l = listener { camera.unlisten(l) }
        listener = nil
        subs.removeAll()
        for t in tasks { t.cancel() }
        var ev = MemoryProbe.fields()
        ev["id"] = .string(item.id)
        log.event("scan_close", ev)
        splatRenderer?.unload()
        splatRenderer = nil
        meshEntity = nil
        dollhouseModel = nil
        tri = nil
        overlay.triangles = nil
        drone.collider = nil
    }

    // 10.1 L3: other agents mapping right now (GET /v1/live/state), as billboards on the map version the live head
    // is based on (an older version's frame would put them in the wrong place).
    private var agentLabels: [MapLabel] = []
    private var agentPolling = false

    private func pollAgents() {
        guard item.type == .map, let map = item.mapID, !agentPolling else { return }
        agentPolling = true
        let store = self.store, me = Identity.agentID, v = item.version
        Task { [weak self] in
            let r = try? await store.api("GET", "/v1/live/state?map_id=\(map)", timeout: 8)
            let doc = (r?.1 == 200) ? r.flatMap { try? JSONDecoder().decode(LiveStateDoc.self, from: $0.0) } : nil
            await MainActor.run {
                guard let self else { return }
                self.agentPolling = false
                var out: [MapLabel] = []
                if let doc, doc.baseVersion == nil || doc.baseVersion == v {
                    for m in AgentMark.from(doc.agents, me: me, now: Date().timeIntervalSince1970) {
                        out.append(MapLabel(id: "agent:" + m.id, kind: "agent", name: m.label,
                                            category: m.live ? "live" : "idle", position: m.position, roomID: nil))
                    }
                }
                if out != self.agentLabels {
                    self.agentLabels = out
                    self.overlay.labels = self.labels.mapLabels + out
                }
            }
        }
    }

    private func memTick() {
        pollAgents()
        let f = MemoryProbe.footprintMB(), a = MemoryProbe.availableMB()
        memText = [f.map { String(format: "%.0f MB", $0) }, a.map { String(format: "%.1f GB free", $0 / 1024) }]
            .compactMap { $0 }.joined(separator: " · ")
        if Date().timeIntervalSince(lastMemLog) >= 10 {
            lastMemLog = Date()
            var ev = MemoryProbe.fields()
            ev["id"] = .string(item.id); ev["mode"] = .string(mode.rawValue); ev["nav"] = .string(nav.rawValue)
            ev["splats"] = .int(splatRenderer?.splatCount ?? 0); ev["triangles"] = .int(tri?.triangleCount ?? 0)
            log.event("scan_mem", ev)
        }
    }

    private func cameraMoved() {
        tracker.update(camera)
        overlay.refresh()
        if nav != .orbit, !plans.floors.isEmpty {
            let li = plans.level(ofEye: camera.eye.y)
            if li != levelIndex {
                levelIndex = li
                if let li { plans.request(li) }
            }
        }
    }

    /// A short message over the scan (saved, blocked, …) that clears itself.
    func flash(_ t: String) {
        hint = t
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.hint = nil }
        }
    }

    // MARK: loading

    private func loadMesh() async {
        var it = item
        if !(it.mesh?.isReady ?? false), !store.isCached(it.id) || store.cached[it.id]?.meshFile == nil {
            if store.offline { status = nil; error = "This scan is not saved on the phone and the map server is offline."; return }
            if it.mesh == nil && it.type != .object && item.splat != nil { return }      // splat-only scene
            await store.prepare(it.id)
            let t0 = Date()
            while !Task.isCancelled {
                status = "The map server is preparing the phone mesh (\(it.mesh?.state ?? "queued"))…"
                if it.mesh?.isReady == true { break }
                if it.mesh?.state == "failed" {
                    status = nil
                    error = "The phone mesh failed on the map server: \(it.mesh?.error ?? "see the server log")"
                    log.event("scan_mesh_failed", ["id": .string(it.id), "error": .string(it.mesh?.error ?? "")])
                    return
                }
                if Date().timeIntervalSince(t0) > 20 * 60 { status = nil; error = "The phone mesh is taking too long; try again later."; return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let n = try? await store.fetch(it.id) { it = n }
            }
        }
        guard !Task.isCancelled else { return }
        do {
            status = "Downloading mesh \(ScanCatalog.bytesText(it.mesh?.bytes))…"
            let (url, _) = try await store.file(it, .mesh) { [weak self] p in self?.progress = p }
            progress = nil
            status = "Opening mesh…"
            let t0 = Date()
            let e = try await ScanModelLoader.load(url)
            let b = ScanModelLoader.bounds(e)
            bounds = b
            markers.setScale(simd_length(b.max - b.min))
            if (item.boundsYUp == nil || !mode.drawsSplat) && nav == .orbit { camera.frame(min: b.min, max: b.max) }
            meshEntity = e
            if mode == .dollhouse && dollhouseModel == nil { dollhouseModel = e.clone(recursive: true) }
            status = nil
            var ev = MemoryProbe.fields()
            ev["id"] = .string(it.id); ev["s"] = .double(Date().timeIntervalSince(t0))
            ev["mb"] = .double(Double(it.mesh?.bytes ?? 0) / 1_048_576)
            log.event("scan_mesh_loaded", ev)
            // triangles for Measure / walk-to / collision / labels: copied on the main actor, indexed off it
            let soup = ScanModelLoader.triangles(e)
            let idx = await Task.detached(priority: .utility) { TriangleIndex(positions: soup.positions, indices: soup.indices) }.value
            guard !Task.isCancelled else { return }
            tri = idx
            overlay.triangles = idx
            updateCollider()
            log.event("scan_mesh_index", ["triangles": .int(idx.triangleCount)])
            if item.type != .object {
                await plans.setMesh(idx, mainY: floorY)
                levelIndex = nav == .orbit ? nil : plans.level(ofEye: camera.eye.y)
                plans.request(levelIndex ?? mainLevel)
            }
        } catch {
            status = nil
            progress = nil
            self.error = "Could not open the mesh: \(error.localizedDescription)"
            log.event("scan_mesh_error", ["id": .string(it.id), "error": .string(error.localizedDescription)])
        }
    }

    /// The level of the scan's main floor (the server's floor fit), else the lowest.
    var mainLevel: Int {
        guard let y = floorY, !plans.floors.isEmpty else { return 0 }
        return plans.floors.indices.min { abs(plans.floors[$0] - y) < abs(plans.floors[$1] - y) } ?? 0
    }

    private func updateCollider() {
        if let t = tri, mode.meshGeometry {
            let r = drone.params.radius
            drone.collider = { a, b in t.sweep(from: a, to: b, radius: r) }
        } else {
            drone.collider = nil
        }
        hasCollider = drone.collider != nil
    }

    private func loadWalkPoints() async {
        guard item.viewsURL != nil, let got = try? await store.file(item, .views, progress: { _ in }),
              let d = try? Data(contentsOf: got.0) else { return }
        walkPoints = WalkPoints.parse(d)
    }

    func loadSplat() async {
        guard !splatReady, !splatLoading, item.splat != nil else { return }
        splatLoading = true
        defer { splatLoading = false }
        guard let r = splatRenderer ?? SplatSceneRenderer(camera: camera) else { error = "No Metal device"; return }
        splatRenderer = r
        let maxN = SplatBudget.fit(maxSplats: SplatBudget.maxSplats(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
                                   availableMB: MemoryProbe.availableMB())
        guard maxN >= 50_000 else { error = "Not enough free memory for the splat right now"; return }
        do {
            status = "Downloading splat…"
            let (url, n) = try await store.file(item, .splat, maxSplats: maxN) { [weak self] p in self?.progress = p }
            progress = nil
            status = "Loading splat…"
            let count = min(n ?? maxN, maxN)
            let t0 = Date()
            try await r.load(url: url, count: count)
            splatReady = true
            status = nil
            let total = item.splat?.count ?? count
            splatInfo = total > count ? "\(count / 1000) k of \(total / 1000) k splats (phone budget)" : "\(count / 1000) k splats"
            var ev = MemoryProbe.fields()
            ev["id"] = .string(item.id); ev["splats"] = .int(count); ev["budget"] = .int(maxN)
            ev["s"] = .double(Date().timeIntervalSince(t0))
            log.event("scan_splat_loaded", ev)
        } catch {
            status = nil
            progress = nil
            self.error = "Could not open the splat: \(error.localizedDescription)"
            log.event("scan_splat_error", ["id": .string(item.id), "error": .string(error.localizedDescription)])
        }
    }

    func setMode(_ m: ScanViewMode) {
        mode = m
        error = nil
        log.event("scan_mode", ["id": .string(item.id), "mode": .string(m.rawValue)])
        if m.drawsSplat { Task { await loadSplat() } }
        if m == .dollhouse, dollhouseModel == nil, let e = meshEntity { dollhouseModel = e.clone(recursive: true) }
        if !m.meshGeometry { measuring = false }
        if !m.is3D { nav = .orbit }
        updateCollider()
    }

    // MARK: navigation

    private func navChanged(from old: NavMode) {
        switch nav {
        case .orbit:
            drone.stop()
            camera.orbit.target = camera.walk.eye + camera.walk.forward * 1.5
            camera.orbit.distance = max(camera.orbit.distance, 3)
            camera.mode = .orbit
            levelIndex = nil
        case .fly:
            if old == .orbit { enterFirstPerson() }
            drone.start()
        }
        cameraMoved()
        log.event("scan_nav", ["id": .string(item.id), "nav": .string(nav.rawValue), "mode": .string(mode.rawValue),
                               "scheme": .string(flyScheme.rawValue)])
    }

    private func enterFirstPerson() {
        if let i = WalkPoints.nearest(walkPoints, to: camera.orbit.target) {
            walkIndex = i
            camera.jump(to: walkPoints[i])
        } else {
            var eye = camera.orbit.target
            eye.y = (floorY ?? (bounds?.min.y ?? 0)) + 1.5
            camera.walk = WalkCamera(eye: eye, yaw: camera.orbit.yaw)
            camera.mode = .walk
        }
    }

    /// Go to a first-person pose: a smooth flight (switching to Fly from Orbit).
    func go(to pose: WalkCamera) {
        if nav == .orbit { nav = .fly }
        drone.fly(to: pose)
    }

    func stepWalk(_ d: Int) {
        guard !walkPoints.isEmpty else { return }
        let i: Int
        if d == 0 { i = WalkPoints.nearest(walkPoints, to: camera.eye) ?? 0 }
        else { i = ((walkIndex ?? 0) + d + walkPoints.count) % walkPoints.count }
        walkIndex = i
        let w = walkPoints[i]
        if nav == .orbit { nav = .fly; camera.jump(to: w); return }
        drone.fly(to: WalkCamera(eye: w.eye, yaw: w.yaw, pitch: w.pitch))
    }

    func resetView() {
        if nav != .orbit { stepWalk(0); return }
        if let b = bounds { camera.frame(min: b.min, max: b.max) }
    }

    func goHome() {
        guard let h = drone.home else { stepWalk(0); return }
        go(to: h)
        log.event("scan_drone_home", ["id": .string(item.id)])
    }

    func goLevel(_ i: Int) {
        guard plans.floors.indices.contains(i) else { return }
        var e = camera.walk.eye
        e.y = plans.floors[i] + 1.45
        go(to: WalkCamera(eye: e, yaw: camera.walk.yaw, pitch: 0))
        plans.request(i)
        log.event("scan_level", ["id": .string(item.id), "level": .int(i)])
    }

    /// Minimap tap: fly there at eye height, facing the direction of travel.
    func goPlan(_ p: SIMD3<Float>) {
        var e = p
        e.y = p.y + 1.45
        var d = e - camera.walk.eye
        d.y = 0
        let yaw = simd_length(d) > 0.05 ? WalkCamera.yaw(of: d) : camera.walk.yaw
        go(to: WalkCamera(eye: e, yaw: yaw, pitch: 0))
    }

    func flyTo(object o: SceneObject) {
        guard let p = o.pinPoint else { return }
        let t = ScanFrames.mapToYUp(SIMD3(Float(p.x), Float(p.y), Float(p.z)))
        go(to: DroneGlide.viewpoint(looking: t, from: camera.eye))
    }

    func flyTo(room r: RoomRecord) {
        let c = Polygon2D.centroid(r.points)
        let z = r.floorZ ?? item.floorZ ?? Double(camera.eye.y) - 1.45
        let e = ScanFrames.mapToYUp(SIMD3(Float(c.x), Float(c.y), Float(z + 1.45)))
        go(to: WalkCamera(eye: e, yaw: camera.walk.yaw, pitch: -0.15))
    }

    // MARK: taps

    private func hit(_ p: CGPoint, _ s: CGSize) -> TriangleIndex.Hit? {
        guard let tri else { return nil }
        let r = camera.ray(p, s)
        return tri.raycast(origin: r.origin, dir: r.dir)
    }

    private func tapped(_ p: CGPoint, _ s: CGSize) {
        if labeling {
            guard mode.meshGeometry else { flash("Labels are placed on the mesh: switch to Mesh or Hybrid"); return }
            guard tri != nil else { flash("Preparing the mesh for labeling…"); return }
            guard let h = hit(p, s) else { flash("No surface there"); return }
            let m = MapLabels.mapPoint(fromYUp: h.point)
            labelTarget = LabelTarget(yUp: h.point, map: m, room: labels.rooms.room(containing: m))
            log.event("scan_label_tap", ["id": .string(item.id), "x": .double(m.x), "y": .double(m.y), "z": .double(m.z)])
            return
        }
        guard measuring, mode.meshGeometry else { return }
        guard tri != nil else { measureText = "Preparing the mesh for measuring…"; return }
        guard let h = hit(p, s) else { measureText = "No surface there"; return }
        if let d = markers.tap(h.point) {
            measureText = d >= 1 ? String(format: "%.2f m", d) : String(format: "%.1f cm", d * 100)
            log.event("scan_measure", ["id": .string(item.id), "m": .double(Double(d))])
        } else {
            measureText = "A set: tap B"
        }
    }

    private func doubleTapped(_ p: CGPoint, _ s: CGSize) {
        guard let h = hit(p, s) else { return }
        if camera.mode == .walk {
            var eye: SIMD3<Float>
            if h.normal.y > 0.7 { eye = h.point; eye.y += 1.45 }                       // floor: stand on it
            else { eye = h.point + h.normal * 0.6; eye.y = camera.walk.eye.y }        // wall/object: stop 60 cm before
            drone.fly(to: WalkCamera(eye: eye, yaw: camera.walk.yaw, pitch: camera.walk.pitch))
        } else {
            camera.orbit.target = h.point
            camera.orbit.distance = min(camera.orbit.distance, max(1, h.t * 0.6))
            camera.changed()
        }
    }

    /// A billboard was tapped: an object → its details; a room → name / HA area.
    func tapLabel(_ id: String) {
        if id.hasPrefix("room:") {
            let rid = String(id.dropFirst(5))
            roomDetails = labels.rooms.rooms.first { $0.id == rid }
        } else if id.hasPrefix("object:") {
            let oid = String(id.dropFirst(7))
            detail = labels.objects.objects.first { $0.id == oid }
        }
    }

    func openRooms(_ start: RoomEditorView.Start, atY y: Float? = nil) {
        let lv = y.flatMap { ScanLevels.index(of: $0, floors: plans.floors) } ?? levelIndex ?? mainLevel
        roomEditor = RoomEditorRequest(start: start, level: lv)
    }
}

struct ScanViewerView: View {
    @StateObject var vm: ScanViewerModel
    @Environment(\.dismiss) private var dismiss

    init(item: ScanItem, store: ScanStore, log: DebugLog) {
        _vm = StateObject(wrappedValue: ScanViewerModel(item: item, store: store, log: log))
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            content.ignoresSafeArea()
            if vm.mode.is3D && vm.labelsEnabled {
                GeometryReader { g in
                    LabelOverlay(model: vm.overlay) { vm.tapLabel($0) }
                        .onAppear { vm.overlay.size = g.size }
                        .onChange(of: g.size) { _, s in vm.overlay.size = s }
                }
                .ignoresSafeArea()
            }
            VStack(spacing: 8) {
                topBar
                HStack(alignment: .top) {
                    Spacer()
                    minimap
                }
                Spacer()
                if let t = vm.status { statusCard(t) }
                if let e = vm.error ?? vm.labels.error {
                    Text(e).font(.callout).padding(10).frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                        .onTapGesture { vm.error = nil; vm.labels.error = nil }
                }
                if let h = vm.hint {
                    Text(h).font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                }
                if let m = vm.measureText {
                    Text(m).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }
                if vm.mode.is3D && vm.nav == .fly {
                    MinimalFlyHUD(advanced: vm.flyScheme == .advanced, driver: vm.drone, levelNames: vm.plans.names, level: vm.levelIndex,
                                  canCollide: vm.hasCollider, onLevel: { vm.goLevel($0) }, onHome: { vm.goHome() })
                }
                if vm.mode.is3D { navBar }
                if vm.mode == .dollhouse { DollhouseBar(state: vm.dollhouse) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .statusBarHidden(true)
        .sheet(item: $vm.labelTarget) { t in
            NewLabelSheet(labels: vm.labels, target: t) {
                vm.openRooms(.newRoom(around: SIMD2(t.map.x, t.map.y)), atY: t.yUp.y)
            }
        }
        .sheet(item: $vm.detail) { o in
            LabelDetailSheet(labels: vm.labels, object: o) { vm.flyTo(object: o) }
        }
        .sheet(item: $vm.roomDetails) { r in
            NavigationStack {
                RoomDetailsForm(room: r, areas: vm.labels.areas, rooms: vm.labels.rooms.rooms,
                                onDelete: { Task { await vm.labels.deleteRoom(r.id) } }) { nr in
                    Task { await vm.labels.upsertRoom(nr) }
                }
            }
        }
        .sheet(isPresented: $vm.showList) {
            LabelListView(labels: vm.labels,
                          onFlyObject: { vm.flyTo(object: $0) },
                          onFlyRoom: { vm.flyTo(room: $0) },
                          onEditRooms: { vm.openRooms(.browse) })
        }
        // a sheet, not a full-screen cover: a cover can fire this view's onDisappear, which unloads the scan
        .sheet(item: $vm.roomEditor) { r in
            RoomEditorView(labels: vm.labels, plans: vm.plans, level: r.level, start: r.start)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        }
    }

    @ViewBuilder private var content: some View {
        switch vm.mode {
        case .mesh:
            if let e = vm.meshEntity { MeshSceneView(entity: e, camera: vm.camera, markers: vm.markers) }
        case .splat, .hybrid:
            if vm.splatReady, let r = vm.splatRenderer { SplatSceneView(renderer: r, camera: vm.camera) }
            else if vm.item.splat == nil {
                Text("No splat for this scan yet (it is trained on the map server after the map is built)")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(40)
            }
        case .dollhouse:
            if let m = vm.dollhouseModel, let b = vm.bounds {
                DollhouseView(model: m, bounds: b, floorY: vm.floorY, state: vm.dollhouse, log: vm.log)
            } else {
                Text("The AR dollhouse needs the mesh; it is still loading")
                    .font(.callout).foregroundStyle(.secondary).padding(40)
            }
        case .overlay:
            OverlayStubView()
        }
    }

    @ViewBuilder private var minimap: some View {
        if vm.mode.is3D, vm.nav != .orbit, let li = vm.levelIndex, let e = vm.plans.ready[li] {
            if vm.showMinimap {      // 9.9: small, collapsible (the ✕ folds it into a map button)
                MinimapView(plan: e.plan, image: e.image, tracker: vm.tracker, rooms: vm.labels.rooms.rooms,
                            labels: vm.labels.mapLabels) { vm.goPlan($0) }
                    .frame(width: 108, height: 108)
                    .overlay(alignment: .topTrailing) {
                        Button { vm.showMinimap = false } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain).padding(3)
                        .accessibilityLabel("Hide the map")
                    }
            } else {
                Button { vm.showMinimap = true } label: {
                    Image(systemName: "map").font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the map")
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(vm.item.title).font(.headline).lineLimit(1)
                    Text([vm.item.subtitle, vm.memText.isEmpty ? nil : "mem \(vm.memText)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer()
                if vm.labels.saving { ProgressView() }
            }
            Picker("View", selection: Binding(get: { vm.mode }, set: { vm.setMode($0) })) {
                ForEach(ScanViewMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusCard(_ t: String) -> some View {
        VStack(spacing: 8) {
            Text(t).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
            if let p = vm.progress { ProgressView(value: p) } else { ProgressView() }
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var hintText: String {
        if vm.labeling { return vm.mode.meshGeometry ? "Tap a spot to pin a label or name its room" : "Labels need the mesh: Mesh or Hybrid" }
        if vm.measuring { return "Tap A then B on the mesh" }
        switch vm.nav {
        case .orbit: return "Drag: orbit · two fingers: pan · pinch: zoom · double-tap: focus"
        case .fly:
            return vm.flyScheme == .minimal
                ? "Stick: move · drag: look · ▲▼ height · double-tap: go there"
                : "Left stick: fly · right stick: look · ▲▼ height · Ghost: through walls"
        }
    }

    private var navBar: some View {
        VStack(spacing: 6) {
            if vm.mode.drawsSplat, !vm.splatInfo.isEmpty {
                Text(vm.splatInfo + (vm.mode == .hybrid ? " · mesh = geometry (walls, labels, measure)" : " · visuals only, measure on the mesh"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(spacing: 8) {
                Picker("Navigate", selection: $vm.nav) {
                    ForEach(NavMode.allCases) { n in Image(systemName: n.icon).tag(n) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 100)
                if vm.nav == .fly {      // 9.9: Simple (default) ⇄ Advanced dual-stick drone
                    Toggle(isOn: Binding(get: { vm.flyScheme == .advanced },
                                         set: { vm.flyScheme = $0 ? .advanced : .minimal })) {
                        Image(systemName: "gamecontroller")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("Advanced drone controls")
                }
                if !vm.walkPoints.isEmpty {
                    Button { vm.stepWalk(-1) } label: { Image(systemName: "chevron.left") }
                    Button { vm.stepWalk(0) } label: {
                        Text(vm.walkIndex.map { "\($0 + 1)/\(vm.walkPoints.count)" } ?? "Walk pts").monospacedDigit()
                    }
                    Button { vm.stepWalk(1) } label: { Image(systemName: "chevron.right") }
                }
                Spacer(minLength: 0)
                Button { vm.resetView() } label: { Image(systemName: "scope") }
            }
            HStack(spacing: 12) {
                if vm.mode.meshGeometry {
                    Toggle(isOn: $vm.measuring) { Image(systemName: "ruler") }.toggleStyle(.button)
                }
                if vm.labelsEnabled {
                    Toggle(isOn: $vm.labeling) { Label("Label", systemImage: "tag") }.toggleStyle(.button)
                    Button { vm.showList = true } label: { Image(systemName: "list.bullet") }
                    Button { vm.openRooms(.browse) } label: { Image(systemName: "square.dashed") }
                        .disabled(vm.plans.floors.isEmpty)
                    LabelFilterMenu(overlay: vm.overlay)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            Text(hintText).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Which billboards to show (its own view: the overlay model changes at frame rate, the viewer should not).
private struct LabelFilterMenu: View {
    @ObservedObject var overlay: LabelOverlayModel

    var body: some View {
        Menu {
            Picker("Labels", selection: $overlay.filter) {
                ForEach(LabelOverlayModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: { Image(systemName: overlay.filter == .off ? "eye.slash" : "eye") }
    }
}

private struct DollhouseBar: View {
    @ObservedObject var state: DollhouseState

    var body: some View {
        HStack {
            Text(state.hint).font(.caption).lineLimit(2)
            Spacer()
            if !state.scaleText.isEmpty { Text(state.scaleText).font(.headline).monospacedDigit() }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
