import ARKit
import RealityKit
import UIKit
import SnailSightCore

/// Placed content: 10 cm cubes (on ARAnchors so ARKit keeps refining them), the two-point measure and the
/// 1 m ruler, plus camera-facing labels. All sizes are real metres.
final class SceneRenderer {
    private let arView: ARView
    private var cubeAnchors: [UUID: (ARAnchor, AnchorEntity, SIMD3<Float>)] = [:]   // + placed position
    /// 9.5: per cube, the holder of cube + cross + label. While the sim is on it re-checks what holds the cube up and
    /// lowers this holder when the mesh under it goes away (SimController support physics); the ARAnchor stays put.
    private var cubeBodies: [UUID: Entity] = [:]
    private var otherAnchors: [(ARAnchor?, AnchorEntity)] = []
    private var billboards: [Entity] = []
    private var measure = TwoPointMeasure()
    private var pendingA: AnchorEntity?
    /// 9.9: numbering + order of the placed cubes (SnailSightCore.CubeLedger), the cube meshes (selection tint).
    private var ledger = CubeLedger<UUID>()
    private var cubeModels: [UUID: ModelEntity] = [:]
    private(set) var selectedCube: UUID?
    var onPlaced: ((Int) -> Void)?

    /// What it takes to put a deleted cube back (undo): its number and where its anchor is now.
    struct CubeSnapshot {
        let number: Int
        let transform: simd_float4x4
    }

    init(arView: ARView) { self.arView = arView }

    // MARK: cube

    func placeCube(hit: simd_float4x4, cameraPosition: SIMD3<Float>, session: ARSession) -> (Int, simd_float4x4) {
        let m = Geo.placementTransform(hit: hit, cameraPosition: cameraPosition)
        let n = addCube(number: nil, transform: m, session: session)
        return (n, m)
    }

    /// New cube (number nil = the next one) or a restored one (undo keeps its number).
    @discardableResult
    private func addCube(number: Int?, transform m: simd_float4x4, session: ARSession) -> Int {
        let a = ARAnchor(name: "snailsight.cube", transform: m)
        let n: Int
        if let number {
            n = number
            ledger.restore([CubeLedger<UUID>.Entry(id: a.identifier.uuidString, number: number, item: a.identifier)])
        } else {
            n = ledger.add(id: a.identifier.uuidString, item: a.identifier)
        }
        session.add(anchor: a)
        let ae = AnchorEntity(anchor: a)
        let body = Entity()
        ae.addChild(body)
        let cube = ModelEntity(mesh: .generateBox(size: 0.10),
                               materials: [SimpleMaterial(color: .systemRed, roughness: 0.6, isMetallic: false)])
        cube.position.y = 0.05                      // base sits on the surface
        body.addChild(cube)
        cubeModels[a.identifier] = cube
        // Base cross (16 cm, wider than the cube) so the centre can be lined up with a tape cross.
        let white = UnlitMaterial(color: .white)
        for size in [SIMD3<Float>(0.16, 0.002, 0.004), SIMD3<Float>(0.004, 0.002, 0.16)] {
            let bar = ModelEntity(mesh: .generateBox(size: size), materials: [white])
            bar.position.y = 0.001
            body.addChild(bar)
        }
        let label = makeLabel("#\(n) · 10 cm")
        label.position.y = 0.15
        body.addChild(label)
        arView.scene.addAnchor(ae)
        cubeAnchors[a.identifier] = (a, ae, Geo.position(m))
        cubeBodies[a.identifier] = body
        onPlaced?(cubeAnchors.count)
        return n
    }

    // MARK: 9.9 cube selection / deletion / undo

    /// Placed cubes in order: (anchor id, number).
    var cubes: [(id: UUID, number: Int)] { ledger.map { ($0.item, $0.number) } }

    func number(of id: UUID) -> Int? { ledger.entry(id.uuidString)?.number }

    /// The cube a world ray hits first (its 10 cm box, grown to a finger-sized pick box), nil = none.
    func pickCube(origin: SIMD3<Float>, direction: SIMD3<Float>) -> UUID? {
        var bodies: [PickBody] = []
        var ids: [UUID] = []
        for (k, (id, body)) in cubeBodies.enumerated() {
            let c = body.convert(position: SIMD3<Float>(0, 0.05, 0), to: nil)
            bodies.append(PickBody(id: k, center: SIMD3(Double(c.x), Double(c.y), Double(c.z)), size: SIMD3(0.12, 0.12, 0.12),
                                   yaw: 0))
            ids.append(id)
        }
        guard let k = SimPick.pick(origin: SIMD3(Double(origin.x), Double(origin.y), Double(origin.z)),
                                   dir: SIMD3(Double(direction.x), Double(direction.y), Double(direction.z)), bodies: bodies)
        else { return nil }
        return ids[k]
    }

    /// Cyan = selected, red = the rest.
    func selectCube(_ id: UUID?) {
        selectedCube = id.flatMap { cubeModels[$0] == nil ? nil : $0 }
        for (k, m) in cubeModels {
            m.model?.materials = [SimpleMaterial(color: k == selectedCube ? .systemCyan : .systemRed, roughness: 0.6,
                                                 isMetallic: false)]
        }
    }

    /// Delete cubes (anchors + entities); returns snapshots for undo.
    func removeCubes(_ ids: [UUID], session: ARSession) -> [CubeSnapshot] {
        var out: [CubeSnapshot] = []
        let gone = ledger.remove(Set(ids.map { $0.uuidString }))
        for e in gone {
            guard let entry = cubeAnchors[e.item] else { continue }
            let a = entry.0, ae = entry.1
            let t = session.currentFrame?.anchors.first { $0.identifier == a.identifier }?.transform ?? a.transform
            out.append(CubeSnapshot(number: e.number, transform: t))
            session.remove(anchor: a)
            arView.scene.removeAnchor(ae)
            cubeAnchors[e.item] = nil
            cubeBodies[e.item] = nil
            cubeModels[e.item] = nil
            if selectedCube == e.item { selectedCube = nil }
        }
        onPlaced?(cubeAnchors.count)
        return out
    }

    func removeAllCubes(session: ARSession) -> [CubeSnapshot] { removeCubes(ledger.map { $0.item }, session: session) }

    /// Undo: the cubes come back where they were, with their numbers.
    func restoreCubes(_ snaps: [CubeSnapshot], session: ARSession) {
        for s in snaps { addCube(number: s.number, transform: s.transform, session: session) }
    }

    /// Measures and rulers only (9.9: Clear cubes is separate).
    func clearMeasures(session: ARSession) {
        for (a, ae) in otherAnchors { if let a { session.remove(anchor: a) }; arView.scene.removeAnchor(ae) }
        if let pa = pendingA { arView.scene.removeAnchor(pa) }
        otherAnchors.removeAll()
        pendingA = nil
        measure.reset()
    }

    /// Cube holders for the sim's support re-checks (9.5).
    func supportBodies() -> [(UUID, Entity)] { cubeBodies.map { ($0.key, $0.value) } }

    /// How far ARKit has moved a cube's anchor since it was placed (metres), nil for non-cube anchors.
    func anchorShift(_ a: ARAnchor) -> Float? {
        guard let c = cubeAnchors[a.identifier] else { return nil }
        return Geo.distance(Geo.position(a.transform), c.2)
    }

    // MARK: two-point measure

    func measureTap(at p: SIMD3<Float>) -> TwoPointMeasure.Step {
        let step = measure.add(p)
        switch step {
        case .first(let a):
            let ae = AnchorEntity(world: a)
            ae.addChild(dot(color: .systemCyan))
            arView.scene.addAnchor(ae)
            pendingA = ae
        case .second(let a, let b, let d):
            let root = AnchorEntity(world: matrix_identity_float4x4)
            let db = dot(color: .systemCyan)
            db.position = b
            root.addChild(db)
            let s = Geo.segment(from: a, to: b)
            let line = ModelEntity(mesh: .generateBox(size: SIMD3(s.length, 0.003, 0.003)),
                                   materials: [UnlitMaterial(color: .systemCyan)])
            line.position = s.center
            line.orientation = s.rotation
            root.addChild(line)
            let label = makeLabel(Geo.centimetres(d))
            label.position = s.center + SIMD3(0, 0.04, 0)
            root.addChild(label)
            arView.scene.addAnchor(root)
            if let pa = pendingA { otherAnchors.append((nil, pa)) }
            pendingA = nil
            otherAnchors.append((nil, root))
        }
        return step
    }

    // MARK: 1 m ruler

    /// A 1.000 m ruler lying on the tapped surface, 0 at the tap, running away from the user, ticks every 10 cm.
    func placeRuler(hit: simd_float4x4, cameraForward: SIMD3<Float>, session: ARSession) -> simd_float4x4? {
        guard let f = Geo.rulerFrame(origin: Geo.position(hit), normal: Geo.normal(hit), cameraForward: cameraForward)
        else { return nil }
        let a = ARAnchor(name: "snailsight.ruler", transform: f)
        session.add(anchor: a)
        let ae = AnchorEntity(anchor: a)
        let bar = ModelEntity(mesh: .generateBox(size: SIMD3(1.0, 0.002, 0.012)),
                              materials: [UnlitMaterial(color: .systemYellow)])
        bar.position = SIMD3(0.5, 0.001, 0)
        ae.addChild(bar)
        let black = UnlitMaterial(color: .black)
        for t in Geo.ticks(length: 1.0, spacing: 0.1) {
            let major = Int((t * 100).rounded()) % 50 == 0
            let tick = ModelEntity(mesh: .generateBox(size: SIMD3(0.002, 0.003, major ? 0.03 : 0.018)),
                                   materials: [black])
            tick.position = SIMD3(t, 0.0025, 0)
            ae.addChild(tick)
        }
        for (x, text) in [(Float(0), "0"), (Float(0.5), "50"), (Float(1.0), "100 cm")] {
            let l = makeLabel(text, size: 0.02)
            l.position = SIMD3(x, 0.03, 0)
            ae.addChild(l)
        }
        arView.scene.addAnchor(ae)
        otherAnchors.append((a, ae))
        return f
    }

    // MARK: 12.5 temporary measure points (Select / Inspect: a tap on a surface)

    private var probeRoot: AnchorEntity?
    private var probeKey = ""

    /// Draw the live measure points (world frame): a small marker each, a line between a pair, the readout above the
    /// newest point; `opacity` fades them out. Empty = remove.
    func setMeasurePoints(_ pts: [SIMD3<Float>], label: String?, opacity: Float) {
        if pts.isEmpty || opacity <= 0 {
            if let r = probeRoot { arView.scene.removeAnchor(r) }
            probeRoot = nil
            probeKey = ""
            return
        }
        let key = pts.map { String(format: "%.3f,%.3f,%.3f", $0.x, $0.y, $0.z) }.joined(separator: ";") + "|" + (label ?? "")
        if key != probeKey {
            if let r = probeRoot { arView.scene.removeAnchor(r) }
            let root = AnchorEntity(world: matrix_identity_float4x4)
            let mat = UnlitMaterial(color: .systemOrange)
            for p in pts {
                let m = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [mat])
                m.position = p
                root.addChild(m)
                var ringMat = UnlitMaterial(color: .white)
                ringMat.blending = .transparent(opacity: 0.6)
                let ring = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: 0.03), materials: [ringMat])
                ring.position = p
                root.addChild(ring)
            }
            if pts.count == 2 {
                let sg = Geo.segment(from: pts[0], to: pts[1])
                let line = ModelEntity(mesh: .generateBox(size: SIMD3(sg.length, 0.003, 0.003)), materials: [mat])
                line.position = sg.center
                line.orientation = sg.rotation
                root.addChild(line)
            }
            if let label, let last = pts.last {
                let l = makeLabel(label, size: 0.025)
                l.position = (pts.count == 2 ? (pts[0] + pts[1]) / 2 : last) + SIMD3(0, 0.06, 0)
                root.addChild(l)
            }
            arView.scene.addAnchor(root)
            probeRoot = root
            probeKey = key
        }
        probeRoot?.components.set(OpacityComponent(opacity: max(0, min(1, opacity))))
    }

    // MARK: housekeeping

    func clearAll(session: ARSession) {
        for (_, (a, ae, _)) in cubeAnchors { session.remove(anchor: a); arView.scene.removeAnchor(ae) }
        for (a, ae) in otherAnchors { if let a { session.remove(anchor: a) }; arView.scene.removeAnchor(ae) }
        if let pa = pendingA { arView.scene.removeAnchor(pa) }
        cubeAnchors.removeAll(); cubeBodies.removeAll(); otherAnchors.removeAll(); billboards.removeAll()
        cubeModels.removeAll(); selectedCube = nil; ledger.reset()
        pendingA = nil; measure.reset()
        setMeasurePoints([], label: nil, opacity: 0)
        onPlaced?(0)
    }

    /// Turn every label toward the camera and keep it a readable size (≈3 cm tall per metre of distance).
    func updateBillboards(camera: SIMD3<Float>) {
        billboards.removeAll { $0.scene == nil }   // dropped with their anchor
        for b in billboards {
            let p = b.position(relativeTo: nil)
            b.setOrientation(Geo.billboardRotation(position: p, camera: camera), relativeTo: nil)
            let s = max(0.6, min(4, Geo.distance(p, camera)))
            b.setScale(SIMD3(repeating: s), relativeTo: nil)
        }
    }

    // MARK: entities

    private func dot(color: UIColor) -> ModelEntity {
        ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: color)])
    }

    private func makeLabel(_ text: String, size: CGFloat = 0.03) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.0005,
                                             font: .systemFont(ofSize: size, weight: .semibold),
                                             containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
        let textEntity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let bounds = textEntity.visualBounds(relativeTo: nil)
        textEntity.position = SIMD3(-bounds.center.x, -bounds.center.y, 0.001)
        var plate = UnlitMaterial(color: .black)
        plate.blending = .transparent(opacity: 0.55)
        let bg = ModelEntity(mesh: .generatePlane(width: bounds.extents.x + Float(size) * 0.6,
                                                  height: bounds.extents.y + Float(size) * 0.4,
                                                  cornerRadius: Float(size) * 0.2),
                             materials: [plate])
        let holder = Entity()
        holder.addChild(bg)
        holder.addChild(textEntity)
        billboards.append(holder)
        return holder
    }
}
