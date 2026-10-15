import Foundation

// SnailSight 10.1 P3 "phone as mock robot" (plan §7 P3, API §8.10): colour the real floor by RobosnailBob's
// traversability and preview "can the robot go here" paths, in AR.
// Source: GET /v1/maps/{map}/nav (levels, bounds, grid_map urls) → each level's grid_map.bin (float32 per layer,
// grid_map order: column-major, (0,0) = the +x +y corner; written by terrain.py `a[::-1, ::-1].ravel(order="F")`)
// + grid_map.yaml (layer order). Patches are rebuilt around the camera (radius ~6 m, 10 cm quads, one mesh per
// traversability class). Pure, Linux-tested (TerrainARTests).

public struct NavLevel: Decodable, Equatable {
    public struct GridFiles: Decodable, Equatable { public var yaml: String?; public var bin: String? }
    public var level: Int
    public var groundZ: Double?
    public var boundsXY: [Double]?              // x0, y0, x1, y1
    public var shape: [Int]?                    // nx, ny
    public var gridMap: GridFiles?
    enum CodingKeys: String, CodingKey {
        case level, shape
        case groundZ = "ground_z", boundsXY = "bounds_xy", gridMap = "grid_map"
    }

    public func contains(x: Double, y: Double, margin: Double = 0) -> Bool {
        guard let b = boundsXY, b.count == 4 else { return false }
        return x >= b[0] - margin && x <= b[2] + margin && y >= b[1] - margin && y <= b[3] + margin
    }
}

public struct NavDoc: Decodable, Equatable {
    public var mapID: String
    public var version: Int
    public var cellM: Double?
    public var levels: [NavLevel]
    public var profileName: String?
    enum CodingKeys: String, CodingKey { case version, levels, profile, mapID = "map_id", cellM = "cell_m" }
    struct Profile: Decodable { var name: String? }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mapID = try c.decode(String.self, forKey: .mapID)
        version = try c.decode(Int.self, forKey: .version)
        cellM = try c.decodeIfPresent(Double.self, forKey: .cellM)
        levels = try c.decode([NavLevel].self, forKey: .levels)
        profileName = (try? c.decodeIfPresent(Profile.self, forKey: .profile))?.name
    }

    /// The level the phone stands on: bounds contain (x, y), ground nearest to (camera z − carrying height 1.4 m).
    public func level(x: Double, y: Double, cameraZ: Double) -> NavLevel? {
        let floor = cameraZ - 1.4
        let inside = levels.filter { $0.contains(x: x, y: y, margin: 0.5) }
        let pool = inside.isEmpty ? levels : inside
        return pool.min { abs(($0.groundZ ?? floor) - floor) < abs(($1.groundZ ?? floor) - floor) }
    }
}

public enum GridMapYAML {
    public static let defaultLayers = ["elevation", "variance", "slope", "roughness", "step", "cost_cell", "cost", "unknown"]

    /// The `layers:` list of a grid_map.yaml (one `- name` per line). Falls back to the documented order.
    public static func layers(_ text: String) -> [String] {
        var out: [String] = []
        var inLayers = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("layers:") { inLayers = true; continue }
            guard inLayers else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { out.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
            else if !t.isEmpty { break }
        }
        return out.isEmpty ? defaultLayers : out
    }
}

/// One level's 2.5D grid, cells [ix, iy] with centres x0 + (ix + 0.5)·cell.
public struct TerrainGrid {
    public let nx: Int, ny: Int
    public let x0: Double, y0: Double, cell: Double
    private var layers: [String: [Float]]

    public init(nx: Int, ny: Int, x0: Double, y0: Double, cell: Double, layers: [String: [Float]]) {
        self.nx = nx; self.ny = ny; self.x0 = x0; self.y0 = y0; self.cell = cell; self.layers = layers
    }

    /// grid_map.bin → grid. Only `keep` layers are kept (memory). nil when the size does not match.
    public static func parse(bin: Data, nx: Int, ny: Int, x0: Double, y0: Double, cell: Double, layerNames: [String],
                             keep: Set<String> = ["elevation", "cost", "slope", "step"]) -> TerrainGrid? {
        let per = nx * ny
        guard per > 0, bin.count >= per * 4 * layerNames.count else { return nil }
        var out: [String: [Float]] = [:]
        bin.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for (k, name) in layerNames.enumerated() where keep.contains(name) {
                var a = [Float](repeating: .nan, count: per)
                let off = k * per * 4
                for ix in 0..<nx {
                    for iy in 0..<ny {
                        let flat = (nx - 1 - ix) + (ny - 1 - iy) * nx
                        let bits = raw.loadUnaligned(fromByteOffset: off + flat * 4, as: UInt32.self)
                        a[ix * ny + iy] = Float(bitPattern: UInt32(littleEndian: bits))
                    }
                }
                out[name] = a
            }
        }
        return TerrainGrid(nx: nx, ny: ny, x0: x0, y0: y0, cell: cell, layers: out)
    }

    public func value(_ layer: String, ix: Int, iy: Int) -> Float? {
        guard ix >= 0, iy >= 0, ix < nx, iy < ny, let a = layers[layer] else { return nil }
        let v = a[ix * ny + iy]
        return v.isFinite ? v : nil
    }

    public func index(x: Double, y: Double) -> (ix: Int, iy: Int)? {
        let ix = Int(floor((x - x0) / cell)), iy = Int(floor((y - y0) / cell))
        guard ix >= 0, iy >= 0, ix < nx, iy < ny else { return nil }
        return (ix, iy)
    }

    public var hasLayers: [String] { layers.keys.sorted() }
}

/// Traversability classes for colouring (COST_STOPS of terrain.py: 0 green, 0.45 amber, 0.9 orange, 1 red).
public enum TerrainClass: Int, CaseIterable {
    case free = 0, caution, hard, lethal

    public static func of(cost: Float) -> TerrainClass {
        if cost >= 1 { return .lethal }
        if cost >= 0.9 { return .hard }
        if cost >= 0.45 { return .caution }
        return .free
    }

    /// RGB 0…1 (matches the web viewer's overlay ramp).
    public var rgb: (Double, Double, Double) {
        switch self {
        case .free: return (46 / 255, 160 / 255, 67 / 255)
        case .caution: return (240 / 255, 200 / 255, 40 / 255)
        case .hard: return (230 / 255, 110 / 255, 30 / 255)
        case .lethal: return (200 / 255, 30 / 255, 30 / 255)
        }
    }
}

public enum TerrainPatch {
    public struct Result {
        public var meshes: [TerrainClass: FlatMesh]
        public var cells: Int
        public var center: [Double]
    }

    /// Quads of `block`×`block` grid cells (2 → 10 cm) within `radius` of (cx, cy), at the block's highest elevation +
    /// `lift`, one mesh per class (the block's worst cost). Unknown blocks are left out. Positions in the map frame.
    public static func build(_ g: TerrainGrid, cx: Double, cy: Double, radius: Double = 6, block: Int = 2,
                             lift: Float = 0.03, maxCells: Int = 12_000) -> Result {
        var meshes: [TerrainClass: FlatMesh] = [:]
        var cells = 0
        guard let c = g.index(x: min(max(cx, g.x0), g.x0 + Double(g.nx) * g.cell - 1e-6),
                              y: min(max(cy, g.y0), g.y0 + Double(g.ny) * g.cell - 1e-6)) else {
            return Result(meshes: [:], cells: 0, center: [cx, cy])
        }
        let r = Int(ceil(radius / g.cell))
        let b = max(1, block)
        let ix0 = max(0, (c.ix - r) / b * b), iy0 = max(0, (c.iy - r) / b * b)
        let ix1 = min(g.nx, c.ix + r + 1), iy1 = min(g.ny, c.iy + r + 1)
        let half = Float(g.cell * Double(b)) / 2
        var bx = ix0
        outer: while bx < ix1 {
            var by = iy0
            while by < iy1 {
                defer { by += b }
                var worst: Float = -1, top: Float = -.infinity
                for ix in bx..<min(bx + b, g.nx) {
                    for iy in by..<min(by + b, g.ny) {
                        if let z = g.value("elevation", ix: ix, iy: iy) { top = max(top, z) }
                        if let k = g.value("cost", ix: ix, iy: iy) { worst = max(worst, k) }
                    }
                }
                guard worst >= 0, top.isFinite else { continue }
                let mx = g.x0 + (Double(bx) + Double(b) / 2) * g.cell, my = g.y0 + (Double(by) + Double(b) / 2) * g.cell
                guard hypot(mx - cx, my - cy) <= radius else { continue }
                let cls = TerrainClass.of(cost: worst)
                var m = meshes[cls] ?? FlatMesh()
                let base = UInt32(m.positions.count / 3)
                let z = top + lift
                let x = Float(mx), y = Float(my)
                let gap: Float = 0.004                       // a hairline between quads reads as a grid
                let h = half - gap
                m.positions += [x - h, y - h, z, x + h, y - h, z, x + h, y + h, z, x - h, y + h, z]
                m.indices += [base, base + 1, base + 2, base, base + 2, base + 3]   // CCW seen from +z
                meshes[cls] = m
                cells += 1
                if cells >= maxCells { break outer }
            }
            bx += b
        }
        return Result(meshes: meshes, cells: cells, center: [cx, cy])
    }

    /// Rebuild when the camera moved more than `metres` from the last patch centre.
    public static func needsRebuild(last: [Double]?, x: Double, y: Double, metres: Double = 2) -> Bool {
        guard let l = last else { return true }
        return hypot(l[0] - x, l[1] - y) > metres
    }
}

/// GET …/nav/query answer (API §8.10).
public struct NavQueryAnswer: Decodable, Equatable {
    public var level: Int?
    public var known: Bool?
    public var elevation: Double?
    public var slopeDeg: Double?
    public var stepM: Double?
    public var roughnessM: Double?
    public var cost: Double?
    public var traversable: Bool?
    public var reason: String?
    enum CodingKeys: String, CodingKey {
        case level, known, elevation, cost, traversable, reason
        case slopeDeg = "slope_deg", stepM = "step_m", roughnessM = "roughness_m"
    }

    /// "Robot fits here · slope 3° · step 2 cm" / "Robot can't stand here: step 9 cm".
    public var text: String {
        if known == false { return "Not scanned here yet" }
        var bits: [String] = []
        if let s = slopeDeg { bits.append(String(format: "slope %.0f°", s)) }
        if let s = stepM { bits.append(String(format: "step %.0f cm", s * 100)) }
        let tail = bits.isEmpty ? "" : " · " + bits.joined(separator: " · ")
        if traversable == true { return "Robot fits here" + tail }
        let why = (reason?.isEmpty == false) ? ": \(reason!)" : ""
        return "Robot can't stand here\(why)" + tail
    }
}

/// POST …/nav/path body + answer.
public struct NavPathRequest: Encodable, Equatable {
    public var start: [Double]
    public var goal: [Double]
    public var allowUnknown = false
    public var snapM = 0.3
    enum CodingKeys: String, CodingKey { case start, goal, allowUnknown = "allow_unknown", snapM = "snap_m" }
    public init(start: [Double], goal: [Double]) { self.start = start; self.goal = goal }
}

public struct NavPathAnswer: Decodable, Equatable {
    public var ok: Bool
    public var lengthM: Double?
    public var maxCost: Double?
    public var climbM: Double?
    public var unknownCells: Int?
    public var points: [[Double]]?
    public var reason: String?
    public var ms: Double?
    enum CodingKeys: String, CodingKey {
        case ok, points, reason, ms
        case lengthM = "length_m", maxCost = "max_cost", climbM = "climb_m", unknownCells = "unknown_cells"
    }

    public var text: String {
        guard ok else { return "No path for the robot" + ((reason?.isEmpty == false) ? ": \(reason!)" : "") }
        var s = String(format: "Robot path %.1f m", lengthM ?? 0)
        if let c = climbM, c >= 0.01 { s += String(format: " · climbs %.0f cm", c * 100) }
        if let k = maxCost, k >= 0.45 { s += " · tight spots" }
        return s
    }

    /// The path as dense points (≤ `spacing` m apart) for drawing a dotted line; z from the answer.
    public func dense(spacing: Double = 0.15) -> [[Double]] {
        guard let p = points, p.count >= 2 else { return points ?? [] }
        var out: [[Double]] = [p[0]]
        for i in 1..<p.count {
            let a = p[i - 1], b = p[i]
            let d = hypot(b[0] - a[0], b[1] - a[1])
            let n = max(1, Int(ceil(d / spacing)))
            for k in 1...n {
                let t = Double(k) / Double(n)
                out.append([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t,
                            (a.count > 2 ? a[2] : 0) + ((b.count > 2 ? b[2] : 0) - (a.count > 2 ? a[2] : 0)) * t])
            }
        }
        return out
    }
}
