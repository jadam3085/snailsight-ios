import Foundation

// SnailSight 12.0 client of the surveyed-vs-estimated world (API §5.16, server flag `estimated_world`):
// - coverage: which ground OUR sensors surveyed vs what only the public 2015 lidar estimates (±2 m) vs unknown,
//   per 16 m tile and as a 0.5 m mask;
// - trees: lidar-estimated trees, confirmed / corrected (drawn est → best position) / refuted / retired by our walks;
// - dem: estimated ground / canopy / slope (float16), with the no-go slope hint.
// Estimated data is a planning HINT only (never measurement, localization or robot nav): the Map draws it hatched /
// ghosted and says so. Pure, Linux-tested (EstimatedWorldTests).

public struct CoverageGrid: Equatable {
    public enum Cls: UInt8 { case unknown = 0, estimated = 1, surveyed = 2 }
    public var origin: [Double]                  // x0, y0 (min corner)
    public var res: Double
    public var w: Int, h: Int
    public var values: [UInt8]                   // row-major, row 0 = min y

    public func cls(ix: Int, iy: Int) -> Cls {
        guard ix >= 0, iy >= 0, ix < w, iy < h else { return .unknown }
        return Cls(rawValue: values[iy * w + ix]) ?? .unknown
    }

    public func cls(x: Double, y: Double) -> Cls {
        cls(ix: Int(floor((x - origin[0]) / res)), iy: Int(floor((y - origin[1]) / res)))
    }

    public var counts: (surveyed: Int, estimated: Int, unknown: Int) {
        var s = 0, e = 0, u = 0
        for v in values { switch v { case 2: s += 1; case 1: e += 1; default: u += 1 } }
        return (s, e, u)
    }

    /// RGBA for the Map, image order (row 0 = max y): estimated = a light hatch (diagonal stripes every 4 cells),
    /// surveyed / unknown = transparent (surveyed ground is drawn by the measured layers).
    public func rgba() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for iy in 0..<h {
            for ix in 0..<w where values[iy * w + ix] == Cls.estimated.rawValue {
                let o = ((h - 1 - iy) * w + ix) * 4
                let stripe = (ix + iy) % 4 == 0
                out[o] = 169; out[o + 1] = 209; out[o + 2] = 142
                out[o + 3] = stripe ? 120 : 28
            }
        }
        return out
    }
}

public struct CoverageTile: Decodable, Equatable {
    public var key: String
    public var bbox: [Double]
    public var surveyedFrac: Double?
    public var estimatedFrac: Double?
    public var unknownFrac: Double?
    public var cls: String?
    enum CodingKeys: String, CodingKey {
        case key, bbox
        case surveyedFrac = "surveyed_frac", estimatedFrac = "estimated_frac", unknownFrac = "unknown_frac", cls = "class"
    }
}

public struct CoverageDoc: Decodable, Equatable {
    public struct Mask: Decodable, Equatable {
        public var origin: [Double]
        public var res: Double
        public var w: Int
        public var h: Int
        public var encoding: String?
        public var data: String
    }
    public var mapID: String?
    public var rev: Int?
    public var coverageRev: Int?
    public var bbox: [Double]?
    public var tiles: [CoverageTile]
    public var mask: Mask?
    enum CodingKeys: String, CodingKey { case rev, bbox, tiles, mask, mapID = "map_id", coverageRev = "coverage_rev" }

    public static func parse(_ d: Data) -> CoverageDoc? { try? JSONDecoder().decode(CoverageDoc.self, from: d) }

    public var grid: CoverageGrid? {
        guard let m = mask, m.origin.count >= 2, m.w > 0, m.h > 0, let raw = Data(base64Encoded: m.data),
              raw.count >= m.w * m.h else { return nil }
        return CoverageGrid(origin: m.origin, res: m.res, w: m.w, h: m.h, values: Array(raw.prefix(m.w * m.h)))
    }

    /// Surveyed share of the requested area, from the tiles (area-weighted).
    public var surveyedFrac: Double {
        var a = 0.0, s = 0.0
        for t in tiles where t.bbox.count == 4 {
            let ar = (t.bbox[2] - t.bbox[0]) * (t.bbox[3] - t.bbox[1])
            a += ar
            s += ar * (t.surveyedFrac ?? 0)
        }
        return a > 0 ? s / a : 0
    }
}

public struct EstimatedTree: Decodable, Equatable, Identifiable {
    public struct XY: Decodable, Equatable { public var x: Double; public var y: Double }
    public var id: String
    public var status: String                  // estimated | confirmed | corrected | refuted
    public var retired: Bool
    public var x: Double, y: Double            // BEST position
    public var z: Double?
    public var heightM: Double?
    public var crownR: Double?
    public var est: XY?
    public var offsetM: [Double]?
    public var correctedTo: String?

    enum CodingKeys: String, CodingKey {
        case id, status, retired, x, y, z, est
        case heightM = "height_m", crownR = "crown_r_m", offsetM = "offset_m", correctedTo = "corrected_to"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s } else { id = String(try c.decode(Int.self, forKey: .id)) }
        status = (try? c.decode(String.self, forKey: .status)) ?? "estimated"
        retired = (try? c.decode(Bool.self, forKey: .retired)) ?? false
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        z = try? c.decodeIfPresent(Double.self, forKey: .z)
        heightM = try? c.decodeIfPresent(Double.self, forKey: .heightM)
        crownR = try? c.decodeIfPresent(Double.self, forKey: .crownR)
        est = try? c.decodeIfPresent(XY.self, forKey: .est)
        offsetM = try? c.decodeIfPresent([Double].self, forKey: .offsetM)
        correctedTo = try? c.decodeIfPresent(String.self, forKey: .correctedTo)
    }

    /// How the Map draws it: ghost (estimate only), solid (confirmed / surveyed), corrected (line est → best), hidden.
    public enum Look: Equatable { case ghost, solid, corrected, hidden }
    public var look: Look {
        if retired || status == "refuted" { return .hidden }
        switch status {
        case "corrected": return .corrected
        case "confirmed": return .solid
        default: return .ghost
        }
    }

    /// Metres the estimate was off (corrected trees).
    public var offsetDistance: Double? {
        if let o = offsetM, o.count >= 2 { return hypot(o[0], o[1]) }
        if let e = est, status == "corrected" { return hypot(x - e.x, y - e.y) }
        return nil
    }
}

public struct EstimatedDoc: Decodable, Equatable {
    public struct Source: Decodable, Equatable {
        public var name: String?
        public var year: Int?
        public var accuracyM: Double?
        enum CodingKeys: String, CodingKey { case name, year, accuracyM = "accuracy_m" }
    }
    public struct SurveyedTree: Decodable, Equatable { public var id: String; public var x: Double; public var y: Double; public var r: Double? }
    public struct Dem: Decodable, Equatable {
        public var origin: [Double]
        public var res: Double
        public var w: Int
        public var h: Int
        public var ground: String?
        public var canopy: String?
        public var slopeDeg: String?
        public var nogoSlopeDeg: Double?
        enum CodingKeys: String, CodingKey {
            case origin, res, w, h, ground, canopy
            case slopeDeg = "slope_deg", nogoSlopeDeg = "nogo_slope_deg"
        }
    }
    public var rev: Int?
    public var eventsSeq: Int?
    public var source: Source?
    public var counts: [String: Int]?
    public var trees: [EstimatedTree]
    public var surveyedTrees: [SurveyedTree]?
    public var dem: Dem?
    enum CodingKeys: String, CodingKey {
        case rev, source, counts, trees, dem
        case eventsSeq = "events_seq", surveyedTrees = "surveyed_trees"
    }

    public static func parse(_ d: Data) -> EstimatedDoc? { try? JSONDecoder().decode(EstimatedDoc.self, from: d) }

    public var sourceLabel: String {
        guard let s = source else { return "public lidar" }
        var t = s.name ?? "public lidar"
        if let y = s.year { t += " · \(y)" }
        if let a = s.accuracyM { t += String(format: " · ±%.0f m", a) }
        return t
    }

    public var correctedCount: Int { trees.filter { $0.look == .corrected }.count }
}

/// Estimated ground / canopy / slope grids (float16, row 0 = min y).
public struct EstimatedDEM: Equatable {
    public var origin: [Double]
    public var res: Double
    public var w: Int, h: Int
    public var ground: [Float]
    public var canopy: [Float]
    public var slope: [Float]
    public var nogoSlopeDeg: Double

    public init?(_ d: EstimatedDoc.Dem) {
        guard d.w > 0, d.h > 0, d.origin.count >= 2 else { return nil }
        let n = d.w * d.h
        func dec(_ s: String?) -> [Float] {
            guard let s, let raw = Data(base64Encoded: s), raw.count >= n * 2 else { return [] }
            return raw.withUnsafeBytes { r in
                (0..<n).map { i in Half.toFloat(UInt16(littleEndian: r.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) }
            }
        }
        origin = d.origin; res = d.res; w = d.w; h = d.h
        ground = dec(d.ground); canopy = dec(d.canopy); slope = dec(d.slopeDeg)
        nogoSlopeDeg = d.nogoSlopeDeg ?? 25
    }

    private func at(_ a: [Float], _ x: Double, _ y: Double) -> Double? {
        let ix = Int(floor((x - origin[0]) / res)), iy = Int(floor((y - origin[1]) / res))
        guard ix >= 0, iy >= 0, ix < w, iy < h, a.count == w * h else { return nil }
        let v = a[iy * w + ix]
        return v.isFinite ? Double(v) : nil
    }

    public func ground(x: Double, y: Double) -> Double? { at(ground, x, y) }
    public func canopy(x: Double, y: Double) -> Double? { at(canopy, x, y) }
    public func slope(x: Double, y: Double) -> Double? { at(slope, x, y) }

    /// Estimated-ground no-go cells (slope over the hint) where `coverage` says estimated (surveyed ground has its own
    /// measured terrain). RGBA image order, dashed amber like O1's "Slope · robot no-go".
    public func noGoRGBA(coverage: CoverageGrid?) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard slope.count == w * h else { return out }
        for iy in 0..<h {
            for ix in 0..<w {
                let s = slope[iy * w + ix]
                guard s.isFinite, Double(s) > nogoSlopeDeg else { continue }
                if let c = coverage {
                    let x = origin[0] + (Double(ix) + 0.5) * res, y = origin[1] + (Double(iy) + 0.5) * res
                    guard c.cls(x: x, y: y) == .estimated else { continue }
                }
                let o = ((h - 1 - iy) * w + ix) * 4
                out[o] = 231; out[o + 1] = 196; out[o + 2] = 92; out[o + 3] = (ix + iy) % 3 == 0 ? 150 : 70
            }
        }
        return out
    }
}

/// IEEE 754 half → Float without Float16 (not on every platform).
public enum Half {
    public static func toFloat(_ h: UInt16) -> Float {
        let s = UInt32(h >> 15) << 31
        let e = Int((h >> 10) & 0x1f)
        let m = UInt32(h & 0x3ff)
        if e == 0 {
            if m == 0 { return Float(bitPattern: s) }
            let v = Float(m) / 1024 * powf(2, -14)
            return s == 0 ? v : -v
        }
        if e == 31 { return m == 0 ? Float(bitPattern: s | 0x7f80_0000) : .nan }
        return Float(bitPattern: s | (UInt32(e - 15 + 127) << 23) | (m << 13))
    }
}

/// One `estimated` live event / REST events entry (tree status change).
public struct EstimatedEvent: Decodable, Equatable {
    public var seq: Int?
    public var kind: String?
    public var id: String?
    public var from: String?
    public var to: String?
    public var offsetM: [Double]?
    enum CodingKeys: String, CodingKey { case seq, kind, id, from, to, offsetM = "offset_m" }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        if let s = try? c.decode(String.self, forKey: .id) { id = s } else if let n = try? c.decode(Int.self, forKey: .id) { id = String(n) }
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        offsetM = try? c.decodeIfPresent([Double].self, forKey: .offsetM)
    }

    /// "Tree corrected · 1.6 m off the estimate" for a toast.
    public var text: String {
        let what = to ?? "updated"
        if let o = offsetM, o.count >= 2 { return String(format: "Tree %@ · %.1f m off the estimate", what, hypot(o[0], o[1])) }
        return "Tree \(what)"
    }
}

/// The downlink `estimated` message (opt-in layer): {rev, seq, events, coverage_changed}.
public struct EstimatedLiveMessage: Decodable, Equatable {
    public var type: String?
    public var rev: Int?
    public var seq: Int?
    public var events: [EstimatedEvent]?
    public var coverageChanged: Bool?
    enum CodingKeys: String, CodingKey { case type, rev, seq, events, coverageChanged = "coverage_changed" }

    public static func parse(_ d: Data) -> EstimatedLiveMessage? {
        guard let m = try? JSONDecoder().decode(EstimatedLiveMessage.self, from: d), m.type == "estimated" else { return nil }
        return m
    }
}
