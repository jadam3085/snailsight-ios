// SnailSight 12.18: hide individual faces of a loaded base tile (USDZ entity tree) without touching the shared mesh
// resources: each ModelComponent gets a NEW MeshResource built from its original contents minus the hidden triangles
// (the original is kept to restore). Used by the AR tiles (TileStreamer: device surface + Layer B cubes) and Map ▸ 3D
// (Map3DTileLoader: Layer B cubes). Face order = entities depth-first, models, parts, triangles (first instance of a
// model only; tile USDZ hold one instance per model).
import RealityKit
import simd
import SnailSightCore

final class TileFaceMask {
    private struct Part {
        let model: String
        let part: Int
        let start: Int
        let indices: [UInt32]
    }

    private struct Target {
        let entity: Entity
        let original: MeshResource
        let contents: MeshResource.Contents
        let parts: [Part]
    }

    private var targets: [Target] = []
    /// x, y, z per face in the MAP frame (z up).
    private(set) var centroids: [Float] = []
    /// [x0, y0, z0, x1, y1, z1] of the centroids (map frame).
    private(set) var box: [Float] = [0, 0, 0, 0, 0, 0]
    private(set) var applied: [Bool] = []
    private(set) var appliedCount = 0

    var faceCount: Int { centroids.count / 3 }
    var isEmpty: Bool { targets.isEmpty }

    /// `frame` = the entity whose space is converted to the map frame by `toMap` (identity for an entity already in
    /// map coordinates).
    init(holder: Entity, frame: Entity, toMap: (SIMD3<Float>) -> SIMD3<Float> = { $0 }) {
        func walk(_ e: Entity) {
            if let mc = e.components[ModelComponent.self] {
                let contents = mc.mesh.contents
                let toFrame = e.transformMatrix(relativeTo: frame)
                var firstInst: [String: simd_float4x4] = [:]
                for inst in contents.instances where firstInst[inst.model] == nil { firstInst[inst.model] = inst.transform }
                var parts: [Part] = []
                for m in contents.models {
                    let M = toFrame * (firstInst[m.id] ?? matrix_identity_float4x4)
                    for (pi, part) in m.parts.enumerated() {
                        guard let idx = part.triangleIndices?.elements, !idx.isEmpty else { continue }
                        let pos = part.positions.elements
                        var flat = [Float]()
                        flat.reserveCapacity(pos.count * 3)
                        for p in pos {
                            let w = M * SIMD4<Float>(p.x, p.y, p.z, 1)
                            let q = toMap(SIMD3<Float>(w.x, w.y, w.z))
                            flat.append(q.x); flat.append(q.y); flat.append(q.z)
                        }
                        parts.append(Part(model: m.id, part: pi, start: centroids.count / 3, indices: idx))
                        centroids += CoveredFaces.centroids(positions: flat, indices: idx)
                    }
                }
                if !parts.isEmpty { targets.append(Target(entity: e, original: mc.mesh, contents: contents, parts: parts)) }
            }
            for c in e.children { walk(c) }
        }
        walk(holder)
        applied = [Bool](repeating: false, count: centroids.count / 3)
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        var i = 0
        while i + 2 < centroids.count {
            if centroids[i] == centroids[i] {
                for a in 0..<3 { lo[a] = min(lo[a], centroids[i + a]); hi[a] = max(hi[a], centroids[i + a]) }
            }
            i += 3
        }
        if lo[0].isFinite { box = lo + hi }
    }

    /// Draw the tile without the faces flagged in `mask` (empty / all false = the original meshes).
    /// Returns false when nothing changed.
    @discardableResult
    func apply(_ mask: [Bool]) -> Bool {
        let m = mask.count == faceCount ? mask : [Bool](repeating: false, count: faceCount)
        guard m != applied else { return false }
        let n = m.reduce(0) { $0 + ($1 ? 1 : 0) }
        for t in targets {
            guard var mc = t.entity.components[ModelComponent.self] else { continue }
            if n == 0 {
                mc.mesh = t.original
                t.entity.components.set(mc)
                continue
            }
            var kept: [String: [Int: [UInt32]]] = [:]
            var touched = false
            for p in t.parts {
                let faces = p.indices.count / 3
                var out = [UInt32]()
                out.reserveCapacity(p.indices.count)
                for f in 0..<faces where !m[p.start + f] {
                    out.append(p.indices[f * 3]); out.append(p.indices[f * 3 + 1]); out.append(p.indices[f * 3 + 2])
                }
                if out.count != p.indices.count { touched = true }
                kept[p.model, default: [:]][p.part] = out.isEmpty ? [0, 0, 0] : out   // degenerate: draws nothing
            }
            guard touched else {
                if mc.mesh !== t.original { mc.mesh = t.original; t.entity.components.set(mc) }
                continue
            }
            var models: [MeshResource.Model] = []
            for md in t.contents.models {
                var parts: [MeshResource.Part] = []
                for (pi, part) in md.parts.enumerated() {
                    var np = part
                    if let k = kept[md.id]?[pi] { np.triangleIndices = MeshBuffers.TriangleIndices(k) }
                    parts.append(np)
                }
                models.append(MeshResource.Model(id: md.id, parts: parts))
            }
            var c = t.contents
            c.models = MeshModelCollection(models)
            guard let res = try? MeshResource.generate(from: c) else { continue }
            mc.mesh = res
            t.entity.components.set(mc)
        }
        applied = m
        appliedCount = n
        return true
    }

    /// Does the map-frame xy square [x0, y0, x1, y1] touch this tile's faces?
    func touches(square s: [Double]) -> Bool {
        guard s.count >= 4 else { return false }
        return Double(box[0]) <= s[2] && Double(box[3]) >= s[0] && Double(box[1]) <= s[3] && Double(box[4]) >= s[1]
    }
}
