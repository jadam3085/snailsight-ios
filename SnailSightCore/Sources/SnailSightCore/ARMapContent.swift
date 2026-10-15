import Foundation

// SnailSight 10.1 AR 1:1 content in the MAP frame (Z-up metres): the master mesh (the version's decimated
// `collision.obj`, ≤ 120 k triangles, API §8.1 — already in map coordinates, so no frame juggling), room names, and the
// P4 objects (boxes + labels). Pure parsing / geometry, Linux-tested (ARMapTests). The app draws all of it under the
// map root entity (ARMapAlign.swift).

/// Flat triangle mesh: xyz floats + triangle indices.
public struct FlatMesh: Equatable {
    public var positions: [Float]             // x, y, z, x, y, z, …
    public var indices: [UInt32]
    public init(positions: [Float] = [], indices: [UInt32] = []) { self.positions = positions; self.indices = indices }
    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    /// Every vertex moved `d` metres along its area-weighted normal (CCW faces), so a wireframe of the house mesh is
    /// not hidden by the LiDAR occlusion mesh of the same wall (MeshOverlay lifts its lines the same way).
    public func liftedAlongNormals(_ d: Float) -> FlatMesh {
        var n = [Float](repeating: 0, count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]) * 3, b = Int(indices[t + 1]) * 3, c = Int(indices[t + 2]) * 3
            t += 3
            let ux = positions[b] - positions[a], uy = positions[b + 1] - positions[a + 1], uz = positions[b + 2] - positions[a + 2]
            let vx = positions[c] - positions[a], vy = positions[c + 1] - positions[a + 1], vz = positions[c + 2] - positions[a + 2]
            let fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx
            for v in [a, b, c] { n[v] += fx; n[v + 1] += fy; n[v + 2] += fz }
        }
        var out = positions
        var i = 0
        while i + 2 < out.count {
            let l = (n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2]).squareRoot()
            if l > 1e-12 { out[i] += n[i] / l * d; out[i + 1] += n[i + 1] / l * d; out[i + 2] += n[i + 2] / l * d }
            i += 3
        }
        return FlatMesh(positions: out, indices: indices)
    }
}

/// Minimal Wavefront OBJ reader: `v x y z [r g b]` and `f a b c …` (also `a/t/n`, negative indices; polygons fanned).
public enum ObjReader {
    public static func parse(_ data: Data, maxTriangles: Int = 400_000) -> FlatMesh {
        var pos: [Float] = []
        var idx: [UInt32] = []
        pos.reserveCapacity(data.count / 12)
        idx.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            var face: [Int] = []
            while i < n {
                // line [i, j)
                var j = i
                while j < n && base[j] != 10 { j += 1 }
                if j - i >= 2 {
                    let c0 = base[i], c1 = base[i + 1]
                    if c0 == 118 /* v */ && (c1 == 32 || c1 == 9) {
                        var k = i + 2
                        var got = 0
                        var xyz: [Float] = [0, 0, 0]
                        while got < 3, let (v, next) = number(base, k, j) { xyz[got] = Float(v); got += 1; k = next }
                        if got == 3 { pos.append(contentsOf: xyz) }
                    } else if c0 == 102 /* f */ && (c1 == 32 || c1 == 9), idx.count / 3 < maxTriangles {
                        face.removeAll(keepingCapacity: true)
                        var k = i + 2
                        while let (v, next) = number(base, k, j, skipSlashes: true) {
                            let vi = Int(v)
                            let nv = pos.count / 3
                            let r = vi < 0 ? nv + vi : vi - 1
                            face.append(r)
                            k = next
                        }
                        let nv = pos.count / 3
                        if face.count >= 3, face.allSatisfy({ $0 >= 0 && $0 < nv }) {
                            for t in 1..<(face.count - 1) {
                                idx.append(UInt32(face[0])); idx.append(UInt32(face[t])); idx.append(UInt32(face[t + 1]))
                            }
                        }
                    }
                }
                i = j + 1
            }
        }
        return FlatMesh(positions: pos, indices: idx)
    }

    /// Next number in [k, end): returns (value, index after it). With `skipSlashes`, `12/5/7` yields 12 and skips the rest.
    private static func number(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int, skipSlashes: Bool = false) -> (Double, Int)? {
        var k = start
        while k < end && (b[k] == 32 || b[k] == 9 || b[k] == 13) { k += 1 }
        guard k < end else { return nil }
        var neg = false
        if b[k] == 45 { neg = true; k += 1 } else if b[k] == 43 { k += 1 }
        var mant = 0.0
        var digits = 0
        while k < end, b[k] >= 48, b[k] <= 57 { mant = mant * 10 + Double(b[k] - 48); k += 1; digits += 1 }
        if k < end, b[k] == 46 {
            k += 1
            var scale = 0.1
            while k < end, b[k] >= 48, b[k] <= 57 { mant += Double(b[k] - 48) * scale; scale *= 0.1; k += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        if k < end, b[k] == 101 || b[k] == 69 {               // exponent
            k += 1
            var eneg = false
            if k < end, b[k] == 45 { eneg = true; k += 1 } else if k < end, b[k] == 43 { k += 1 }
            var e = 0
            while k < end, b[k] >= 48, b[k] <= 57 { e = e * 10 + Int(b[k] - 48); k += 1 }
            mant *= pow(10, Double(eneg ? -e : e))
        }
        if skipSlashes { while k < end, b[k] != 32, b[k] != 9, b[k] != 13 { k += 1 } }
        return (neg ? -mant : mant, k)
    }
}

/// Splits a mesh into XY grid chunks (by triangle centroid) so RealityKit can cull what is behind / far away, and
/// so a near-the-camera budget can pick chunks. Each chunk has its own compact vertex list.
public enum MeshChunker {
    public struct Chunk: Equatable {
        public var key: String                 // "ix_iy"
        public var center: [Double]            // map x, y, z of the chunk's bounds centre
        public var mesh: FlatMesh
    }

    public static func split(_ m: FlatMesh, cell: Double = 4) -> [Chunk] {
        var buckets: [String: (vmap: [UInt32: UInt32], mesh: FlatMesh, lo: [Float], hi: [Float])] = [:]
        let p = m.positions
        var t = 0
        while t + 2 < m.indices.count {
            let a = Int(m.indices[t]), b = Int(m.indices[t + 1]), c = Int(m.indices[t + 2])
            t += 3
            let cx = Double(p[a * 3] + p[b * 3] + p[c * 3]) / 3, cy = Double(p[a * 3 + 1] + p[b * 3 + 1] + p[c * 3 + 1]) / 3
            let key = "\(Int(floor(cx / cell)))_\(Int(floor(cy / cell)))"
            var e = buckets[key] ?? ([:], FlatMesh(), [.infinity, .infinity, .infinity], [-.infinity, -.infinity, -.infinity])
            for v in [a, b, c] {
                let src = UInt32(v)
                if let local = e.vmap[src] { e.mesh.indices.append(local); continue }
                let local = UInt32(e.mesh.positions.count / 3)
                e.vmap[src] = local
                for k in 0..<3 {
                    let q = p[v * 3 + k]
                    e.mesh.positions.append(q)
                    e.lo[k] = min(e.lo[k], q); e.hi[k] = max(e.hi[k], q)
                }
                e.mesh.indices.append(local)
            }
            buckets[key] = e
        }
        return buckets.map { k, e in
            Chunk(key: k, center: (0..<3).map { Double(e.lo[$0] + e.hi[$0]) / 2 }, mesh: e.mesh)
        }.sorted { $0.key < $1.key }
    }

    /// Chunks nearest to `point` (map XY) until `maxTriangles` is used.
    public static func nearest(_ chunks: [Chunk], to point: [Double], maxTriangles: Int) -> [String] {
        let sorted = chunks.sorted {
            hypot($0.center[0] - point[0], $0.center[1] - point[1]) < hypot($1.center[0] - point[0], $1.center[1] - point[1])
        }
        var out: [String] = []
        var used = 0
        for c in sorted {
            if used + c.mesh.triangleCount > maxTriangles && !out.isEmpty { break }
            used += c.mesh.triangleCount
            out.append(c.key)
        }
        return out
    }
}

// MARK: rooms + objects (the parts AR needs; full docs live in ScanLabels.swift for the Scans viewer)

public struct ARRoom: Decodable, Equatable {
    public var id: String
    public var name: String
    public var polygon: [[Double]]           // map frame [x, y] (API §8.4)
    public var floorZ: Double?
    public var height: Double?
    enum CodingKeys: String, CodingKey { case id, name, polygon, height, floorZ = "floor_z" }
    public var points: [[Double]] { polygon.filter { $0.count >= 2 } }
}

public struct ARRoomsDoc: Decodable, Equatable {
    public var revision: Int?
    public var rooms: [ARRoom]
}

public struct ARObject: Decodable, Equatable {
    public struct Box: Decodable, Equatable {
        public var center: [Double]
        public var size: [Double]
        public var yaw: Double?
    }
    public var id: String
    public var label: String
    public var name: String?
    public var category: String?
    public var isStatic: Bool?
    public var centroid: [Double]
    public var box: Box?
    public var confidence: Double?
    public var state: String?
    public var source: String?
    enum CodingKeys: String, CodingKey {
        case id, label, name, category, centroid, box, confidence, state, source
        case isStatic = "static"
    }

    public var displayName: String {
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return label
    }
    public var isManual: Bool { (source ?? "").hasPrefix("manual") }
}

public struct ARObjectsDoc: Decodable, Equatable {
    public var revision: Int
    public var objects: [ARObject]
}

/// One drawable label (map frame).
public struct ARLabelItem: Equatable {
    public enum Kind: String { case room, object }
    public var id: String
    public var kind: Kind
    public var text: String
    public var position: [Double]

    public init(id: String, kind: Kind, text: String, position: [Double]) {
        self.id = id; self.kind = kind; self.text = text; self.position = position
    }
}

/// One drawable object box (map frame, yaw about +z, size = full extents x, y, z).
public struct ARBoxItem: Equatable {
    public var id: String
    public var label: String
    public var center: [Double]
    public var size: [Double]
    public var yaw: Double
    public var movable: Bool
    public var confidence: Double

    public init(id: String, label: String, center: [Double], size: [Double], yaw: Double, movable: Bool, confidence: Double) {
        self.id = id; self.label = label; self.center = center; self.size = size
        self.yaw = yaw; self.movable = movable; self.confidence = confidence
    }
}

public enum ARMapContent {
    /// Publish floor of the P4 layer (plan §7 P4: ≈ 73 % right above 0.5). Owner-made objects always show.
    public static let minConfidence = 0.5

    public static func roomLabels(_ doc: ARRoomsDoc, defaultFloorZ: Double?) -> [ARLabelItem] {
        doc.rooms.compactMap { r in
            guard r.points.count >= 3 else { return nil }
            let c = centroid(r.points)
            return ARLabelItem(id: "room:" + r.id, kind: .room, text: r.name,
                               position: [c[0], c[1], (r.floorZ ?? defaultFloorZ ?? 0) + 1.6])
        }
    }

    /// Objects worth drawing: not missing, confident enough (or owner-made).
    public static func visible(_ doc: ARObjectsDoc, minConfidence: Double = ARMapContent.minConfidence) -> [ARObject] {
        doc.objects.filter { o in
            o.state != "missing" && (o.isManual || (o.confidence ?? 1) >= minConfidence) && o.centroid.count == 3
        }
    }

    public static func boxes(_ objs: [ARObject]) -> [ARBoxItem] {
        objs.map { o in
            let b = o.box
            let ok = (b?.center.count == 3 && b?.size.count == 3)
            let size = ok ? b!.size.map { max($0, 0.04) } : [0.2, 0.2, 0.2]
            return ARBoxItem(id: o.id, label: o.displayName, center: ok ? b!.center : o.centroid, size: size,
                             yaw: b?.yaw ?? 0, movable: !(o.isStatic ?? false) || o.category == "movable",
                             confidence: o.confidence ?? 1)
        }
    }

    public static func objectLabels(_ boxes: [ARBoxItem]) -> [ARLabelItem] {
        boxes.map { b in
            ARLabelItem(id: "object:" + b.id, kind: .object, text: b.label,
                        position: [b.center[0], b.center[1], b.center[2] + b.size[2] / 2 + 0.08])
        }
    }

    /// Area centroid of a polygon (falls back to the vertex mean when degenerate).
    public static func centroid(_ pts: [[Double]]) -> [Double] {
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            let cr = p[0] * q[1] - q[0] * p[1]
            a += cr; cx += (p[0] + q[0]) * cr; cy += (p[1] + q[1]) * cr
        }
        if abs(a) < 1e-9 {
            let n = Double(max(pts.count, 1))
            return [pts.reduce(0) { $0 + $1[0] } / n, pts.reduce(0) { $0 + $1[1] } / n]
        }
        return [cx / (3 * a), cy / (3 * a)]
    }

    /// Ray (map frame) vs oriented boxes: the nearest hit's id and distance. Boxes smaller than `minPick` are picked as
    /// if they had that size (a 4 cm cup is hard to tap).
    public static func pick(origin o: [Double], direction d: [Double], boxes: [ARBoxItem], minPick: Double = 0.25)
        -> (id: String, distance: Double)? {
        var best: (String, Double)?
        for b in boxes {
            let c = cos(-b.yaw), s = sin(-b.yaw)
            // into the box frame (rotate about z by −yaw around its centre)
            let ox = o[0] - b.center[0], oy = o[1] - b.center[1], oz = o[2] - b.center[2]
            let lo = [c * ox - s * oy, s * ox + c * oy, oz]
            let ld = [c * d[0] - s * d[1], s * d[0] + c * d[1], d[2]]
            var tmin = 0.0, tmax = Double.infinity
            var hit = true
            for k in 0..<3 {
                let h = max(b.size[k], minPick) / 2
                if abs(ld[k]) < 1e-12 {
                    if abs(lo[k]) > h { hit = false; break }
                } else {
                    var t1 = (-h - lo[k]) / ld[k], t2 = (h - lo[k]) / ld[k]
                    if t1 > t2 { swap(&t1, &t2) }
                    tmin = max(tmin, t1); tmax = min(tmax, t2)
                    if tmin > tmax { hit = false; break }
                }
            }
            if hit, best == nil || tmin < best!.1 { best = (b.id, tmin) }
        }
        return best.map { (id: $0.0, distance: $0.1) }
    }

    /// The 12 edges of a box as segment pairs in map coordinates (for a thin-bar outline).
    public static func boxEdges(_ b: ARBoxItem) -> [([Double], [Double])] {
        let hx = b.size[0] / 2, hy = b.size[1] / 2, hz = b.size[2] / 2
        let c = cos(b.yaw), s = sin(b.yaw)
        func corner(_ sx: Double, _ sy: Double, _ sz: Double) -> [Double] {
            let x = sx * hx, y = sy * hy
            return [b.center[0] + c * x - s * y, b.center[1] + s * x + c * y, b.center[2] + sz * hz]
        }
        var out: [([Double], [Double])] = []
        for sz in [-1.0, 1.0] {
            let ring = [corner(-1, -1, sz), corner(1, -1, sz), corner(1, 1, sz), corner(-1, 1, sz)]
            for i in 0..<4 { out.append((ring[i], ring[(i + 1) % 4])) }
        }
        for (sx, sy) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] { out.append((corner(sx, sy, -1), corner(sx, sy, 1))) }
        return out
    }
}

/// P4 object corrections from AR (API §8.6: PATCH rename / DELETE false positive), the same bodies the Scans labels
/// use (§8.6a): `author` = snailsight-<agent_id>, `base_revision`; 409 → re-read + retry once (caller).
public struct ObjectCorrectionRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [(String, String)]
    public var body: Data?

    public static func == (a: ObjectCorrectionRequest, b: ObjectCorrectionRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.body == b.body
            && a.query.map { $0.0 + "=" + $0.1 } == b.query.map { $0.0 + "=" + $0.1 }
    }

    static func objectPath(_ scene: String, _ id: String) -> String {
        let s = scene.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scene
        let i = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return "/v1/scenes/\(s)/objects/\(i)"
    }

    /// Rename: `label` = what it is (class, lower-cased by the server); `name` = the owner's own name.
    public static func rename(scene: String, id: String, label: String?, name: String?, author: String,
                              baseRevision: Int?) -> ObjectCorrectionRequest {
        var o: [String: Any] = ["author": author]
        if let l = label?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { o["label"] = String(l.prefix(60)) }
        if let n = name { o["name"] = String(n.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        if let r = baseRevision { o["base_revision"] = r }
        let body = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return ObjectCorrectionRequest(method: "PATCH", path: objectPath(scene, id), query: [], body: body)
    }

    public static func delete(scene: String, id: String, author: String, baseRevision: Int?) -> ObjectCorrectionRequest {
        var q = [("author", author)]
        if let r = baseRevision { q.append(("base_revision", String(r))) }
        return ObjectCorrectionRequest(method: "DELETE", path: objectPath(scene, id), query: q, body: nil)
    }
}
