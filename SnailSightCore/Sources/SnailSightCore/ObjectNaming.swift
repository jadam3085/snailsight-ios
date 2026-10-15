import Foundation

// Pure (simd-free) half of the 9.3 object-scan code, split out of ObjectScan.swift so Linux CI compiles it.

/// The two capture choices behind "Object scan (high-res)".
public enum ObjectScanMode: String, CaseIterable, Codable {
    /// Apple Object Capture: guided capture (ObjectCaptureSession + ObjectCaptureView, with Apple's adjustable AR box)
    /// and on-device PhotogrammetrySession reconstruction (.reduced is the only iOS detail level). Best surface detail.
    case photo
    /// SnailSight recorder with the object profile (dense full-res keyframes) inside an AR box the owner places;
    /// the server fuses the LiDAR depth (TSDF, 4 mm voxels). Quicker, no on-device reconstruction wait.
    case lidar

    public var title: String {
        switch self {
        case .photo: return "Photo-quality (Apple Object Capture)"
        case .lidar: return "Quick LiDAR (box + depth)"
        }
    }

    /// Capture folder / client id prefix: "obj-…" (photo), "objl-…" (lidar). Neither starts with "cap-", so the room
    /// capture scans in the upload queue (orphans, crash recovery) never treat them as room captures.
    public var prefix: String { self == .photo ? "obj" : "objl" }
}

public enum ObjectNaming {
    /// "obj-20261012-153012" / "objl-20261012-153012" (UTC), sortable with the room captures.
    public static func clientObjectID(mode: ObjectScanMode, start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(mode.prefix)-\(f.string(from: start))"
    }

    /// Mode from a capture id, nil for a room capture.
    public static func mode(of id: String) -> ObjectScanMode? {
        if id.hasPrefix("objl-") { return .lidar }
        if id.hasPrefix("obj-") { return .photo }
        return nil
    }

    /// Tags sent with the object: lower-case, [a-z0-9_-], de-duplicated; "robot" = send to the robot page.
    public static func tags(_ raw: [String]) -> [String] {
        var out: [String] = []
        for t in raw {
            let s = String(t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
            if !s.isEmpty, s.count <= 32, !out.contains(s) { out.append(s) }
        }
        return out
    }
}

/// Where an upload goes. Room captures → /v1/sessions (house workflow); object scans → /v1/objects (never merged,
/// never a scene, no rooms/floorplan/sim export).
public enum UploadRoute {
    public static func target(for id: String) -> String { ObjectNaming.mode(of: id) == nil ? "session" : "object" }
    public static func createPath(target: String) -> String { target == "object" ? "/v1/objects" : "/v1/sessions" }
    public static func partPath(target: String, serverID: String, part: Int) -> String {
        target == "object" ? "/v1/objects/\(serverID)/parts/\(part)" : "/v1/sessions/\(serverID)/parts/\(part)"
    }
    public static func statusPath(target: String, serverID: String) -> String {
        target == "object" ? "/v1/objects/\(serverID)" : "/v1/sessions/\(serverID)"
    }
    /// Server id key in the create response.
    public static func idKey(target: String) -> String { target == "object" ? "object_id" : "session_id" }

    /// "Object 0.84 × 0.62 × 0.61 m (w × d × h)" from GET /v1/objects/{id} `result.dims_m` = [x, y (height), z].
    public static func objectLine(dims: [Double]?) -> String? {
        guard let d = dims, d.count == 3 else { return nil }
        return String(format: "Object %.2f × %.2f × %.2f m (w × d × h)", d[0], d[2], d[1])
    }
}
