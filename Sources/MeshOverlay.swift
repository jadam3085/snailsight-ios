import ARKit
import RealityKit
import UIKit

/// Subtle live LiDAR scene mesh: thin, faint white wireframe built from ARMeshAnchors (style "Wire").
/// The "Debug" style instead uses RealityKit's built-in `.showSceneUnderstanding` view, as Apple's sample does.
/// Vertices are lifted 5 mm along their normals so the lines are not hidden by the occlusion mesh, which is the
/// same surface. Rebuilds are throttled (≤ 2 anchors per frame, each ≥ 1 s apart) to protect the frame rate.
/// 9.1.61: while recording ≤ 1 anchor per frame, each ≥ 4 s apart (the wireframe is coverage feedback, not data); when
/// the overlay is off no ARMeshAnchor is held (each one keeps its geometry buffers alive).
/// 9.6 (owner on 9.3.65: "I couldn't see the mesh" while recording): when the recording freezes the mesh
/// (AdaptiveCapture MeshMode.frozen: ARKit reconstruction stops to free its memory) the wireframe already built STAYS,
/// dimmed amber, and ignores anchor updates/removals until thaw (Stop). On thaw the frozen copy fades out after the
/// live mesh has rebuilt (≤ 30 s) so the room never goes blank. `rebuildEvery` = per-anchor spacing while recording
/// (4 s live, 8 s throttled at thermal fair).
final class MeshOverlay {
    let root = AnchorEntity(world: matrix_identity_float4x4)
    private var entities: [UUID: ModelEntity] = [:]
    private var pending: [UUID: ARMeshAnchor] = [:]
    private var lastBuilt: [UUID: TimeInterval] = [:]
    private var seen = Set<UUID>()                // anchors counted while the overlay is off (count only)
    private let material: UnlitMaterial
    private let frozenMaterial: UnlitMaterial
    private let lift: Float = 0.005
    private var vertices: [UUID: Int] = [:]        // per anchor (ARKit geometry), for the mesh memory cap
    /// 12.20: vertices of OUR wire copies per anchor (what this overlay holds), capped by MemPlan.overlayMaxVertices.
    private var built: [UUID: Int] = [:]
    private var centers: [UUID: SIMD3<Float>] = [:]
    private(set) var trimmed = 0
    /// MemPlan: our copies' vertex cap (0 = no copies at all) and the radius kept when over it.
    var maxVertices = 400_000
    var keepRadius: Float = 10
    private(set) var frozen = false
    private var ghost: [ModelEntity] = []          // the frozen copy kept while the live mesh rebuilds after Stop
    private var ghostUntil: TimeInterval = 0
    var rebuildEvery = 4.0
    /// 9.8 heat budget (SimBudget.meshRebuildS): per-anchor spacing when NOT recording (1 s full, 3 s warm, 6 s eco).
    var idleEvery = 1.0
    /// Vertices in the live scene mesh (sum over ARMeshAnchors seen), for AdaptiveCapture.meshVertexCap.
    var vertexCount: Int { vertices.values.reduce(0, +) }
    /// Vertices in our wire copies (≈ 16 B position + 4 B index share each, plus RealityKit's GPU copy).
    var builtVertices: Int { built.values.reduce(0, +) }
    var estimatedBytes: Int { builtVertices * 40 }

    var isEnabled = true {
        didSet {
            root.isEnabled = isEnabled
            if !isEnabled { pending.removeAll() }
        }
    }
    var recording = false
    var count: Int { max(entities.count, pending.count, seen.count) }

    init() {
        var m = UnlitMaterial(color: .white)
        if #available(iOS 18.0, *) {          // wireframe needs iOS 18 (the owner's phone runs 26)
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: 0.22)
        } else {                               // iOS 17: a very faint filled veil instead
            m.blending = .transparent(opacity: 0.08)
        }
        material = m
        var f = UnlitMaterial(color: UIColor(red: 1, green: 0.75, blue: 0.3, alpha: 1))      // frozen: dim amber
        if #available(iOS 18.0, *) {
            f.triangleFillMode = .lines
            f.blending = .transparent(opacity: 0.14)
        } else {
            f.blending = .transparent(opacity: 0.05)
        }
        frozenMaterial = f
    }

    /// Recording froze the mesh: keep what is drawn (dimmed), stop following ARKit (whose reconstruction is reset).
    func freeze() {
        guard !frozen else { return }
        frozen = true
        pending.removeAll()
        for e in entities.values { e.model?.materials = [frozenMaterial] }
    }

    /// Stop: the live mesh comes back with new anchors; the frozen copy stays until it has rebuilt (or 30 s).
    func thaw(now: TimeInterval) {
        guard frozen else { return }
        frozen = false
        ghost = Array(entities.values)
        entities.removeAll(); lastBuilt.removeAll(); vertices.removeAll(); seen.removeAll(); built.removeAll()
        ghostUntil = now + 30
    }

    private func dropGhost() {
        for e in ghost { e.removeFromParent() }
        ghost.removeAll()
    }

    func update(_ a: ARMeshAnchor) {
        if frozen { return }
        vertices[a.identifier] = a.geometry.vertices.count
        centers[a.identifier] = SIMD3(a.transform.columns.3.x, a.transform.columns.3.y, a.transform.columns.3.z)
        if isEnabled && maxVertices > 0 { pending[a.identifier] = a } else { seen.insert(a.identifier) }
        entities[a.identifier]?.transform = Transform(matrix: a.transform)
    }

    func remove(_ id: UUID) {
        if frozen { return }                       // the reset that froze the mesh removes every anchor: keep ours
        vertices[id] = nil; built[id] = nil; centers[id] = nil
        pending[id] = nil; lastBuilt[id] = nil; seen.remove(id)
        entities.removeValue(forKey: id)?.removeFromParent()
    }

    func removeAll() {
        for e in entities.values { e.removeFromParent() }
        entities.removeAll(); pending.removeAll(); lastBuilt.removeAll(); seen.removeAll(); vertices.removeAll()
        built.removeAll(); centers.removeAll()
        dropGhost()
        frozen = false
    }

    /// 12.20 memory cap: over `maxVertices` our copies of anchors farther than `keepRadius` from the camera go (ARKit
    /// keeps the real mesh; the wire returns when ARKit updates an anchor near you again). 0 = no copies.
    private func enforceCap(cam: SIMD3<Float>?) {
        if maxVertices <= 0 {
            guard !entities.isEmpty || !pending.isEmpty, !frozen else { return }
            for (id, e) in entities { e.removeFromParent(); built[id] = nil; trimmed += 1 }
            entities.removeAll(); pending.removeAll(); lastBuilt.removeAll()
            return
        }
        guard !frozen, builtVertices > maxVertices else { return }
        let c = cam ?? .zero
        func d2(_ id: UUID) -> Float { let p = centers[id] ?? c; let d = p - c; return d.x * d.x + d.z * d.z }
        var total = builtVertices
        for id in entities.keys.sorted(by: { d2($0) > d2($1) }) where total > Int(Double(maxVertices) * 0.85) {
            entities.removeValue(forKey: id)?.removeFromParent()
            total -= built.removeValue(forKey: id) ?? 0
            lastBuilt[id] = nil
            trimmed += 1
        }
    }

    func tick(now: TimeInterval, cam: SIMD3<Float>? = nil) {
        if !ghost.isEmpty, now > ghostUntil || entities.count >= max(8, ghost.count / 2) { dropGhost() }
        enforceCap(cam: cam)
        guard isEnabled, !frozen, !pending.isEmpty, maxVertices > 0 else { return }
        var builtNow = 0
        let perFrame = recording || idleEvery > 1.5 ? 1 : 2, every = recording ? rebuildEvery : idleEvery
        let over = builtVertices > Int(Double(maxVertices) * 0.85)
        let r2 = keepRadius * keepRadius
        for (id, a) in pending where builtNow < perFrame && now - (lastBuilt[id] ?? -10) >= every {
            pending[id] = nil
            if over, let c = cam, entities[id] == nil {           // over the cap: only near anchors get a new copy
                let p = centers[id] ?? c, d = p - c
                if d.x * d.x + d.z * d.z > r2 { continue }
            }
            lastBuilt[id] = now
            builtNow += 1
            guard let mesh = Self.meshResource(from: a.geometry, lift: lift) else { continue }
            built[id] = a.geometry.vertices.count
            if let e = entities[id] {
                e.model?.mesh = mesh
                e.transform = Transform(matrix: a.transform)
            } else {
                let e = ModelEntity(mesh: mesh, materials: [material])
                e.transform = Transform(matrix: a.transform)
                root.addChild(e)
                entities[id] = e
            }
        }
    }

    static func meshResource(from g: ARMeshGeometry, lift: Float) -> MeshResource? {
        let vs = g.vertices, ns = g.normals, fs = g.faces
        guard vs.count > 0, fs.count > 0, vs.format == .float3, fs.bytesPerIndex == 4,
              fs.indexCountPerPrimitive == 3 else { return nil }
        let useNormals = ns.count == vs.count && ns.format == .float3
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vs.count)
        for i in 0..<vs.count {
            var p = g.vertex(at: UInt32(i))
            if useNormals { p += g.normal(at: UInt32(i)) * lift }
            positions.append(p)
        }
        let n = fs.count * 3
        let ip = fs.buffer.contents().bindMemory(to: UInt32.self, capacity: n)
        let indices = Array(UnsafeBufferPointer(start: ip, count: n))
        var d = MeshDescriptor(name: "scene")
        d.positions = MeshBuffers.Positions(positions)
        d.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [d])
    }
}
