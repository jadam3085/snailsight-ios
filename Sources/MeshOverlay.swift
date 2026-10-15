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
    private(set) var frozen = false
    private var ghost: [ModelEntity] = []          // the frozen copy kept while the live mesh rebuilds after Stop
    private var ghostUntil: TimeInterval = 0
    var rebuildEvery = 4.0
    /// 9.8 heat budget (SimBudget.meshRebuildS): per-anchor spacing when NOT recording (1 s full, 3 s warm, 6 s eco).
    var idleEvery = 1.0
    /// Vertices in the live scene mesh (sum over ARMeshAnchors seen), for AdaptiveCapture.meshVertexCap.
    var vertexCount: Int { vertices.values.reduce(0, +) }

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
        entities.removeAll(); lastBuilt.removeAll(); vertices.removeAll(); seen.removeAll()
        ghostUntil = now + 30
    }

    private func dropGhost() {
        for e in ghost { e.removeFromParent() }
        ghost.removeAll()
    }

    func update(_ a: ARMeshAnchor) {
        if frozen { return }
        vertices[a.identifier] = a.geometry.vertices.count
        if isEnabled { pending[a.identifier] = a } else { seen.insert(a.identifier) }
        entities[a.identifier]?.transform = Transform(matrix: a.transform)
    }

    func remove(_ id: UUID) {
        if frozen { return }                       // the reset that froze the mesh removes every anchor: keep ours
        vertices[id] = nil
        pending[id] = nil; lastBuilt[id] = nil; seen.remove(id)
        entities.removeValue(forKey: id)?.removeFromParent()
    }

    func removeAll() {
        for e in entities.values { e.removeFromParent() }
        entities.removeAll(); pending.removeAll(); lastBuilt.removeAll(); seen.removeAll(); vertices.removeAll()
        dropGhost()
        frozen = false
    }

    func tick(now: TimeInterval) {
        if !ghost.isEmpty, now > ghostUntil || entities.count >= max(8, ghost.count / 2) { dropGhost() }
        guard isEnabled, !frozen, !pending.isEmpty else { return }
        var built = 0
        let perFrame = recording || idleEvery > 1.5 ? 1 : 2, every = recording ? rebuildEvery : idleEvery
        for (id, a) in pending where built < perFrame && now - (lastBuilt[id] ?? -10) >= every {
            pending[id] = nil
            lastBuilt[id] = now
            built += 1
            guard let mesh = Self.meshResource(from: a.geometry, lift: lift) else { continue }
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
