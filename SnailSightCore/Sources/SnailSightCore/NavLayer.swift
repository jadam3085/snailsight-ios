import Foundation

// SnailSight 12.18: Layer A, the robots' obstacle view (live world plan P1, server livenav.py, API §6b.6).
// GET /v1/live/nav?map_id=site&since=<rev> → {map_id, live, rev, tiles: [{key "level/tx/ty", level, tx, ty, rev, z0, vox,
// nz, nc, t, occ, free}]}: per 4 m tile and 5 cm column two uint64 masks over `nz` height bins of `vox` from `z0`
// (= storey floor − 0.30 m): `occ` = bins confidently occupied, `free` = confidently empty. Base64 little-endian
// uint64 [nc × nc], row = y, column = x. `since` returns only tiles changed after that rev.
// The app shows what a ground robot plans around: per column, the robot's body band (floor + 0.10 … + 1.00 m, the
// robosnailbob clearance / height the server's occupancy layer uses) → blocked (any occupied bin), seen free (free bins
// and none occupied) or unknown. Pure, Linux-tested (NavLayerTests).

public struct LiveNavTile: Decodable, Equatable {
    public var key: String
    public var level: Int
    public var tx: Int
    public var ty: Int
    public var rev: Int
    public var z0: Double
    public var vox: Double
    public var nz: Int
    public var nc: Int
    public var t: Double?
    public var occ: [UInt64]
    public var free: [UInt64]

    enum CodingKeys: String, CodingKey { case key, level, tx, ty, rev, z0, vox, nz, nc, t, occ, free }

    public init(key: String, level: Int, tx: Int, ty: Int, rev: Int, z0: Double, vox: Double = 0.05, nz: Int = 58,
                nc: Int = 80, t: Double? = nil, occ: [UInt64], free: [UInt64]) {
        self.key = key; self.level = level; self.tx = tx; self.ty = ty; self.rev = rev; self.z0 = z0; self.vox = vox
        self.nz = nz; self.nc = nc; self.t = t; self.occ = occ; self.free = free
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        tx = try c.decode(Int.self, forKey: .tx)
        ty = try c.decode(Int.self, forKey: .ty)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        z0 = try c.decode(Double.self, forKey: .z0)
        vox = try c.decodeIfPresent(Double.self, forKey: .vox) ?? 0.05
        nz = try c.decodeIfPresent(Int.self, forKey: .nz) ?? 58
        nc = try c.decodeIfPresent(Int.self, forKey: .nc) ?? 80
        t = try c.decodeIfPresent(Double.self, forKey: .t)
        occ = Self.masks(try c.decode(String.self, forKey: .occ))
        free = Self.masks(try c.decode(String.self, forKey: .free))
    }

    /// base64 little-endian uint64 → masks.
    public static func masks(_ b64: String) -> [UInt64] {
        guard let d = Data(base64Encoded: b64) else { return [] }
        let n = d.count / 8
        var out = [UInt64](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            for i in 0..<n {
                var v: UInt64 = 0
                for b in 0..<8 { v |= UInt64(raw[i * 8 + b]) << (8 * UInt64(b)) }
                out[i] = v
            }
        }
        return out
    }

    public var tileM: Double { vox * Double(nc) }
    /// The storey floor (z0 = floor − 0.30 m).
    public var floorZ: Double { z0 + NavBand.below }
    /// [x0, y0, x1, y1] in the map frame.
    public var square: [Double] { [Double(tx) * tileM, Double(ty) * tileM, Double(tx + 1) * tileM, Double(ty + 1) * tileM] }
}

public struct LiveNavDoc: Decodable {
    public var mapID: String?
    public var live: Bool?
    public var rev: Int?
    public var tiles: [LiveNavTile]
    enum CodingKeys: String, CodingKey { case mapID = "map_id", live, rev, tiles }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mapID = try c.decodeIfPresent(String.self, forKey: .mapID)
        live = try c.decodeIfPresent(Bool.self, forKey: .live)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
        tiles = (try? c.decodeIfPresent([LiveNavTile].self, forKey: .tiles)) ?? []
    }
}

/// The robot body band and the column classes.
public enum NavBand {
    public static let below = 0.30                  // z0 = floor − 0.30 m (server Z_LO)
    public static let lo = 0.10, hi = 1.00          // body band above the floor (ground clearance … height)
    public static let unknown: UInt8 = 0, free: UInt8 = 1, blocked: UInt8 = 2

    /// Bit mask of the bins covering [floor + lo, floor + hi).
    public static func mask(vox: Double, nz: Int, lo: Double = lo, hi: Double = hi) -> UInt64 {
        let a = max(0, Int(((below + lo) / vox).rounded(.down)))
        let b = min(min(nz, 64), Int(((below + hi) / vox).rounded(.up)))
        guard b > a else { return 0 }
        var m: UInt64 = 0
        for i in a..<b { m |= 1 << UInt64(i) }
        return m
    }

    /// nc × nc classes (row 0 = min y).
    public static func classes(_ t: LiveNavTile) -> [UInt8] {
        let n = t.nc * t.nc
        guard t.occ.count >= n, t.free.count >= n else { return [UInt8](repeating: unknown, count: n) }
        let m = mask(vox: t.vox, nz: t.nz)
        var out = [UInt8](repeating: unknown, count: n)
        for i in 0..<n {
            if t.occ[i] & m != 0 { out[i] = blocked } else if t.free[i] & m != 0 { out[i] = free }
        }
        return out
    }

    /// RGBA (premultiplied) with image row 0 = max y (top of the plan): blocked red, seen free faint green,
    /// unknown transparent.
    public static func rgba(_ cls: [UInt8], n: Int, freeAlpha: UInt8 = 70, blockedAlpha: UInt8 = 220) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard cls.count == n * n else { return px }
        for j in 0..<n {
            for i in 0..<n {
                let o = ((n - 1 - j) * n + i) * 4
                switch cls[j * n + i] {
                case blocked:
                    let a = Double(blockedAlpha) / 255
                    px[o] = UInt8(255 * a); px[o + 1] = UInt8(60 * a); px[o + 2] = UInt8(60 * a); px[o + 3] = blockedAlpha
                case free:
                    let a = Double(freeAlpha) / 255
                    px[o] = UInt8(80 * a); px[o + 1] = UInt8(230 * a); px[o + 2] = UInt8(140 * a); px[o + 3] = freeAlpha
                default: break
                }
            }
        }
        return px
    }

    public static func counts(_ cls: [UInt8]) -> (blocked: Int, free: Int) {
        var b = 0, f = 0
        for c in cls { if c == blocked { b += 1 } else if c == free { f += 1 } }
        return (b, f)
    }
}

/// The tiles held by the app (latest per key) + the rev to ask `since`.
public struct LiveNavState {
    public private(set) var tiles: [String: LiveNavTile] = [:]
    public private(set) var rev: Int?
    public private(set) var lastChange: Double?
    public init() {}

    /// Applies a response; returns the keys whose content changed.
    @discardableResult
    public mutating func apply(_ doc: LiveNavDoc, now: Double) -> [String] {
        var changed: [String] = []
        for t in doc.tiles {
            if let old = tiles[t.key], old.rev == t.rev, old.occ == t.occ, old.free == t.free { continue }
            tiles[t.key] = t
            changed.append(t.key)
        }
        if let r = doc.rev { rev = max(rev ?? r, r) }
        if !changed.isEmpty { lastChange = now }
        return changed.sorted()
    }

    public mutating func reset() { tiles.removeAll(); rev = nil; lastChange = nil }

    public func summary(now: Double, blocked: Int) -> String {
        guard !tiles.isEmpty else { return "Waiting for the live nav layer" }
        var s = "\(tiles.count) tile\(tiles.count == 1 ? "" : "s") · \(String(format: "%.1f", Double(blocked) * 0.0025)) m² blocked"
        if let l = lastChange { s += " · changed \(LiveMeshFeed.ago(now - l))" }
        return s
    }
}
