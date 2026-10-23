import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// SnailSight 12.8 runtime sim content: spawnable characters (the Helix lab's) arrive from the map server at RUNTIME, so a
// new character needs no app release. GET /v1/sim/content returns catalog items in the bundled catalog.json shape plus
// `blobs` (file name → sha256 + bytes); every file is fetched once from /v1/sim/content/blobs/<sha256>.<ext> (content
// addressed, immutable) and cached on the device. Bundled models stay the fallback. These helpers are pure (tested in
// SimContentTests); the app's SimContentStore does the I/O.

public struct SimBlobRef: Codable, Equatable {
    public var sha256: String
    public var bytes: Int?
    public init(sha256: String, bytes: Int? = nil) { self.sha256 = sha256; self.bytes = bytes }
}

public struct SimClipInfo: Codable, Equatable {
    public var action: String?
    public var loop: Bool?
    public var durationS: Double?
    enum CodingKeys: String, CodingKey { case action, loop, durationS = "duration_s" }
    public init(action: String? = nil, loop: Bool? = nil, durationS: Double? = nil) {
        self.action = action; self.loop = loop; self.durationS = durationS
    }
}

public struct SimContentRejected: Codable, Equatable {
    public var key: String
    public var label: String?
    public var reasons: [String]?
    public var warnings: [String]?
}

/// The server's runtime content document (GET /v1/sim/content).
public struct SimContentDoc: Codable, Equatable {
    public var version: Int
    public var rev: String
    public var updated: String?
    public var blobPath: String?
    public var items: [SimCatalogItem]
    public var rejected: [SimContentRejected]?
    /// 12.9: served low-poly models ("robot" = RobosnailBob, "drone"); absent = the compiled-in drawings
    public var agents: [String: SimAgentModel]?

    enum CodingKeys: String, CodingKey { case version, rev, updated, items, rejected, agents, blobPath = "blob_path" }

    public init(version: Int = 1, rev: String, updated: String? = nil, blobPath: String? = nil, items: [SimCatalogItem],
                rejected: [SimContentRejected]? = nil, agents: [String: SimAgentModel]? = nil) {
        self.version = version; self.rev = rev; self.updated = updated; self.blobPath = blobPath; self.items = items
        self.rejected = rejected; self.agents = agents
    }

    public static func decode(_ data: Data) throws -> SimContentDoc { try JSONDecoder().decode(SimContentDoc.self, from: data) }

    /// One malformed item (an unknown category …) is skipped, never the whole document; a malformed `agents` entry too.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        rev = try c.decode(String.self, forKey: .rev)
        updated = try? c.decode(String.self, forKey: .updated)
        blobPath = try? c.decode(String.self, forKey: .blobPath)
        rejected = try? c.decode([SimContentRejected].self, forKey: .rejected)
        items = (try? c.decode([Lossy<SimCatalogItem>].self, forKey: .items))?.compactMap(\.value) ?? []
        agents = (try? c.decode([String: Lossy<SimAgentModel>].self, forKey: .agents))?.compactMapValues(\.value)
    }

    struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from d: Decoder) throws { value = try? T(from: d) }
    }
}

public enum SimContent {
    public static let defaultBlobPath = "/v1/sim/content/blobs/"
    /// Clips the app draws from the body's motion; everything else in `files` is a gesture candidate.
    public static let locomotion: Set<String> = ["idle", "walk", "run", "eat", "static"]
    /// File types the phone needs (the .glb web twin is the portal's).
    public static let phoneExtensions: Set<String> = ["usdz", "png"]

    public static func isSHA(_ s: String) -> Bool {
        s.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func ext(_ file: String) -> String { (file as NSString).pathExtension.lowercased() }

    /// "<sha256>.<ext>" — the cache / URL name of a file's blob (nil for a malformed hash or no extension).
    public static func blobName(file: String, ref: SimBlobRef) -> String? {
        let e = ext(file)
        guard isSHA(ref.sha256), !e.isEmpty, e.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "\(ref.sha256).\(e)"
    }

    /// Server path of a blob.
    public static func blobPath(_ name: String, base: String?) -> String {
        var b = base ?? defaultBlobPath
        if b.isEmpty { b = defaultBlobPath }
        if !b.hasSuffix("/") { b += "/" }
        return b + name
    }

    /// The phone files of an item (every clip file + the thumbnail) with their blob refs; nil when any phone file has
    /// no valid blob ref (the item is unusable at runtime: never half-shown).
    public static func phoneFiles(_ item: SimCatalogItem) -> [(file: String, blob: String, ref: SimBlobRef)]? {
        var names = Set((item.files ?? [:]).values)
        if let t = item.thumb { names.insert(t) }
        names = names.filter { phoneExtensions.contains(ext($0)) }
        guard !names.isEmpty, let blobs = item.blobs else { return nil }
        var out: [(String, String, SimBlobRef)] = []
        for f in names.sorted() {
            guard let r = blobs[f], let b = blobName(file: f, ref: r) else { return nil }
            out.append((f, b, r))
        }
        return out
    }

    /// Blobs still to download for these items (unique by blob name, in item order), given what is on disk.
    public static func missing(_ items: [SimCatalogItem], have: Set<String>) -> [(blob: String, ref: SimBlobRef)] {
        var seen = Set<String>(), out: [(String, SimBlobRef)] = []
        for it in items {
            for f in phoneFiles(it) ?? [] where !have.contains(f.blob) && seen.insert(f.blob).inserted {
                out.append((f.blob, f.ref))
            }
        }
        return out
    }

    /// Items whose every phone file is on disk (only these are exposed).
    public static func ready(_ items: [SimCatalogItem], have: Set<String>) -> [SimCatalogItem] {
        items.filter { it in
            guard let fs = phoneFiles(it) else { return false }
            return fs.allSatisfy { have.contains($0.blob) }
        }
    }

    /// Blob names referenced by these docs (keep these when pruning; the caller passes the current + previous rev).
    public static func referenced(_ docs: [SimContentDoc]) -> Set<String> {
        var s = Set<String>()
        for d in docs { for it in d.items { for f in phoneFiles(it) ?? [] { s.insert(f.blob) } } }
        return s
    }

    /// The local file for a catalog file name of a runtime item (nil = not a runtime file → use the bundle).
    public static func blob(for file: String, in items: [SimCatalogItem]) -> String? {
        for it in items {
            if let r = it.blobs?[file], let b = blobName(file: file, ref: r) { return b }
        }
        return nil
    }

    /// Bundled items first (bundled order, a runtime item with the same key replaces it in place), then new runtime
    /// items in server order.
    public static func merge(bundled: SimCatalog, runtime: [SimCatalogItem]) -> SimCatalog {
        var byKey: [String: SimCatalogItem] = [:]
        for r in runtime where byKey[r.key] == nil { byKey[r.key] = r }
        var out: [SimCatalogItem] = []
        var used = Set<String>()
        for b in bundled.items {
            if let r = byKey[b.key] { out.append(r); used.insert(b.key) } else { out.append(b) }
        }
        for r in runtime where !used.contains(r.key) { out.append(r); used.insert(r.key) }
        return SimCatalog(version: bundled.version, items: out)
    }

    /// One-shot gesture clips of an item (clip_info loop == false, with a file), sorted.
    public static func gestures(_ item: SimCatalogItem) -> [String] {
        let files = item.files ?? [:]
        return (item.clipInfo ?? [:]).filter { $0.value.loop == false && files[$0.key] != nil && !locomotion.contains($0.key) }
            .map(\.key).sorted()
    }

    public static func isGesture(_ item: SimCatalogItem?, clip: String) -> Bool {
        guard let it = item else { return false }
        return it.clipInfo?[clip]?.loop == false
    }

    /// "think" → "Think", "thumbs_up" → "Thumbs up".
    public static func gestureLabel(_ clip: String) -> String {
        let s = clip.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: sha256

    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return sha256HexPortable(data)
        #endif
    }

    public static func verify(_ data: Data, ref: SimBlobRef) -> Bool {
        if let n = ref.bytes, n != data.count { return false }
        return sha256Hex(data) == ref.sha256.lowercased()
    }

    /// Plain-Swift SHA-256 (FIPS 180-4): the Linux test path and a CryptoKit cross-check.
    public static func sha256HexPortable(_ data: Data) -> String {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        var off = 0
        while off < msg.count {
            for t in 0..<16 {
                let j = off + t * 4
                w[t] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[t] &+ w[t]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            off += 64
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
