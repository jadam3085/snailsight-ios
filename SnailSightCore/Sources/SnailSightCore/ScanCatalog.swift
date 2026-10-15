import Foundation
import simd

// 9.6 Scans screen (owner 2026-10-13: "see scans through the app, not just through the web portal").
// Pure model of the server's phone catalogue `GET /v1/phone/scans` (docs/SNAILSIGHT-API.md §8.9): whole-house map
// versions, single walks (sessions) and object scans, each with a thumbnail, a RealityKit-ready `mesh.usdz` (built on
// the map server from mesh.glb / model.glb) and, for scenes, the phone splat (`splat_mobile.splat`, antimatter15
// 32-byte layout, ordered most-important-first so a prefix is a good smaller splat).

public struct ScanMesh: Codable, Equatable {
    public var state: String                 // ready | queued | building | failed | missing
    public var usdzURL: String?
    public var bytes: Int?
    public var triangles: Int?
    public var texturePx: Int?
    public var error: String?
    public var frame: String?

    enum CodingKeys: String, CodingKey {
        case state, bytes, triangles, error, frame
        case usdzURL = "usdz_url", texturePx = "texture_px"
    }

    public init(state: String, usdzURL: String? = nil, bytes: Int? = nil, triangles: Int? = nil) {
        self.state = state; self.usdzURL = usdzURL; self.bytes = bytes; self.triangles = triangles
    }

    public var isReady: Bool { state == "ready" && usdzURL != nil }
    public var isPending: Bool { state == "queued" || state == "building" }
}

public struct ScanSplat: Codable, Equatable {
    public var url: String
    public var bytes: Int?
    public var count: Int?
    public var format: String?
    public var frame: String?

    public init(url: String, bytes: Int? = nil, count: Int? = nil) { self.url = url; self.bytes = bytes; self.count = count }
}

public struct ScanBounds: Codable, Equatable {
    public var min: [Double]
    public var max: [Double]
    public init(min: [Double], max: [Double]) { self.min = min; self.max = max }
}

public struct ScanItem: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case map, session, object }

    public var id: String
    public var type: Kind
    public var title: String
    public var subtitle: String?
    public var created: Double?
    public var mapID: String?
    public var version: Int?
    public var latest: Bool?
    public var thumbURL: String?
    public var mesh: ScanMesh?
    public var splat: ScanSplat?
    public var viewsURL: String?
    public var bounds: ScanBounds?
    public var boundsFrame: String?
    public var floorZ: Double?
    public var dimsM: [Double]?

    enum CodingKeys: String, CodingKey {
        case id, type, title, subtitle, created, version, latest, mesh, splat, bounds
        case mapID = "map_id", thumbURL = "thumb_url", viewsURL = "views_url", boundsFrame = "bounds_frame"
        case floorZ = "floor_z", dimsM = "dims_m"
    }

    public init(id: String, type: Kind, title: String, created: Double? = nil, mapID: String? = nil, version: Int? = nil,
                latest: Bool? = nil, mesh: ScanMesh? = nil, splat: ScanSplat? = nil) {
        self.id = id; self.type = type; self.title = title; self.created = created; self.mapID = mapID
        self.version = version; self.latest = latest; self.mesh = mesh; self.splat = splat
    }

    /// Bounds in the viewer's Y-up frame (scenes arrive in the map frame, Z-up; objects already Y-up).
    public var boundsYUp: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let b = bounds, b.min.count == 3, b.max.count == 3 else { return nil }
        let lo = SIMD3<Float>(Float(b.min[0]), Float(b.min[1]), Float(b.min[2]))
        let hi = SIMD3<Float>(Float(b.max[0]), Float(b.max[1]), Float(b.max[2]))
        if boundsFrame == "y-up" || type == .object { return (lo, hi) }
        let a = ScanFrames.mapToYUp(lo), c = ScanFrames.mapToYUp(hi)
        return (simd_min(a, c), simd_max(a, c))
    }
}

public struct ScanList: Codable { public var items: [ScanItem] }

public enum ScanCatalog {
    public static func decode(_ data: Data) throws -> [ScanItem] {
        try JSONDecoder().decode(ScanList.self, from: data).items
    }

    public static func decodeItem(_ data: Data) throws -> ScanItem {
        try JSONDecoder().decode(ScanItem.self, from: data)
    }

    public struct Section: Equatable {
        public var title: String
        public var items: [ScanItem]
    }

    /// Screen order (owner: whole-house maps, latest site version first): "Whole house" = the newest version of every
    /// map (`site` first), then "Walks" (sessions, newest first), "Objects" (newest first), then "Older map versions".
    public static func sections(_ items: [ScanItem]) -> [Section] {
        let maps = items.filter { $0.type == .map }
        var newest: [String: ScanItem] = [:]
        for m in maps {
            let key = m.mapID ?? m.id
            if let cur = newest[key], (cur.version ?? 0) >= (m.version ?? 0) { continue }
            newest[key] = m
        }
        let top = newest.values.sorted { a, b in
            let sa = (a.mapID ?? a.id) == "site", sb = (b.mapID ?? b.id) == "site"
            if sa != sb { return sa }
            return (a.created ?? 0) > (b.created ?? 0)
        }
        let topIDs = Set(top.map(\.id))
        let older = maps.filter { !topIDs.contains($0.id) }.sorted {
            ($0.mapID ?? "", -($0.version ?? 0)) < ($1.mapID ?? "", -($1.version ?? 0))
        }
        let byNew: (ScanItem, ScanItem) -> Bool = { ($0.created ?? 0) > ($1.created ?? 0) }
        var out: [Section] = []
        if !top.isEmpty { out.append(Section(title: "Whole house", items: top)) }
        let sessions = items.filter { $0.type == .session }.sorted(by: byNew)
        if !sessions.isEmpty { out.append(Section(title: "Walks", items: sessions)) }
        let objects = items.filter { $0.type == .object }.sorted(by: byNew)
        if !objects.isEmpty { out.append(Section(title: "Objects", items: objects)) }
        if !older.isEmpty { out.append(Section(title: "Older map versions", items: older)) }
        return out
    }

    /// "48 MB" / "820 KB".
    public static func bytesText(_ b: Int?) -> String {
        guard let b, b > 0 else { return "" }
        if b >= 1_048_576 { return String(format: "%.0f MB", Double(b) / 1_048_576) }
        return String(format: "%.0f KB", Double(b) / 1024)
    }
}

/// Memory budget for the native splat renderer (MetalSplatter keeps 32 B/splat on the GPU plus sort buffers).
public enum SplatBudget {
    /// Max splats by device RAM: 8 GB phones (15 Pro / 16 Pro) 1.5 M, 6 GB 1.0 M, less 0.5 M.
    public static func maxSplats(physicalMemoryBytes: UInt64) -> Int {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824
        if gb >= 7.5 { return 1_500_000 }
        if gb >= 5.5 { return 1_000_000 }
        return 500_000
    }

    public static let bytesPerSplat = 32

    /// Bytes of the .splat file to load: a whole number of 32-byte records, at most `maxSplats` (the server orders
    /// `splat_mobile.splat` most-important-first, so the prefix is the best smaller splat).
    public static func loadBytes(fileBytes: Int, maxSplats: Int) -> Int {
        let n = min(fileBytes / bytesPerSplat, max(0, maxSplats))
        return n * bytesPerSplat
    }
}

/// Offline cache policy: keep the last viewed scan always; evict least-recently-used others above the budget.
public struct ScanCachePolicy {
    public struct Entry: Equatable {
        public var key: String
        public var bytes: Int
        public var lastUsed: Double
        public init(key: String, bytes: Int, lastUsed: Double) { self.key = key; self.bytes = bytes; self.lastUsed = lastUsed }
    }

    public var budgetBytes: Int
    public init(budgetBytes: Int = 600 * 1_048_576) { self.budgetBytes = budgetBytes }

    /// Keys to delete so the total fits the budget; `keep` (the scan on screen / last viewed) is never evicted.
    public func evictions(_ entries: [Entry], keep: String?) -> [String] {
        var total = entries.reduce(0) { $0 + $1.bytes }
        var out: [String] = []
        for e in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > budgetBytes {
            if e.key == keep { continue }
            out.append(e.key)
            total -= e.bytes
        }
        return out
    }

    /// File-system safe cache folder name for a scan id (`site@5` → `site_5`).
    public static func folderName(_ id: String) -> String {
        String(id.unicodeScalars.map { c -> Character in
            let ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "."
            return ok ? Character(c) : "_"
        })
    }
}

extension SplatBudget {
    /// Further cap by what the app may still allocate now (os_proc_available_memory): keep `reserveMB` free and count
    /// ~64 B per splat (32 B GPU record + sort keys/indices). nil availability = no extra cap.
    public static func fit(maxSplats: Int, availableMB: Double?, reserveMB: Double = 500) -> Int {
        guard let a = availableMB else { return maxSplats }
        let n = Int(max(0, (a - reserveMB)) * 1_048_576 / 64)
        return max(0, min(maxSplats, n))
    }
}

/// One record of an antimatter15 `.splat` file (32 bytes, little-endian): position f32×3, linear scale f32×3,
/// RGBA u8×4 (sRGB colour + linear opacity), rotation u8×4 (w, x, y, z; q = (b − 128) / 128).
public struct DotSplatRecord: Equatable {
    public var position: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var rgba: SIMD4<UInt8>
    public var rotation: simd_quatf

    public static let byteWidth = 32
    public static let shC0: Float = 0.28209479177387814

    public static func decode(_ p: UnsafeRawPointer) -> DotSplatRecord {
        func f(_ i: Int) -> Float { Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
        func b(_ i: Int) -> UInt8 { p.load(fromByteOffset: 24 + i, as: UInt8.self) }
        let q = simd_quatf(ix: Float(b(5)) - 128, iy: Float(b(6)) - 128, iz: Float(b(7)) - 128, r: Float(b(4)) - 128)
        return DotSplatRecord(position: SIMD3(f(0), f(1), f(2)), scale: SIMD3(f(3), f(4), f(5)),
                              rgba: SIMD4(b(0), b(1), b(2), b(3)),
                              rotation: simd_length(q.vector) > 0 ? q.normalized : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    /// Degree-0 spherical-harmonic colour (what MetalSplatter's shader takes): (sRGB − 0.5) / C0.
    public var sh0: SIMD3<Float> { (SIMD3<Float>(Float(rgba.x), Float(rgba.y), Float(rgba.z)) / 255 - 0.5) / Self.shC0 }
    public var opacity: Float { Float(rgba.w) / 255 }
}
