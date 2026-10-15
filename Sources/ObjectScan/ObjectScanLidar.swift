// 9.3 "Object scan (high-res)" → Quick LiDAR: the owner places a 3D box around the object in AR (Object Capture's
// UI pattern: set the floor, tap the object, adjust W/D/H + rotation + nudges), then records with SnailSight's own
// recorder in the object profile (ObjectProfile: dense 1920×1440 keyframes). capture.json carries `object_box`
// (ARKit world, SnailSightCore.ObjectBox.json); the map server fuses the depth inside the box (TSDF, 4 mm voxels, floor
// cut, docs/SNAILSIGHT-API.md §9). The capture is `objl-<UTC>` and uploads to /v1/objects, never /v1/sessions.
// 9.4 (owner's first real scan, 2026-10-13): Place box AUTO-FITS the box to the object under the crosshair from the
// LiDAR scene mesh (SnailSightCore.ObjectAutoFit: support surface = the table / shelf / floor around the object, box
// bottom on it, size from the object's points + 3 cm); "Set surface" + the old placement remain as the fallback. The
// name starts empty and is required; the robot tag starts OFF (nothing is persisted between scans).
import ARKit
import RealityKit
import SwiftUI
import SnailSightCore

/// Object-scan UI state (observed by ObjectScanOverlay; AppModel owns one).
final class ObjectScanState: ObservableObject {
    @Published var showChooser = false
    @Published var name: String = ObjectNameRule.defaultName           // required, asked every scan
    @Published var robotTag: Bool = ObjectNameRule.defaultRobotTag     // off unless the owner turns it on
    @Published var photo: PhotoScanController?
    @Published var lidarActive = false          // box placement / LiDAR object recording in the main AR view
    @Published var floorY: Float?
    @Published var box: ObjectBox?

    var tags: [String] { robotTag ? ["robot"] : [] }
    var objectName: String { ObjectNameRule.clean(name) }
    var hasName: Bool { ObjectNameRule.isValid(name) }

    /// A new scan: empty name, robot tag off (the old defaults sent a mini PC to the robot page as "RoboSnailBob").
    func resetForNewScan() {
        name = ObjectNameRule.defaultName
        robotTag = ObjectNameRule.defaultRobotTag
    }
}

/// Draws the AR box (12 cyan edges) and answers taps while the LiDAR object mode is placing it.
final class ObjectBoxController {
    private let arView: ARView
    private unowned let model: AppModel
    private var anchor: AnchorEntity?
    private var floorMarker: AnchorEntity?

    init(model: AppModel, arView: ARView) {
        self.model = model
        self.arView = arView
    }

    private var scan: ObjectScanState { model.objectScan }
    private var centre: CGPoint { CGPoint(x: arView.bounds.midX, y: arView.bounds.midY) }

    /// Tap while placing = Place box at the tapped point (auto-fit; the surface is found under it).
    func handleTap(_ pt: CGPoint) {
        guard !model.recording else { return }
        placeBox(at: pt)
    }

    func setFloor(at pt: CGPoint? = nil) {
        guard let hit = arView.raycast(from: pt ?? centre, allowing: .estimatedPlane, alignment: .horizontal).first else {
            model.flash("No floor there yet: sweep the phone over the floor next to the object")
            return
        }
        let p = Geo.position(hit.worldTransform)
        scan.floorY = p.y
        if var b = scan.box { b.floorY = p.y; update(b) }
        showFloorMarker(at: p)
        model.log.event("object_floor", ["y": .double(Double(p.y))])
        model.flash("Surface set ✓ Now aim at the object and tap it (or Place box)")
    }

    func placeBox(at pt: CGPoint? = nil) {
        guard let hit = arView.raycast(from: pt ?? centre, allowing: .estimatedPlane, alignment: .any).first else {
            model.flash("Nothing there yet: sweep the phone over the object first")
            return
        }
        let w = hit.worldTransform
        let hp = Geo.position(w)
        let cam = arView.cameraTransform.translation
        let t0 = CFAbsoluteTimeGetCurrent()
        let pts = meshPoints(near: hp, radius: ObjectAutoFit.searchRadius)
        if let f = ObjectAutoFit.fit(points: pts, hit: hp, camera: cam) {
            scan.floorY = f.supportY
            showFloorMarker(at: SIMD3(f.box.center.x, f.supportY, f.box.center.z))
            update(f.box)
            let b = f.box
            model.log.event("object_box", ["center": .doubles([Double(b.center.x), Double(b.center.y), Double(b.center.z)]),
                                           "size": .doubles([Double(b.size.x), Double(b.size.y), Double(b.size.z)]),
                                           "yaw_deg": .double(Double(b.yawDeg)), "fit": .string("auto"),
                                           "support_y": .double(Double(f.supportY)), "sides": .int(f.sides),
                                           "mesh_points": .int(pts.count),
                                           "ms": .double(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())])
            model.flash("Box fitted ✓ \(b.label) on the surface under it. Adjust if needed, then Start")
            return
        }
        model.log.event("object_box_fit_failed", ["mesh_points": .int(pts.count)])
        guard let floor = scan.floorY else {
            model.flash("Could not find the surface under it: aim at the table / floor beside it and tap Set surface", seconds: 4)
            return
        }
        let b = ObjectBox.place(hit: Geo.position(w), normal: Geo.normal(w), camera: arView.cameraTransform.translation,
                                floorY: floor, size: scan.box?.size ?? ObjectBox.defaultSize)
        update(b)
        model.log.event("object_box", ["center": .doubles([Double(b.center.x), Double(b.center.y), Double(b.center.z)]),
                                       "size": .doubles([Double(b.size.x), Double(b.size.y), Double(b.size.z)]),
                                       "yaw_deg": .double(Double(b.yawDeg))])
    }

    /// Scene-mesh surface samples (world) within `radius` (XZ) of `c`: every mesh triangle near it, sampled every
    /// ~2 cm (ARKit's mesh keeps few vertices on flat tables / floors, which the support search needs).
    func meshPoints(near c: SIMD3<Float>, radius: Float) -> [SIMD3<Float>] {
        guard let frame = arView.session.currentFrame else { return [] }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        var out: [SIMD3<Float>] = []
        let r2 = (radius + 0.1) * (radius + 0.1)
        for a in anchors {
            let g = a.geometry
            let T = a.transform
            let vb = g.vertices.buffer.contents()
            var V = [SIMD3<Float>](repeating: .zero, count: g.vertices.count)
            for i in 0..<g.vertices.count {
                let p = vb.advanced(by: g.vertices.offset + g.vertices.stride * i).assumingMemoryBound(to: Float.self)
                let w = T * SIMD4<Float>(p[0], p[1], p[2], 1)
                V[i] = SIMD3(w.x, w.y, w.z)
            }
            let f = g.faces
            guard f.indexCountPerPrimitive == 3 else { continue }
            let fb = f.buffer.contents()
            for k in 0..<f.count {
                func idx(_ j: Int) -> Int {
                    let o = (k * 3 + j) * f.bytesPerIndex
                    return f.bytesPerIndex == 4 ? Int(fb.load(fromByteOffset: o, as: UInt32.self))
                                                : Int(fb.load(fromByteOffset: o, as: UInt16.self))
                }
                let p0 = V[idx(0)], p1 = V[idx(1)], p2 = V[idx(2)]
                let m = (p0 + p1 + p2) / 3
                let dx = m.x - c.x, dz = m.z - c.z
                guard dx * dx + dz * dz <= r2 else { continue }
                let e = max(simd_distance(p0, p1), simd_distance(p1, p2), simd_distance(p2, p0))
                let n = max(1, min(30, Int((e / 0.02).rounded(.up))))
                for i in 0...n { for j in 0...(n - i) {
                    let u = Float(i) / Float(n), v = Float(j) / Float(n)
                    out.append(p0 + (p1 - p0) * u + (p2 - p0) * v)
                } }
            }
            if out.count > 400_000 { break }
        }
        return out
    }

    func update(_ b: ObjectBox) {
        let c = b.clamped()
        scan.box = c
        render(c)
    }

    func clear() {
        anchor?.removeFromParent(); anchor = nil
        floorMarker?.removeFromParent(); floorMarker = nil
        scan.box = nil
        scan.floorY = nil
    }

    private func render(_ b: ObjectBox) {
        anchor?.removeFromParent()
        let a = AnchorEntity(world: .zero)
        let mat = UnlitMaterial(color: UIColor(red: 0.2, green: 0.9, blue: 1.0, alpha: 1))
        let corners = b.corners
        for (i, j) in ObjectBox.edges {
            let p = corners[i], q = corners[j]
            let len = simd_distance(p, q)
            guard len > 1e-4 else { continue }
            let e = ModelEntity(mesh: .generateBox(size: SIMD3(0.006, 0.006, len)), materials: [mat])
            e.position = (p + q) / 2
            e.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: simd_normalize(q - p))
            a.addChild(e)
        }
        arView.scene.addAnchor(a)
        anchor = a
    }

    private func showFloorMarker(at p: SIMD3<Float>) {
        floorMarker?.removeFromParent()
        let a = AnchorEntity(world: p)
        let disc = ModelEntity(mesh: .generateBox(size: SIMD3(0.12, 0.002, 0.12), cornerRadius: 0.06),
                               materials: [UnlitMaterial(color: UIColor(red: 0.2, green: 0.9, blue: 1.0, alpha: 0.6))])
        a.addChild(disc)
        arView.scene.addAnchor(a)
        floorMarker = a
    }
}

/// Everything object-scan on the main screen: chooser sheet, Quick LiDAR box panel + reticle, Photo full-screen flow.
struct ObjectScanOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var scan: ObjectScanState

    var body: some View {
        ZStack {
            Color.clear.allowsHitTesting(false)          // hosts the sheet / cover; touches pass through to AR + HUD
            if scan.lidarActive && !model.recording {
                Image(systemName: "viewfinder").font(.system(size: 34, weight: .light)).foregroundStyle(.cyan)
                    .shadow(radius: 2).allowsHitTesting(false)
                VStack {
                    lidarPanel.padding(.top, 52)        // 9.8: below the slim status pill
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
        }
        .sheet(isPresented: $scan.showChooser) { chooser.presentationDetents([.medium, .large]) }
        .fullScreenCover(isPresented: Binding(get: { scan.photo != nil }, set: { if !$0 { model.endPhotoScan(upload: false) } })) {
            if let c = scan.photo { PhotoCaptureView(c: c) }
        }
    }

    private var chooser: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (required), e.g. NAD9 mini PC", text: $scan.name)
                    Toggle("Send to the robot page (tag robot)", isOn: $scan.robotTag)
                } header: { Text("Object") } footer: {
                    Text(scan.hasName ? "Object scans stay out of the house map: no rooms, floor plan or sim export. They show in the viewer's Objects page. Robot tag only for robot parts."
                                      : "Give the object a name first.")
                }
                Section {
                    Button { scan.showChooser = false; model.beginPhotoScan() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ObjectScanMode.photo.title).fontWeight(.semibold)
                            Text("Apple's guided capture: fit the box, walk round (low + high pass); the phone builds a textured model (a few minutes), then it uploads. Best detail.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!PhotoScanController.isSupported || !scan.hasName)
                    Button { scan.showChooser = false; model.beginLidarObjectScan() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ObjectScanMode.lidar.title).fontWeight(.semibold)
                            Text("Aim at it: the box fits itself on the table / floor under it; record while walking round slowly at 0.3–1.5 m; the map server fuses the LiDAR depth (2.5–4 mm). No wait on the phone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!scan.hasName)
                } header: { Text("How") } footer: {
                    if !PhotoScanController.isSupported { Text("Object Capture is not supported on this device.") }
                }
            }
            .navigationTitle("Object scan (high-res)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { scan.showChooser = false } } }
        }
    }

    private var lidarPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Object scan · Quick LiDAR").font(.headline)
                Spacer()
                Button { model.cancelLidarObjectScan() } label: { Image(systemName: "xmark.circle.fill") }
            }
            if scan.box == nil {
                Text("1. Sweep over the object and the surface it stands on, aim the crosshair at the object, then tap Place box (or tap the object). The box fits itself and sits on the table / floor under it.").font(.callout)
                HStack {
                    Button { model.controller.objectBox.setFloor() } label: { wide(scan.floorY == nil ? "Set surface" : "Reset surface") }
                        .buttonStyle(.bordered)
                    Button { model.controller.objectBox.placeBox() } label: { wide("Place box") }.buttonStyle(.borderedProminent)
                }
                Text("Set surface: only if Place box cannot find it (aim at the table / floor beside the object).")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let b = scan.box {
                Text("2. Check the box holds the whole object and nothing else, \(b.label)").font(.callout)
                slider("Width", b.size.x) { v in var n = b; n.size.x = v; return n }
                slider("Depth", b.size.z) { v in var n = b; n.size.z = v; return n }
                slider("Height", b.size.y) { v in var n = b; n.size.y = v; return n }
                HStack {
                    Text("Turn").font(.caption).frame(width: 52, alignment: .leading)
                    Slider(value: Binding(get: { Double(b.yawDeg) }, set: { v in var n = b; n.yawDeg = Float(v); model.controller.objectBox.update(n) }),
                           in: -180...180)
                }
                HStack(spacing: 6) {
                    nudge("arrow.left", dx: -0.02, dz: 0); nudge("arrow.right", dx: 0.02, dz: 0)
                    nudge("arrow.up", dx: 0, dz: -0.02); nudge("arrow.down", dx: 0, dz: 0.02)
                    Button { model.controller.objectBox.placeBox() } label: { Image(systemName: "scope") }.buttonStyle(.bordered)
                }
                TextField("Object name (required)", text: $scan.name).textFieldStyle(.roundedBorder)
                Button { model.startLidarObjectRecording() } label: {
                    Label("Start object scan", systemImage: "record.circle").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.red).disabled(!scan.hasName)
                Text("Walk slowly round at arm's length (0.3–1.5 m): one low pass for the wheels, one high pass for the top. Then Stop.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func slider(_ label: String, _ value: Float, _ make: @escaping (Float) -> ObjectBox) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { model.controller.objectBox.update(make(Float($0))) }),
                   in: Double(ObjectBox.minSide)...2.0)
            Text(String(format: "%.2f", value)).font(.caption).monospacedDigit().frame(width: 40)
        }
    }

    private func nudge(_ icon: String, dx: Float, dz: Float) -> some View {
        Button {
            if let b = scan.box { model.controller.objectBox.update(b.nudged(dx: dx, dz: dz)) }
        } label: { Image(systemName: icon).frame(maxWidth: .infinity) }
        .buttonStyle(.bordered)
    }

    private func wide(_ t: String) -> some View { Text(t).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 4) }
}

// MARK: - AppModel: object scan flows

extension AppModel {
    /// Photo-quality: pause SnailSight's AR session (Object Capture runs its own) and present Apple's guided capture.
    @MainActor func beginPhotoScan() {
        guard !recording else { flash("Stop the recording first"); return }
        guard objectScan.hasName else { flash("Name the object first"); return }
        guard PhotoScanController.isSupported else { flash("Object Capture is not supported on this iPhone"); return }
        guard let root = CaptureRecorder.capturesDirectory else { flash("No Documents folder"); return }
        let id = ObjectNaming.clientObjectID(mode: .photo, start: Date())
        let meta: [String: Any] = ["agent_id": agentID, "agent_type": Identity.agentType, "app_version": version,
                                   "device": DebugLog.deviceModel]
        let lg = log
        let c = PhotoScanController(id: id, dir: root.appendingPathComponent(id), name: objectScan.objectName,
                                    tags: objectScan.tags, meta: meta, log: { ev, data in lg.event(ev, data) })
        c.onEnd = { [weak self] ready in self?.endPhotoScan(upload: ready) }
        if simOn { simOn = false }
        controller.suspendForObjectCapture()
        objectScan.photo = c
        c.start()
        log.event("object_scan_begin", ["id": .string(id), "mode": .string("photo"), "name": .string(objectScan.objectName),
                                        "tags": .string(objectScan.tags.joined(separator: ","))])
    }

    /// End of the photo flow (Done, Cancel or the cover dismissed): resume AR; upload when a folder is ready.
    @MainActor func endPhotoScan(upload: Bool) {
        guard let c = objectScan.photo else { return }
        objectScan.photo = nil
        controller.resumeAfterObjectCapture()
        let dir = c.dir
        let hasDoc = FileManager.default.fileExists(atPath: dir.appendingPathComponent("object.json").path)
        guard hasDoc else {                              // cancelled / nothing usable: no upload
            try? FileManager.default.removeItem(at: dir)
            return
        }
        enqueueObject(id: c.id, dir: dir)
        objectScan.resetForNewScan()
    }

    func beginLidarObjectScan() {
        guard !recording else { flash("Stop the recording first"); return }
        if simOn { simOn = false }
        guard objectScan.hasName else { flash("Name the object first"); return }
        controller.objectBox.clear()
        objectScan.lidarActive = true
        hudCollapsed = true
        log.event("object_scan_begin", ["mode": .string("lidar"), "name": .string(objectScan.objectName)])
        flash("Aim at the object, then Place box")
    }

    func cancelLidarObjectScan() {
        controller.objectBox.clear()
        objectScan.lidarActive = false
        hudCollapsed = false
    }

    func startLidarObjectRecording() {
        guard let b = objectScan.box else { flash("Place the box first"); return }
        guard objectScan.hasName else { flash("Name the object first"); return }
        let spec = ObjectRecordingSpec(id: ObjectNaming.clientObjectID(mode: .lidar, start: Date()),
                                       meta: ["object_box": b.json, "profile": "object", "object_name": objectScan.objectName,
                                              "object_tags": objectScan.tags])
        startRecording(object: spec)
    }

    /// After Stop of a LiDAR object recording (AppModel.stopRecording): the box goes away; the upload is queued there.
    func lidarObjectRecordingStopped() {
        objectScan.resetForNewScan()
        controller.objectBox.clear()
        objectScan.lidarActive = false
        hudCollapsed = false
    }

    func enqueueObject(id: String, dir: URL) {
        let files = (try? PartPlanner.listFiles(in: dir)) ?? []
        let bytes = files.reduce(0) { $0 + $1.size }
        let s = CaptureSummary(clientSessionID: id, directory: dir, frames: files.filter { $0.path.hasPrefix("images/") }.count,
                               bytes: bytes, dropped: 0)
        log.event("object_enqueue", ["id": .string(id), "mb": .double(Double(bytes) / 1_048_576), "files": .int(files.count)])
        flash("Object scan saved · uploading to the map server", seconds: 4)
        let q = queue!
        Task {
            await q.enqueue(s)
            await q.kick(reason: "object")
        }
    }
}

/// A LiDAR object recording: its capture id (objl-…) and the extra capture.json keys (object_box, profile, name, tags).
struct ObjectRecordingSpec {
    var id: String
    var meta: [String: Any]
}
