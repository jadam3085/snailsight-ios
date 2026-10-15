import ARKit
import SnailSightCore

/// World-space views of the LiDAR scene mesh (ARMeshAnchors) for the sim (9.4):
///  - change regions: the world bounds an anchor covered before and after an update / removal, so bodies resting on
///    that part of the mesh re-check their support (SupportWake);
///  - floor triangles around the user for the A* grid (NavGridBuilder), read off the main thread.
/// RealityKit itself rebuilds the scene-understanding collision shapes for changed anchors (the `.collision` option);
/// what was missing in 9.3.65 was anything asking "am I still held up?" afterwards.
final class SimMeshSource {
    private var bounds: [UUID: Bounds3] = [:]

    func reset() { bounds.removeAll() }

    /// Region to wake for an added/updated anchor: old ∪ new bounds (a box moved away shrinks the anchor's bounds,
    /// so the old ones are where support may have vanished).
    func changed(_ a: ARMeshAnchor) -> Bounds3? {
        guard let now = Self.worldBounds(a) else { return bounds[a.identifier] }
        let old = bounds[a.identifier]
        bounds[a.identifier] = now
        return old.map { $0.union(now) } ?? now
    }

    func removed(_ id: UUID) -> Bounds3? { bounds.removeValue(forKey: id) }

    func knownBounds(_ id: UUID) -> Bounds3? { bounds[id] }

    /// World AABB of an anchor's vertices (local AABB → 8 transformed corners).
    static func worldBounds(_ a: ARMeshAnchor) -> Bounds3? {
        let g = a.geometry
        let n = g.vertices.count
        guard n > 0, g.vertices.format == .float3 else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<n {
            let v = g.vertex(at: UInt32(i))
            lo = pointwiseMin(lo, v); hi = pointwiseMax(hi, v)
        }
        var wlo = SIMD3<Double>(repeating: .greatestFiniteMagnitude), whi = -wlo
        for k in 0..<8 {
            let c = SIMD3<Float>(k & 1 == 0 ? lo.x : hi.x, k & 2 == 0 ? lo.y : hi.y, k & 4 == 0 ? lo.z : hi.z)
            let w = a.transform * SIMD4(c, 1)
            let d = SIMD3<Double>(Double(w.x), Double(w.y), Double(w.z))
            wlo = pointwiseMin(wlo, d); whi = pointwiseMax(whi, d)
        }
        return Bounds3(min: wlo, max: whi)
    }

    /// Anchors whose bounds touch a ground rectangle (x/z in world).
    func anchors(in session: ARSession, near region: Bounds3) -> [ARMeshAnchor] {
        let all = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        return all.filter { a in
            guard let b = bounds[a.identifier] ?? Self.worldBounds(a) else { return false }
            return b.intersects(region)
        }
    }

    /// Feed every triangle of `anchors` (world coordinates → ground frame + height) into the grid builder.
    /// ARMeshAnchors are immutable snapshots, so this runs on a background queue.
    static func addTriangles(of anchors: [ARMeshAnchor], to b: inout NavGridBuilder) {
        for a in anchors {
            let g = a.geometry
            let fs = g.faces
            guard g.vertices.format == .float3, fs.bytesPerIndex == 4, fs.indexCountPerPrimitive == 3 else { continue }
            let m = a.transform
            var world = [(V2, Double)]()
            world.reserveCapacity(g.vertices.count)
            for i in 0..<g.vertices.count {
                let w = m * SIMD4(g.vertex(at: UInt32(i)), 1)
                world.append((V2(Double(w.x), Double(-w.z)), Double(w.y)))
            }
            let n = fs.count * 3
            let ip = fs.buffer.contents().bindMemory(to: UInt32.self, capacity: n)
            var k = 0
            while k + 2 < n {
                let i0 = Int(ip[k]), i1 = Int(ip[k + 1]), i2 = Int(ip[k + 2])
                k += 3
                guard i0 < world.count, i1 < world.count, i2 < world.count else { continue }
                b.addTriangle(world[i0], world[i1], world[i2])
            }
        }
    }
}
