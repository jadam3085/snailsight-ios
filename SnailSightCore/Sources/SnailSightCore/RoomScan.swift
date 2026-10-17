import Foundation

// 11.3 "Room scan" (structure layer S4): Apple RoomPlan runs on the app's OWN ARSession, so its walls, doors, windows,
// openings, floors and furniture boxes are in the same ARKit world frame the localizer maps with T_map_arkit. The phone
// uploads the room in a small normalized JSON (`snailsight-roomplan/1`, below) plus Apple's own CapturedRoom JSON
// (archived) and, when small, the USDZ export, to `POST /v1/maps/{map}/roomplan` (API §8.11b). The server aligns it with
// the T_map_arkit sent here, checks it against the scanned walls, and lets it replace structure elements only where it
// scores better (the monotonic rule). Everything here is pure (no RoomPlan / ARKit / URLSession) so the Linux CI tests it;
// the app side is Sources/RoomScan/RoomScanner.swift.

// MARK: - ids

public enum RoomScanID {
    /// "rp-20261017-142233-a1b2c3": UTC time + 24 random bits (server rule ^rp-[A-Za-z0-9_-]{4,60}$).
    public static func make(date: Date, random: UInt32 = UInt32.random(in: .min ... .max)) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "rp-" + f.string(from: date) + "-" + String(format: "%06x", random & 0xFFFFFF)
    }

    public static func isValid(_ s: String) -> Bool {
        guard s.hasPrefix("rp-") else { return false }
        let rest = s.dropFirst(3)
        guard (4...60).contains(rest.count) else { return false }
        return rest.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
    }
}

// MARK: - the normalized room

public enum RoomSurfaceKind: String, Codable, CaseIterable {
    case wall, door, window, opening, floor
}

public enum RoomConfidence: String, Codable {
    case high, medium, low
}

/// One RoomPlan surface: `T` = ARKit world ← surface, ROW-major 16 (x along the width, y up, z the normal).
public struct RoomSurface: Equatable {
    public var id: String
    public var kind: RoomSurfaceKind
    public var confidence: RoomConfidence
    public var dimensions: [Double]              // width, height, depth (metres)
    public var T: [Double]
    public var parent: String?
    public var open: Bool?
    public var polygon: [[Double]]               // corners in the surface frame (floors, iOS 17+), may be empty
    public init(id: String, kind: RoomSurfaceKind, confidence: RoomConfidence, dimensions: [Double], T: [Double],
                parent: String? = nil, open: Bool? = nil, polygon: [[Double]] = []) {
        self.id = id; self.kind = kind; self.confidence = confidence; self.dimensions = dimensions; self.T = T
        self.parent = parent; self.open = open; self.polygon = polygon
    }
}

public struct RoomObject: Equatable {
    public var id: String
    public var category: String
    public var confidence: RoomConfidence
    public var dimensions: [Double]
    public var T: [Double]
    public init(id: String, category: String, confidence: RoomConfidence, dimensions: [Double], T: [Double]) {
        self.id = id; self.category = category; self.confidence = confidence; self.dimensions = dimensions; self.T = T
    }
}

public struct RoomScanRoom: Equatable {
    public static let format = "snailsight-roomplan/1"
    public var surfaces: [RoomSurface]
    public var objects: [RoomObject]
    public var story: Int?
    public init(surfaces: [RoomSurface], objects: [RoomObject], story: Int? = nil) {
        self.surfaces = surfaces; self.objects = objects; self.story = story
    }

    public func count(_ k: RoomSurfaceKind) -> Int { surfaces.filter { $0.kind == k }.count }

    private static func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// The `room` object of the upload.
    public func json() -> [String: Any] {
        var out: [String: Any] = [
            "format": Self.format,
            "surfaces": surfaces.map { s -> [String: Any] in
                var d: [String: Any] = ["id": s.id, "kind": s.kind.rawValue, "confidence": s.confidence.rawValue,
                                        "dimensions": s.dimensions.map(Self.fin), "T": s.T.map(Self.fin)]
                if let p = s.parent { d["parent"] = p }
                if let o = s.open { d["open"] = o }
                if !s.polygon.isEmpty { d["polygon"] = s.polygon.map { $0.map(Self.fin) } }
                return d
            },
            "objects": objects.map { o -> [String: Any] in
                ["id": o.id, "category": o.category, "confidence": o.confidence.rawValue,
                 "dimensions": o.dimensions.map(Self.fin), "T": o.T.map(Self.fin)]
            },
        ]
        if let s = story { out["story"] = s }
        return out
    }

    /// "4 walls · 1 door · 2 windows · 3 objects" (HUD / toast).
    public var summary: String {
        func n(_ c: Int, _ one: String, _ many: String) -> String? { c > 0 ? "\(c) \(c == 1 ? one : many)" : nil }
        let parts = [n(count(.wall), "wall", "walls"), n(count(.door), "door", "doors"),
                     n(count(.window), "window", "windows"), n(count(.opening), "opening", "openings"),
                     n(objects.count, "object", "objects")].compactMap { $0 }
        return parts.isEmpty ? "nothing yet" : parts.joined(separator: " · ")
    }
}

// MARK: - maths

public enum RoomScanMath {
    /// simd_float4x4 memory / columns (column-major 16) → row-major 16.
    public static func rowMajor(columnMajor c: [Double]) -> [Double] {
        precondition(c.count == 16)
        return (0..<16).map { i in c[(i % 4) * 4 + i / 4] }
    }

    /// Map position of a surface's centre: T_map_arkit · T_arkit_surface (both row-major).
    public static func mapCentre(T_map_arkit: [Double], surfaceT: [Double]) -> [Double] {
        let m = Mat4(T_map_arkit) * Mat4(surfaceT)
        return [m[0, 3], m[1, 3], m[2, 3]]
    }

    /// Is the surface vertical in the map (its y axis within `maxDeg` of map +z)? The server refuses walls that are not.
    public static func isVerticalInMap(T_map_arkit: [Double], surfaceT: [Double], maxDeg: Double = 10) -> Bool {
        let m = Mat4(T_map_arkit) * Mat4(surfaceT)
        let y0: Double = m[0, 1], y1: Double = m[1, 1], y2: Double = m[2, 1]
        let n2: Double = y0 * y0 + y1 * y1 + y2 * y2
        let n = n2.squareRoot()
        guard n > 1e-9 else { return false }
        let limit: Double = cos(maxDeg * Double.pi / 180)
        return abs(y2 / n) >= limit
    }
}

// MARK: - upload

public enum RoomScanUpload {
    public static let usdzMaxBytes = 8 * 1_048_576       // bigger exports stay on the phone (JSON is what the server uses)

    /// The POST body. `appleJSON` = JSONEncoder output of CapturedRoom (archived by the server, not interpreted unless
    /// the normalized room is missing). nil when the alignment is missing (scan only after the map lock).
    public static func body(id: String, room: RoomScanRoom, appleJSON: Data?, align: MapAlignment?, errCm: Double?,
                            agentID: String, appVersion: String, capturedAt: Double, usdz: Data?) -> Data? {
        guard let al = align, al.T.m.count == 16 else { return nil }
        var b: [String: Any] = ["id": id, "room": room.json(), "T_map_arkit": al.T.m, "agent_id": agentID,
                                "app_version": appVersion, "captured_at": capturedAt]
        var a: [String: Any] = ["version": al.version, "map_id": al.mapID, "at": al.at]
        if let m = al.method { a["method"] = m }
        if let s = al.spreadCm, s.isFinite { a["spread_cm"] = s }
        if let e = errCm, e.isFinite { a["err_cm"] = e }
        b["align"] = a
        if let j = appleJSON, let o = try? JSONSerialization.jsonObject(with: j) { b["captured_room"] = o }
        if let u = usdz, !u.isEmpty, u.count <= usdzMaxBytes { b["usdz_b64"] = u.base64EncodedString() }
        guard JSONSerialization.isValidJSONObject(b) else { return nil }
        return try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
    }

    /// What to do with an answer: 2xx = sent (delete the spool file), 4xx = the server will never take it (drop, log),
    /// anything else / offline = keep and retry.
    public enum Outcome: Equatable { case sent, drop, retry }
    public static func outcome(status: Int?) -> Outcome {
        guard let s = status else { return .retry }
        if (200..<300).contains(s) { return .sent }
        if s == 408 || s == 429 { return .retry }
        if (400..<500).contains(s) { return .drop }
        return .retry
    }
}

/// HUD wording.
public enum RoomScanText {
    public static func needsLock() -> String { "Room scan needs the map lock first: look around until the pill says LOCKED" }
    public static func scanning(_ room: RoomScanRoom?) -> String { "Room scan · " + (room?.summary ?? "move slowly around the room") }
    public static func result(_ status: String?, changed: Bool?) -> String {
        switch status {
        case "replaced": return "Room scan improved the map's walls"
        case "new_room": return "Room scan added a new room to the map"
        case "kept": return "Room scan checked: the map's walls were already better"
        case "rejected_alignment": return "Room scan did not line up with the map (relocalize and scan again)"
        default: return changed == true ? "Room scan applied" : "Room scan uploaded"
        }
    }
}
