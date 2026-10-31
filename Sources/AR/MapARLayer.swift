// 11.0 (live shared-map plan M2): the house itself is drawn from streamed per-tile USDZ (TileStreamer, `tileNode`)
// after the lock: Model = the textured tiles (default), Wire / Ghost = their materials on the same tiles. The
// whole-house collision.obj is no longer downloaded for drawing (only for the Sim X-ray occluder, after a lock, while
// X-ray is on). Rooms / objects docs are fetched only after a lock too: no map bytes before the lock.
// 10.7: the version drawn follows the house map's newest READY version (MapFollower, plan M1); a newer mesh swaps in
// at a still moment.
// SnailSight 10.1 "AR 1:1" (plan §7 P2 finish + P4 in AR): once LOCALIZED against the house map (MapLocalizer,
// /v1/localize), the master map's content is drawn where it really is: the version's mesh (dimmed wireframe or a
// faint ghost), room names, and the P4 detected objects (box outlines + labels). Tap tool "Objects" + tap a box to
// rename it or delete a false positive (API §8.6 PATCH / DELETE, 409 → re-read + retry once).
//
// Everything hangs under ONE entity (`root`) whose transform is T_arkit_map; children use MAP coordinates (Z-up
// metres) directly. A new lock / refinement never moves `root` at once: SnailSightCore.AlignBlender eases the shown
// alignment to the new one about the camera (≤ 0.5 m/s, ≤ 20°/s) and snaps (with a short fade) only for a relock
// > 2 m / 30° away. Nothing is drawn before a lock (never at a guessed place) or while ARKit relocalizes.
// Terrain (TerrainARLayer), other agents + live tiles (LiveMapClient) and the shared sim (ServerSimClient) attach to
// this root too, so one blend moves them all.
import ARKit
import RealityKit
import UIKit
import SnailSightCore

enum HouseStyle: String, CaseIterable, Identifiable {
    case off = "Off", labels = "Labels", model = "Model", wire = "Wire", ghost = "Ghost"
    var id: String { rawValue }
}

/// 12.1 live mesh tile look: photo colour (per-vertex RGB from the server, flat per triangle in AR) or wireframe.
enum MeshColour: String, CaseIterable, Identifiable {
    case photo = "Photo", wireframe = "Wireframe"
    var id: String { rawValue }
}

/// The detected object the owner tapped (AR correction sheet).
struct ARObjectEdit: Identifiable, Equatable {
    let id: String
    let scene: String
    let label: String
    let name: String
    let confidence: Double?
    let manual: Bool
}

extension Mat4 {
    /// simd matrix (RealityKit / ARKit), from the row-major wire form.
    var simdMatrix: simd_float4x4 {
        let f = columnsMajor
        return simd_float4x4(columns: (SIMD4<Float>(f[0], f[1], f[2], f[3]), SIMD4<Float>(f[4], f[5], f[6], f[7]),
                                       SIMD4<Float>(f[8], f[9], f[10], f[11]), SIMD4<Float>(f[12], f[13], f[14], f[15])))
    }
}

final class MapARLayer {
    private unowned let model: AppModel
    private let arView: ARView
    let root = AnchorEntity(world: matrix_identity_float4x4)
    /// Child of `root` carrying T_arkit_map (the anchor itself stays at identity, as MeshOverlay / SimController do).
    private let mapFrame = Entity()
    private let labelNode = Entity()
    private let objectNode = Entity()
    /// Other layers draw in the map frame under these.
    let terrainNode = Entity()
    let pathNode = Entity()
    let agentNode = Entity()
    let liveNode = Entity()
    let simNode = Entity()
    /// 12.2 Mark camera: the marks' rays, the triangulated point + its uncertainty ring.
    let markNode = Entity()
    /// 12.6 articulated door leaves (DoorStore) at their latest angle, with a state label above each.
    let doorNode = Entity()
    /// 12.18 Layer A: the robots' obstacle view (NavLayerClient), flat on each storey floor.
    let navNode = Entity()
    /// 12.18 Layer B: live block-mesh surface (LayerBClient).
    let blockNode = Entity()
    /// 12.22 islands: their own anchor (an island you are in draws in its own frame, without the house lock).
    let islandRoot = AnchorEntity(world: matrix_identity_float4x4)
    private var doorRev = -1
    private var doorLabels: [Entity] = []

    private var blender = AlignBlender()
    private(set) var shown: Align4?
    private var lastFrameT: TimeInterval?
    private var lastSlow: TimeInterval = 0
    private var hiddenUntil: TimeInterval = 0
    private(set) var camWorld = SIMD3<Float>(0, 0, 0)
    private(set) var status = ARMapStatus(tone: .neutral, title: "", detail: "", opacity: 0)
    /// L3: the live graph's correction for this phone's stream (T_map_arkit), used only while the localizer has no lock.
    private var liveAlign: (align: Align4, at: Double, stream: String)?

    // content of the current scene ("site@10")
    private(set) var sceneID: String?
    private var loadingScene: String?
    private(set) var objectsDoc: ARObjectsDoc?
    private(set) var roomsDoc: ARRoomsDoc?
    private(set) var floorZ: Double?
    private var boxes: [ARBoxItem] = []
    private var labelItems: [ARLabelItem] = []
    private var labelEntities: [String: Entity] = [:]
    private var boxEntities: [String: Entity] = [:]
    private var loadTask: Task<Void, Never>?
    private var lastLoadTry: TimeInterval = 0

    static let labelRange: Double = 7
    static let maxLabels = 30
    static let boxRange: Double = 6
    static let maxBoxes = 25
    /// 11.0: the streamed house tiles (Model / Wire / Ghost) under the map frame.
    private(set) lazy var tiles = TileStreamer(model: model, layer: self)
    /// 12.18: the device surface is truth near you (stored faces this phone has seen are hidden).
    private(set) lazy var surface = DeviceSurface(model: model)
    private(set) var camForwardWorld = SIMD3<Float>(0, 0, -1)

    lazy var wireMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1))
        if #available(iOS 18.0, *) {
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: 0.2)
        } else {
            m.blending = .transparent(opacity: 0.08)
        }
        return m
    }()
    lazy var ghostMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1))
        m.blending = .transparent(opacity: 0.12)
        return m
    }()

    /// 12.21 Live map view: stored tiles as a dim neutral veil under the solid live surface.
    lazy var dimMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(white: 0.55, alpha: 1))
        m.blending = .transparent(opacity: 0.16)
        return m
    }()

    /// 12.21: Camera + device surface <-> Live map view.
    func lookChanged() {
        tiles.restyle()
    }

    init(model: AppModel, arView: ARView) {
        self.model = model
        self.arView = arView
        root.name = "map.root"
        root.addChild(mapFrame)
        for n in [labelNode, objectNode, terrainNode, pathNode, agentNode, liveNode, simNode, markNode, doorNode, navNode, blockNode] { mapFrame.addChild(n) }
        mapFrame.addChild(tiles.node)
        root.isEnabled = false
        arView.scene.addAnchor(root)
        islandRoot.name = "islands.root"
        islandRoot.isEnabled = false
        arView.scene.addAnchor(islandRoot)
    }

    // MARK: frames

    /// The alignment content should converge to: the localizer's lock, else a recent live-graph correction.
    private var target: Align4? {
        if let al = model.mapLocalizer.alignment { return Align4(al.T) }
        if let l = liveAlign, Date().timeIntervalSince1970 - l.at < 120 { return l.align }
        return nil
    }

    private var lockKind: ARMapStatus.Lock {
        if let al = model.mapLocalizer.alignment {
            return model.mapLocalizer.lockSource == "place_cache" ? .cached : .server(method: al.method)
        }
        return liveAlign == nil ? .none : .server(method: "live")
    }

    var mapVersion: Int? { model.mapLocalizer.alignment?.version ?? model.liveBaseVersion }
    var mapID: String { model.mapLocalizer.mapID }
    var isAligned: Bool { shown != nil && status.opacity > 0 }

    /// Every AR frame (main).
    func frame(_ f: ARFrame) {
        let t = f.timestamp
        let dt = lastFrameT.map { min(0.1, max(0, t - $0)) } ?? 0
        lastFrameT = t
        let c = f.camera.transform.columns.3
        camWorld = SIMD3<Float>(c.x, c.y, c.z)
        let fw = f.camera.transform.columns.2                   // the camera looks along -z
        camForwardWorld = SIMD3<Float>(-fw.x, -fw.y, -fw.z)
        let pivot = [Double(c.x), Double(c.y), Double(c.z)]
        let tg = target
        if tg != blender.target { blender.setTarget(tg) }
        if blender.step(dt: dt, pivot: pivot) {
            if blender.snapped { hiddenUntil = t + 0.35 }
            shown = blender.shown
            if let s = shown { mapFrame.transform = Transform(matrix: s.inverseMatrix.simdMatrix) }
        } else if tg == nil {
            shown = nil
        }
        if t - lastSlow >= 0.5 {
            lastSlow = t
            slowTick(pivot: pivot)
            surface.tick()
        }
        surface.frame(f, align: shown)
        let show = shown != nil && status.opacity > 0 && t >= hiddenUntil && !model.recording && !model.arSuspended
        if root.isEnabled != show { root.isEnabled = show }
        guard show else { return }
        for e in labelEntities.values.filter({ $0.isEnabled }) + model.liveMap.tagEntities + model.serverSim.tagEntities + doorLabels {
            let p = e.position(relativeTo: nil)
            e.setOrientation(Geo.billboardRotation(position: p, camera: camWorld), relativeTo: nil)
            let s = max(0.6, min(4, Geo.distance(p, camWorld)))
            e.setScale(SIMD3(repeating: s), relativeTo: nil)
        }
    }

    private func slowTick(pivot: [Double]) {
        let now = Date().timeIntervalSince1970
        let al = model.mapLocalizer.alignment
        var tracking = model.tracking.code
        if tracking == "limited:relocalizing" { tracking = "relocalizing" }
        let s = ARMapStatus.make(online: model.serverBase != nil, lock: lockKind, version: mapVersion, tracking: tracking,
                                 remainingCm: blender.remaining(pivot: pivot).cm,
                                 searchingS: model.mapLocalizer.searchSeconds, matches: model.mapLocalizer.matchCount,
                                 ageS: al.map { now - $0.at } ?? 0)
        status = s
        if model.arStatus != s { model.arStatus = s }
        // 10.7 follow LATEST (plan M1): the content version = the lock's version while it is not newer than the
        // followed head, else the head (MapFollower).
        // 11.0: only after a lock (no map bytes before it), and only the small docs (rooms, objects): the house mesh
        // itself streams as tiles (TileStreamer).
        // 12.4: no rooms / objects docs while the house is hidden (3D world off or House overlay Off) unless X-ray needs the scene.
        if al != nil, model.serverBase != nil, model.drawHouse != .off || model.simXRay, let v = model.mapFollower.contentVersion(lock: mapVersion) {
            let scene = "\(mapID)@\(v)"
            if scene != sceneID && loadingScene == nil && now - lastLoadTry > 10 { load(scene) }
        }
        guard let sh = shown else { return }
        let cam = sh.toMap(pivot)
        let ahead = sh.toMap([pivot[0] + Double(camForwardWorld.x), pivot[1] + Double(camForwardWorld.y),
                              pivot[2] + Double(camForwardWorld.z)])
        applyStyle()
        updateDoors()
        updateVisible(cam: cam)
        tiles.tick(cam: cam, forward: [ahead[0] - cam[0], ahead[1] - cam[1], ahead[2] - cam[2]])
        model.terrainLayer.tick(cameraMap: cam)
    }

    /// L3: the uplink got a correction for one of this phone's streams.
    func liveCorrection(T_map_arkit T: Mat4, stream: String, placed: Bool) {
        guard placed, stream == model.liveStreamer.streamID else { return }
        liveAlign = (Align4(T), Date().timeIntervalSince1970, stream)
    }

    /// The ARKit world frame changed: every alignment belongs to the old frame.
    func worldFrameChanged() {
        surface.worldReset()
        liveAlign = nil
        blender.reset()
        shown = nil
        root.isEnabled = false
    }

    // MARK: map ↔ world helpers (for the other layers)

    func toMap(world p: SIMD3<Float>) -> [Double]? {
        shown?.toMap([Double(p.x), Double(p.y), Double(p.z)])
    }

    func toWorld(map q: [Double]) -> SIMD3<Float>? {
        guard let s = shown else { return nil }
        let w = s.toArkit(q)
        return SIMD3<Float>(Float(w[0]), Float(w[1]), Float(w[2]))
    }

    /// The camera in the map frame.
    var cameraMap: [Double]? { toMap(world: camWorld) }

    /// A screen ray in the map frame (origin, unit direction).
    func mapRay(_ pt: CGPoint) -> (origin: [Double], direction: [Double])? {
        guard let s = shown, let r = arView.ray(through: pt) else { return nil }
        let o = s.toMap([Double(r.origin.x), Double(r.origin.y), Double(r.origin.z)])
        let e = s.toMap([Double(r.origin.x + r.direction.x), Double(r.origin.y + r.direction.y), Double(r.origin.z + r.direction.z)])
        return (o, [e[0] - o[0], e[1] - o[1], e[2] - o[2]])
    }

    // MARK: loading (rooms, objects, mesh) for one scene

    func reloadDocs() {
        guard let s = sceneID else { return }
        sceneID = nil
        load(s, docsOnly: true)
    }

    private func load(_ scene: String, docsOnly: Bool = false) {
        loadingScene = scene
        lastLoadTry = Date().timeIntervalSince1970
        let link = model.link!
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let enc = scene.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scene
            var rooms: ARRoomsDoc?
            var objects: ARObjectsDoc?
            if let r = try? await link.request("GET", "/v1/scenes/\(enc)/rooms", timeout: 20), r.1 == 200 {
                rooms = try? JSONDecoder().decode(ARRoomsDoc.self, from: r.0)
            }
            if let r = try? await link.request("GET", "/v1/scenes/\(enc)/objects", timeout: 30), r.1 == 200 {
                objects = try? JSONDecoder().decode(ARObjectsDoc.self, from: r.0)
            }
            var floor: Double?
            if let r = try? await link.request("GET", "/v1/phone/scans/\(enc)", timeout: 15), r.1 == 200 {
                floor = (JSON.object(r.0)["floor_z"] as? NSNumber)?.doubleValue
            }
            let roomsF = rooms, objectsF = objects, floorF = floor
            await MainActor.run {
                guard let self, self.loadingScene == scene else { return }
                self.loadingScene = nil
                self.sceneID = scene
                if let r = roomsF { self.roomsDoc = r }
                if let o = objectsF { self.objectsDoc = o }
                if let f = floorF { self.floorZ = f }
                self.rebuildItems()
                self.model.log.event("armap_load", ["scene": .string(scene), "rooms": .int(roomsF?.rooms.count ?? -1),
                                                    "objects": .int(objectsF?.objects.count ?? -1)])
            }
        }
    }

    // MARK: 10.8 X-ray: the house mesh as a CPU ray index (map frame) - is a sim body behind a wall?

    /// The newest house mesh as a ray index (nil until built; built only while Sim X-ray is on).
    private(set) var occluder: TriangleIndex?
    private var occluderScene: String?
    private var occluderLoading = false

    /// Build (in the background) the ray index of the shown scene's collision mesh, once per scene. 11.0: the ONLY use
    /// of collision.obj left: fetched after a server lock, while Sim X-ray is on (callers check the toggle).
    func ensureOccluder() {
        guard model.mapLocalizer.alignment != nil, let scene = sceneID, scene != occluderScene, !occluderLoading,
              let link = model.link else { return }
        occluderLoading = true
        let enc = scene.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scene
        Task { [weak self] in
            let data = await Self.meshData(scene: scene, enc: enc, link: link)
            let idx: TriangleIndex? = await Task.detached(priority: .utility) { () -> TriangleIndex? in
                guard let d = data else { return nil }
                let m = ObjReader.parse(d)
                guard m.triangleCount > 0 else { return nil }
                var pts = [SIMD3<Float>]()
                pts.reserveCapacity(m.vertexCount)
                var i = 0
                while i + 2 < m.positions.count {
                    pts.append(SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2]))
                    i += 3
                }
                return TriangleIndex(positions: pts, indices: m.indices)
            }.value
            await MainActor.run {
                guard let self else { return }
                self.occluderLoading = false
                self.occluderScene = scene
                self.occluder = idx
                self.model.log.event("sim_xray_occluder", ["scene": .string(scene), "triangles": .int(idx?.triangleCount ?? -1)])
            }
        }
    }

    /// Is the straight line from the camera to this map point blocked by the house mesh (a wall, a floor)?
    /// nil = no index yet. `margin`: ignore hits this close to the point (the body's own floor / furniture).
    func blocked(from cam: [Double], to p: [Double], margin: Float = 0.3) -> Bool? {
        guard let idx = occluder, cam.count >= 3, p.count >= 3 else { return nil }
        let o = SIMD3<Float>(Float(cam[0]), Float(cam[1]), Float(cam[2]))
        let d = SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p[2])) - o
        let dist = simd_length(d)
        guard dist > margin + 0.1 else { return false }
        return idx.raycast(origin: o, dir: d, maxT: dist - margin) != nil
    }

    /// The scene's collision.obj bytes (Caches/armap/ first, else downloaded and cached).
    private static func meshData(scene: String, enc: String, link: ServerLink) async -> Data? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("armap", isDirectory: true)
        else { return nil }
        let file = dir.appendingPathComponent(scene.replacingOccurrences(of: "@", with: "-v") + "-collision.obj")
        if let d = try? Data(contentsOf: file) { return d }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let r = try? await link.request("GET", "/v1/scenes/\(enc)/files/collision.obj", timeout: 90), r.1 == 200 else {
            return nil
        }
        try? r.0.write(to: file, options: .atomic)
        evictMeshCache(dir)
        return r.0
    }

    /// Keep only the newest 3 cached collision meshes (the X-ray occluder's cache).
    private static func evictMeshCache(_ dir: URL) {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let old = all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.dropFirst(3)
        for u in old { try? fm.removeItem(at: u) }
    }

    private func applyStyle() {
        let st = model.drawHouse                                  // 12.4: the 3D world switch hides labels + boxes too
        labelNode.isEnabled = st != .off
        objectNode.isEnabled = st != .off && model.arObjects
    }

    // MARK: 12.6 doors

    private func updateDoors() {
        let on = model.drawDoors
        if doorNode.isEnabled != on { doorNode.isEnabled = on }
        guard on else { return }
        model.doorStore.ensure()
        guard model.doorStore.rev != doorRev else { return }
        doorRev = model.doorStore.rev
        doorNode.children.removeAll()
        doorLabels = []
        for d in model.doorStore.leaves {
            doorNode.addChild(DoorMeshes.leaf(d))
            let l = makeLabel("\(d.id.replacingOccurrences(of: "door-", with: "")) \(d.label)", size: 0.04)
            l.position = SIMD3<Float>(Float(d.boxCenter[0]), Float(d.boxCenter[1]), Float(d.z0 + d.height + 0.2))
            doorNode.addChild(l)
            doorLabels.append(l)
        }
    }

    // MARK: labels + boxes

    private func rebuildItems() {
        for e in labelEntities.values { e.removeFromParent() }
        for e in boxEntities.values { e.removeFromParent() }
        labelEntities.removeAll()
        boxEntities.removeAll()
        var items: [ARLabelItem] = []
        if let r = roomsDoc { items += ARMapContent.roomLabels(r, defaultFloorZ: floorZ) }
        if let o = objectsDoc {
            boxes = ARMapContent.boxes(ARMapContent.visible(o))
            items += ARMapContent.objectLabels(boxes)
        } else {
            boxes = []
        }
        labelItems = items
    }

    private func updateVisible(cam: [Double]) {
        func d(_ p: [Double]) -> Double { hypot(p[0] - cam[0], p[1] - cam[1]) + abs(p[2] - cam[2]) * 0.5 }
        // labels: rooms always within range; objects only when the Objects layer is on
        let cand = labelItems.filter { ($0.kind == .room || model.arObjects) && d($0.position) <= Self.labelRange }
            .sorted { d($0.position) < d($1.position) }.prefix(Self.maxLabels)
        let want = Set(cand.map(\.id))
        for (id, e) in labelEntities { e.isEnabled = want.contains(id) }
        for it in cand where labelEntities[it.id] == nil {
            let e = makeLabel(it.text, size: it.kind == .room ? 0.05 : 0.028, room: it.kind == .room)
            e.position = SIMD3<Float>(Float(it.position[0]), Float(it.position[1]), Float(it.position[2]))
            labelNode.addChild(e)
            labelEntities[it.id] = e
        }
        // boxes
        let bc = model.arObjects ? boxes.filter { d($0.center) <= Self.boxRange }.sorted { d($0.center) < d($1.center) }
            .prefix(Self.maxBoxes) : []
        let wb = Set(bc.map(\.id))
        for (id, e) in boxEntities { e.isEnabled = wb.contains(id) }
        for b in bc where boxEntities[b.id] == nil {
            let e = boxOutline(b)
            objectNode.addChild(e)
            boxEntities[b.id] = e
        }
    }

    private func boxOutline(_ b: ARBoxItem) -> Entity {
        let holder = Entity()
        holder.position = SIMD3<Float>(Float(b.center[0]), Float(b.center[1]), Float(b.center[2]))
        holder.orientation = simd_quatf(angle: Float(b.yaw), axis: SIMD3<Float>(0, 0, 1))
        let mat = UnlitMaterial(color: b.movable ? UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1)
                                                 : UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 1))
        let sx = Float(b.size[0]), sy = Float(b.size[1]), sz = Float(b.size[2])
        let t: Float = 0.008
        for a in [Float(-1), 1] {
            for c in [Float(-1), 1] {
                let ex = ModelEntity(mesh: .generateBox(size: SIMD3(sx, t, t)), materials: [mat])
                ex.position = SIMD3(0, a * sy / 2, c * sz / 2)
                let ey = ModelEntity(mesh: .generateBox(size: SIMD3(t, sy, t)), materials: [mat])
                ey.position = SIMD3(a * sx / 2, 0, c * sz / 2)
                let ez = ModelEntity(mesh: .generateBox(size: SIMD3(t, t, sz)), materials: [mat])
                ez.position = SIMD3(a * sx / 2, c * sy / 2, 0)
                holder.addChild(ex); holder.addChild(ey); holder.addChild(ez)
            }
        }
        return holder
    }

    /// Camera-facing label (SceneRenderer.makeLabel style); rooms get a tinted plate.
    func makeLabel(_ text: String, size: CGFloat = 0.03, room: Bool = false) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.0005,
                                             font: .systemFont(ofSize: size, weight: room ? .bold : .semibold),
                                             containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
        let textEntity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let bounds = textEntity.visualBounds(relativeTo: nil)
        textEntity.position = SIMD3(-bounds.center.x, -bounds.center.y, 0.001)
        var plate = UnlitMaterial(color: room ? UIColor(red: 0.05, green: 0.25, blue: 0.35, alpha: 1) : .black)
        plate.blending = .transparent(opacity: 0.55)
        let bg = ModelEntity(mesh: .generatePlane(width: bounds.extents.x + Float(size) * 0.6,
                                                  height: bounds.extents.y + Float(size) * 0.4,
                                                  cornerRadius: Float(size) * 0.2),
                             materials: [plate])
        let holder = Entity()
        holder.addChild(bg)
        holder.addChild(textEntity)
        return holder
    }

    // MARK: P4 corrections

    /// Tool "Objects": a tap on a detected object opens its correction sheet. true = handled.
    /// 12.5 Select / Inspect: a tap on a drawn house object opens its sheet; false (silently) when nothing is hit.
    func inspectObject(_ pt: CGPoint) -> Bool {
        guard isAligned, model.arObjects, model.drawHouse != .off, let scene = sceneID,
              let ray = mapRay(pt), let cam = cameraMap else { return false }
        let near = boxes.filter { hypot($0.center[0] - cam[0], $0.center[1] - cam[1]) <= Self.boxRange + 2 }
        guard let hit = ARMapContent.pick(origin: ray.origin, direction: ray.direction, boxes: near),
              let o = objectsDoc?.objects.first(where: { $0.id == hit.id }) else { return false }
        model.log.event("armap_object_tap", ["id": .string(o.id), "label": .string(o.label), "m": .double(hit.distance),
                                             "via": .string("inspect")])
        model.arObjectEdit = ARObjectEdit(id: o.id, scene: scene, label: o.label, name: o.name ?? "",
                                          confidence: o.confidence, manual: o.isManual)
        return true
    }

    func handleObjectTap(_ pt: CGPoint) -> Bool {
        guard isAligned, model.arObjects, model.drawHouse != .off, let scene = sceneID else {
            model.flash(isAligned ? "Turn on More ▸ House ▸ Objects" : "Objects show once LOCALIZED in the house map")
            return true
        }
        guard let ray = mapRay(pt), let cam = cameraMap else { return true }
        let near = boxes.filter { hypot($0.center[0] - cam[0], $0.center[1] - cam[1]) <= Self.boxRange + 2 }
        guard let hit = ARMapContent.pick(origin: ray.origin, direction: ray.direction, boxes: near),
              let o = objectsDoc?.objects.first(where: { $0.id == hit.id }) else {
            model.flash("No detected object there")
            return true
        }
        model.log.event("armap_object_tap", ["id": .string(o.id), "label": .string(o.label), "m": .double(hit.distance)])
        model.arObjectEdit = ARObjectEdit(id: o.id, scene: scene, label: o.label, name: o.name ?? "",
                                          confidence: o.confidence, manual: o.isManual)
        return true
    }

    /// Rename (label = class, name = owner's name) or delete. nil = done, else an error for the sheet.
    func correct(_ edit: ARObjectEdit, label: String?, name: String?, delete: Bool) async -> String? {
        let link = model.link!
        let author = "snailsight-\(model.agentID)"
        var rev = objectsDoc?.revision
        for attempt in 0..<2 {
            let req = delete
                ? ObjectCorrectionRequest.delete(scene: edit.scene, id: edit.id, author: author, baseRevision: rev)
                : ObjectCorrectionRequest.rename(scene: edit.scene, id: edit.id, label: label, name: name, author: author,
                                                 baseRevision: rev)
            let q = req.query.map { URLQueryItem(name: $0.0, value: $0.1) }
            do {
                let (d, s) = try await link.request(req.method, req.path, query: q, body: req.body, timeout: 20)
                await MainActor.run {
                    self.model.log.event("armap_object_fix", ["id": .string(edit.id), "op": .string(delete ? "delete" : "rename"),
                                                         "status": .int(s), "attempt": .int(attempt)])
                }
                if s == 200 || s == 201 {
                    await MainActor.run { self.reloadDocs() }
                    return nil
                }
                if s == 409 && attempt == 0 {            // stale: re-read the revision, apply the one change again
                    let enc = edit.scene.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? edit.scene
                    if let r = try? await link.request("GET", "/v1/scenes/\(enc)/objects", timeout: 30), r.1 == 200 {
                        rev = (try? JSONDecoder().decode(ARObjectsDoc.self, from: r.0))?.revision
                    }
                    continue
                }
                return "Server said \(s): \(JSON.detail(d))"
            } catch {
                return error.localizedDescription
            }
        }
        return "Changed by someone else meanwhile; try again"
    }
}
