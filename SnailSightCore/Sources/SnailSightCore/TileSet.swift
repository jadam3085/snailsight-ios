import Foundation

// SnailSight 11.0 tile streaming (live shared-map plan §3.2 / M2, API §5.12). The map server publishes the house map as
// a 3D Tiles 1.1 explicit tileset in the MAP frame (z up, metres): 4 m leaves ("L/tx/ty"), 8/16/32/64 m parents
// ("L/size/tx/ty"), REPLACE refinement. Every node carries `extras` {key, level, size_m, rev, triangles, mem, usdz {uri,
// bytes}, glb_bytes}; content URIs are relative to the tileset's own URL ("../../../blobs/<sha256>.usdz" from
// /v1/maps/site/tiles/tileset.json, "<sha256>.usdz" from /v1/blobs/<hash>.json). Blobs are immutable: cache by hash.
// Pure parsing + URL resolution here (Linux-tested, TileSelectTests).

/// The `tiles` block of `GET /v1/maps/site/head` (nil / absent while the server has no tileset yet).
public struct MapTiles: Codable, Equatable {
    public struct Tileset: Codable, Equatable {
        public var hash: String
        public var bytes: Int?
        public var url: String?
        public var stableURL: String?

        enum CodingKeys: String, CodingKey { case hash, bytes, url, stableURL = "stable_url" }

        public init(hash: String, bytes: Int? = nil, url: String? = nil, stableURL: String? = nil) {
            self.hash = hash; self.bytes = bytes; self.url = url; self.stableURL = stableURL
        }
    }

    public var rev: Int
    public var tilesets: [String: Tileset]
    public var defaultVariant: String?

    enum CodingKeys: String, CodingKey { case rev, tilesets, defaultVariant = "default_variant" }

    public init(rev: Int, tilesets: [String: Tileset], defaultVariant: String? = "structure") {
        self.rev = rev; self.tilesets = tilesets; self.defaultVariant = defaultVariant
    }

    /// Lenient: an unexpected field never breaks the head (MapFollower must keep working whatever `tiles` holds).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = (try? c.decode(Int.self, forKey: .rev)) ?? 0
        tilesets = (try? c.decode([String: Tileset].self, forKey: .tilesets)) ?? [:]
        defaultVariant = try? c.decodeIfPresent(String.self, forKey: .defaultVariant)
    }

    /// The variant to draw: the wanted one when the server has it, else the server's default, else any.
    public func variant(raw: Bool) -> String? {
        let want = raw ? "raw" : "structure"
        if tilesets[want] != nil { return want }
        if let d = defaultVariant, tilesets[d] != nil { return d }
        return tilesets.keys.sorted().first
    }

    /// Where to GET the tileset of a variant (the stable URL: content URIs are rewritten relative to it).
    public func tilesetPath(_ variant: String) -> String? {
        guard let t = tilesets[variant] else { return nil }
        return t.stableURL ?? t.url ?? "/v1/blobs/\(t.hash).json"
    }
}

/// One tile of the tree, as the selection sees it (tileselect.py `Node`).
public final class TileNode {
    public let key: String
    public let level: Int
    public let size: Int
    /// 3D Tiles box: [cx, cy, cz, hx, 0, 0, 0, hy, 0, 0, 0, hz] (axis aligned, map frame).
    public let box: [Double]
    public let error: Double
    /// usdz blob URI as written in the tileset (relative); nil = a node without content of its own.
    public let uri: String?
    public let bytes: Int
    /// Estimated GPU bytes when drawn.
    public let mem: Int
    public let rev: Int?
    public let triangles: Int
    public let children: [TileNode]

    public init(key: String, level: Int = 0, size: Int, box: [Double], error: Double = 0, uri: String?, bytes: Int = 0,
                mem: Int, rev: Int? = nil, triangles: Int = 0, children: [TileNode] = []) {
        self.key = key; self.level = level; self.size = size; self.box = box; self.error = error; self.uri = uri
        self.bytes = bytes; self.mem = mem; self.rev = rev; self.triangles = triangles; self.children = children
    }

    public var center: (Double, Double, Double) { (box[0], box[1], box[2]) }
    public var half: (Double, Double, Double) { (box[3], box[7], box[11]) }

    /// The content hash of the usdz ("<sha256>" of ".../<sha256>.usdz"), the disk-cache key.
    public var hash: String? { uri.flatMap(TileURL.blobHash) }
}

/// Codable form of the tileset JSON (only what the client uses).
public struct TilesetDoc: Decodable {
    public struct Volume: Decodable { public var box: [Double]? }
    public struct Content: Decodable { public var uri: String }
    public struct Usdz: Decodable { public var uri: String; public var bytes: Int? }
    public struct Extras: Decodable {
        public var key: String?
        public var level: Int?
        public var sizeM: Int?
        public var rev: Int?
        public var triangles: Int?
        public var mem: Int?
        public var usdz: Usdz?
        public var glbBytes: Int?
        enum CodingKeys: String, CodingKey {
            case key, level, rev, triangles, mem, usdz, sizeM = "size_m", glbBytes = "glb_bytes"
        }
    }
    public struct RootExtras: Decodable {
        public var mapID: String?
        public var rev: Int?
        public var variant: String?
        enum CodingKeys: String, CodingKey { case rev, variant, mapID = "map_id" }
    }
    public final class Node: Decodable {
        public var boundingVolume: Volume
        public var geometricError: Double?
        public var refine: String?
        public var content: Content?
        public var children: [Node]?
        public var extras: Extras?
    }
    public var root: Node
    public var extras: RootExtras?
}

public enum TileSet {
    /// Top-level nodes (the per-level 64 m roots) of a SnailSight tileset (tileselect.py `parse`).
    public static func parse(_ data: Data) throws -> [TileNode] {
        let doc = try JSONDecoder().decode(TilesetDoc.self, from: data)
        return (doc.root.children ?? []).map(node)
    }

    /// The tileset's own rev / variant (extras), if present.
    public static func info(_ data: Data) -> (rev: Int?, variant: String?) {
        guard let d = try? JSONDecoder().decode(TilesetDoc.self, from: data) else { return (nil, nil) }
        return (d.extras?.rev, d.extras?.variant)
    }

    static func node(_ n: TilesetDoc.Node) -> TileNode {
        let ex = n.extras
        let box = n.boundingVolume.box ?? [Double](repeating: 0, count: 12)
        return TileNode(key: ex?.key ?? "", level: ex?.level ?? 0, size: ex?.sizeM ?? 0,
                        box: box.count >= 12 ? box : box + [Double](repeating: 0, count: 12 - box.count),
                        error: n.geometricError ?? 0, uri: ex?.usdz?.uri, bytes: ex?.usdz?.bytes ?? 0,
                        mem: ex?.mem ?? 0, rev: ex?.rev, triangles: ex?.triangles ?? 0,
                        children: (n.children ?? []).map(node))
    }

    /// Every node, depth first (parents before children).
    public static func flatten(_ roots: [TileNode]) -> [TileNode] {
        var out: [TileNode] = []
        func walk(_ n: TileNode) { out.append(n); n.children.forEach(walk) }
        roots.forEach(walk)
        return out
    }
}

/// Relative URI resolution (RFC 3986 §5.2, paths only) for the tileset's content URIs.
public enum TileURL {
    /// Resolve `ref` against `base` (a path like "/v1/maps/site/tiles/tileset.json?variant=structure" or a full URL).
    /// Absolute refs ("/…", "http://…") are returned as they are.
    public static func resolve(_ ref: String, against base: String) -> String {
        if ref.hasPrefix("/") || ref.contains("://") { return ref }
        var b = base
        if let q = b.firstIndex(where: { $0 == "?" || $0 == "#" }) { b = String(b[..<q]) }
        var prefix = ""
        var path = b
        if let r = b.range(of: "://") {                       // keep scheme://host, resolve the path part
            let rest = b[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                prefix = String(b[..<slash])
                path = String(b[slash...])
            } else {
                prefix = b
                path = "/"
            }
        }
        let dir: String
        if let i = path.lastIndex(of: "/") { dir = String(path[...i]) } else { dir = "/" }
        return prefix + removeDots(dir + ref)
    }

    static func removeDots(_ p: String) -> String {
        var out: [Substring] = []
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        for (i, s) in parts.enumerated() {
            if s == "." { if i == parts.count - 1 { out.append("") }; continue }
            if s == ".." {
                if out.count > 1 { out.removeLast() }
                if i == parts.count - 1 { out.append("") }
                continue
            }
            out.append(s)
        }
        var r = out.joined(separator: "/")
        if !r.hasPrefix("/") { r = "/" + r }
        return r
    }

    /// "<sha256>" from ".../blobs/<sha256>.usdz" (64 lowercase hex), nil otherwise.
    public static func blobHash(_ uri: String) -> String? {
        let name = uri.split(separator: "/").last.map(String.init) ?? uri
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        guard stem.count == 64, stem.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return stem
    }
}
