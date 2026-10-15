import Foundation

// 10.2 "Map mesh" (owner: "Otherwise do a non-splat data collection just for colored mesh?"): while the toggle is on
// (or automatically once localized, Settings), the phone collects what the server's mesh-first pipeline needs and
// nothing else — LiDAR depth at a low rate (+ a small colour image for vertex colour), occasional SHARP full-resolution
// colour keyframes (motion/blur-gated, every ~0.75 m or 20°), ARKit scene-reconstruction mesh anchors, and the
// map alignment of the ARKit session — with no continuous video, no audio. Chunks are spooled to disk and uploaded
// one by one (resumable) to `PUT /v1/meshmap/{upload_id}/chunks/{seq}` (API §5.10); the server fuses the new depth into
// the house mesh for the covered 4 m tiles and re-bakes their texture, producing a new map version.
// Everything here is pure (no ARKit / URLSession / file system) so the Linux CI tests it; the app side is
// Sources/MeshMap/MeshMapper.swift.

// MARK: - ids

public enum MeshMapID {
    /// "mm-20261015-142233-a1b2c3": UTC start time + 24 random bits.
    public static func make(date: Date, random: UInt32 = UInt32.random(in: .min ... .max)) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "mm-" + f.string(from: date) + "-" + String(format: "%06x", random & 0xFFFFFF)
    }

    /// The server's rule: ^mm-[A-Za-z0-9_-]{4,60}$
    public static func isValid(_ s: String) -> Bool {
        guard s.hasPrefix("mm-") else { return false }
        let rest = s.dropFirst(3)
        guard (4...60).contains(rest.count) else { return false }
        return rest.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
    }
}

// MARK: - chunk wire format (SSMM)

public enum MeshMapKind: String, CaseIterable {
    case depth, keyframe, mesh, align
}

/// The phone's map alignment at capture time (MapLocalizer's T_map_arkit).
public struct MeshMapAlign: Equatable {
    public var T: [Double]              // T_map_arkit, row-major 16
    public var version: Int
    public var method: String?
    public var errCm: Double?
    public init(T: [Double], version: Int, method: String? = nil, errCm: Double? = nil) {
        self.T = T; self.version = version; self.method = method; self.errCm = errCm
    }
}

public enum MeshMapChunk {
    public static let magic: [UInt8] = Array("SSMM".utf8)
    public static let maxBytes = 8 * 1024 * 1024          // server: 413 above

    private static func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// Header of a `depth` / `keyframe` chunk (blobs are added by `encode`).
    public static func frameHeader(kind: MeshMapKind, seq: Int, streamID: String, t: Double, wall: Double,
                                   T: [Double], K: [Double], imageSize: [Int], align: MeshMapAlign?,
                                   sharpness: Double? = nil, blurPx: Double? = nil) -> [String: Any] {
        var h: [String: Any] = ["kind": kind.rawValue, "seq": seq, "stream_id": streamID, "t": fin(t), "wall": fin(wall),
                                "T_arkit_cam": T.map(fin), "K": K.map(fin), "image_size": imageSize]
        if let a = align, a.T.count == 16 {
            h["T_map_arkit"] = a.T.map(fin)
            h["map_version"] = a.version
            if let m = a.method { h["align_method"] = m }
            if let e = a.errCm, e.isFinite { h["align_err_cm"] = e }
        }
        if let s = sharpness, s.isFinite { h["sharpness"] = s }
        if let b = blurPx, b.isFinite { h["blur_px"] = b }
        return h
    }

    /// `align` chunk: the stream's newest alignment (lock / refinement), so frames captured before the lock can use it.
    public static func alignHeader(seq: Int, streamID: String, t: Double, wall: Double, align: MeshMapAlign,
                                   spreadCm: Double? = nil) -> [String: Any] {
        var h: [String: Any] = ["kind": MeshMapKind.align.rawValue, "seq": seq, "stream_id": streamID, "t": fin(t),
                                "wall": fin(wall), "T_map_arkit": align.T.map(fin), "map_version": align.version,
                                "at": fin(wall)]
        if let m = align.method { h["method"] = m }
        if let e = align.errCm, e.isFinite { h["err_cm"] = e }
        if let s = spreadCm, s.isFinite { h["spread_cm"] = s }
        return h
    }

    /// `mesh` chunk header: one entry per anchor, blob name = "a<k>".
    public static func meshHeader(seq: Int, streamID: String, t: Double, wall: Double,
                                  anchors: [MeshAnchorEntry]) -> [String: Any] {
        ["kind": MeshMapKind.mesh.rawValue, "seq": seq, "stream_id": streamID, "t": fin(t), "wall": fin(wall),
         "anchors": anchors.enumerated().map { k, a -> [String: Any] in
             ["id": a.id, "T_arkit_anchor": a.T.map(fin), "vertices": a.vertices, "faces": a.faces, "blob": "a\(k)"]
         }]
    }

    /// `b"SSMM"` + uint32 big-endian header length + header JSON + blobs (the SSKF framing of API §6b). The header's
    /// `blobs` = [[name, length], …] in payload order is filled in here. nil if the header is not valid JSON.
    public static func encode(header: [String: Any], blobs: [(name: String, data: Data)]) -> Data? {
        var h = header
        h["blobs"] = blobs.map { [$0.name, $0.data.count] as [Any] }
        guard JSONSerialization.isValidJSONObject(h),
              let json = try? JSONSerialization.data(withJSONObject: h, options: [.sortedKeys]) else { return nil }
        var out = Data(capacity: 8 + json.count + blobs.reduce(0) { $0 + $1.data.count })
        out.append(contentsOf: magic)
        let n = UInt32(json.count)
        out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(json)
        for b in blobs { out.append(b.data) }
        return out
    }

    public static func parse(_ data: Data) -> (header: [String: Any], blobs: [(name: String, data: Data)])? {
        let b = [UInt8](data)
        guard b.count >= 8, Array(b[0..<4]) == magic else { return nil }
        let n = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        guard b.count >= 8 + n,
              let obj = (try? JSONSerialization.jsonObject(with: Data(b[8..<(8 + n)]))) as? [String: Any],
              let list = obj["blobs"] as? [[Any]] else { return nil }
        var off = 8 + n
        var out: [(name: String, data: Data)] = []
        for item in list {
            guard item.count == 2, let name = item[0] as? String, let len = (item[1] as? NSNumber)?.intValue,
                  len >= 0, off + len <= b.count else { return nil }
            out.append((name: name, data: Data(b[off..<(off + len)])))
            off += len
        }
        guard off == b.count else { return nil }
        return (obj, out)
    }
}

// MARK: - capture gate

/// Which frames become chunks. Depth: at most `depthRateHz`, only after ≥ 10 cm / 8° of motion (a still phone sends
/// nothing). Colour keyframe: every ~0.75 m or 20° (≥ 0.8 s apart), taken on the first frame whose predicted motion blur
/// is ≤ 2 px, or after 1.5 s of waiting the first ≤ 6 px; a keyframe also carries that frame's depth.
/// Thermal serious: half the depth rate, keyframes 1.5× further apart and 2× rarer.
public struct MeshMapGate {
    public enum Decision: Equatable { case skip, depth, keyframe }

    public static let depthRateHz = 2.0
    public static let depthMinMoveM = 0.10
    public static let depthMinTurnDeg = 8.0
    public static let kfMetres = 0.75
    public static let kfDegrees = 20.0
    public static let kfMinInterval = 0.8
    public static let kfMaxWait = 1.5
    public static let blurOK = 2.0
    public static let blurLate = 6.0

    public private(set) var lastDepthT: Double?
    private var lastDepthPos: [Double]?
    private var lastDepthQ: CaptureFormat.Quat?
    public private(set) var lastKfT: Double?
    private var lastKfPos: [Double]?
    private var lastKfQ: CaptureFormat.Quat?
    public private(set) var kfDueSince: Double?

    public init() {}

    public mutating func reset() { self = MeshMapGate() }

    static func quat(_ T: [Double]) -> CaptureFormat.Quat {
        CaptureFormat.quaternion(rows: [[T[0], T[1], T[2]], [T[4], T[5], T[6]], [T[8], T[9], T[10]]])
    }

    static func dist(_ a: [Double], _ T: [Double]) -> Double {
        let dx = T[3] - a[0], dy = T[7] - a[1], dz = T[11] - a[2]
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// `T` = row-major camera → world (ARKit); `blurPx` = predicted motion blur (KeyframeQuality), nil = unknown.
    public mutating func decide(t: Double, T: [Double], blurPx: Double?, hot: Bool = false) -> Decision {
        guard T.count == 16 else { return .skip }
        let q = Self.quat(T)
        // keyframe due?
        var due = false
        if let lt = lastKfT, let lp = lastKfPos, let lq = lastKfQ {
            let gap = Self.kfMinInterval * (hot ? 2 : 1)
            let metres = Self.kfMetres * (hot ? 1.5 : 1)
            if t - lt >= gap && (Self.dist(lp, T) >= metres || AdaptiveCapture.rotationDegrees(lq, q) >= Self.kfDegrees) {
                due = true
            }
        } else {
            due = true
        }
        if due {
            if kfDueSince == nil { kfDueSince = t }
            let waited = t - (kfDueSince ?? t)
            let b = blurPx ?? 0
            if b <= Self.blurOK || (waited >= Self.kfMaxWait && b <= Self.blurLate) { return .keyframe }
        } else {
            kfDueSince = nil
        }
        // depth
        let rate = Self.depthRateHz * (hot ? 0.5 : 1)
        if let lt = lastDepthT, let lp = lastDepthPos, let lq = lastDepthQ {
            if t - lt < 1 / rate - 0.005 { return .skip }
            if Self.dist(lp, T) < Self.depthMinMoveM && AdaptiveCapture.rotationDegrees(lq, q) < Self.depthMinTurnDeg {
                return .skip
            }
        }
        return .depth
    }

    /// The decided frame was captured (call only when it really was: an encoder that is busy skips the commit, so the
    /// next frame is offered again).
    public mutating func commit(_ d: Decision, t: Double, T: [Double]) {
        guard T.count == 16, d != .skip else { return }
        let p = [T[3], T[7], T[11]], q = Self.quat(T)
        lastDepthT = t; lastDepthPos = p; lastDepthQ = q
        if d == .keyframe {
            lastKfT = t; lastKfPos = p; lastKfQ = q
            kfDueSince = nil
        }
    }
}

// MARK: - mesh anchors

/// One ARKit mesh anchor in a `mesh` chunk.
public struct MeshAnchorEntry: Equatable {
    public var id: String
    public var T: [Double]              // T_arkit_anchor, row-major 16
    public var vertices: Int
    public var faces: Int
    public init(id: String, T: [Double], vertices: Int, faces: Int) {
        self.id = id; self.T = T; self.vertices = vertices; self.faces = faces
    }
}

/// Which mesh anchors to (re)send: new ones, and ones whose vertex count changed by ≥ 15 % no sooner than 10 s after
/// they were last sent (ARKit refines anchors continuously; the server keeps the newest copy per anchor id).
public struct MeshAnchorTracker {
    public static let minChangeFrac = 0.15
    public static let minGapS = 10.0
    public static let maxBytesPerChunk = 3 * 1024 * 1024

    private var sent: [String: (vertices: Int, at: Double)] = [:]
    public init() {}

    public var count: Int { sent.count }

    public func wants(id: String, vertices: Int, now: Double) -> Bool {
        guard vertices > 0 else { return false }
        guard let s = sent[id] else { return true }
        guard now - s.at >= Self.minGapS else { return false }
        let change = Double(abs(vertices - s.vertices)) / Double(max(s.vertices, 1))
        return change >= Self.minChangeFrac
    }

    public mutating func didSend(id: String, vertices: Int, now: Double) { sent[id] = (vertices, now) }
    public mutating func removed(id: String) { sent[id] = nil }
    public mutating func reset() { sent = [:] }
}

/// Anchor geometry blob: little-endian float32 xyz × n (anchor-local metres) + uint32 indices × 3m.
public enum MeshAnchorPack {
    public static func encode(vertices: [Float], faces: [UInt32]) -> Data {
        var out = Data(capacity: vertices.count * 4 + faces.count * 4)
        for v in vertices { var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        for i in faces { var x = i.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        return out
    }

    public static func decode(_ d: Data, vertices n: Int, faces m: Int) -> (vertices: [Float], faces: [UInt32])? {
        let b = [UInt8](d)
        guard b.count == n * 12 + m * 12 else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        let v = (0..<(n * 3)).map { Float(bitPattern: u32($0 * 4)) }
        let f = (0..<(m * 3)).map { u32(n * 12 + $0 * 4) }
        return (v, f)
    }
}

// MARK: - policy

public enum MeshMapPolicy {
    /// Mapping wanted at all: the toggle, or "auto when localized" while localized.
    public static func wanted(toggle: Bool, auto: Bool, localized: Bool) -> Bool { toggle || (auto && localized) }

    /// Why a wanted mapping is paused right now (nil = capturing).
    public static func pauseReason(recording: Bool, scansOpen: Bool, thermalCritical: Bool, trackingNormal: Bool,
                                   meshSupported: Bool, depthSupported: Bool, spoolFull: Bool) -> String? {
        if !depthSupported || !meshSupported { return "no LiDAR" }
        if recording { return "recording" }
        if scansOpen { return "Scans open" }
        if thermalCritical { return "too hot" }
        if spoolFull { return "storage full" }
        if !trackingNormal { return "tracking" }
        return nil
    }
}

// MARK: - upload ledger (persisted next to the spooled chunks)

/// One mapping upload: Documents/meshmap/<upload_id>/ledger.json + chunks/<seq>.ssmm. Seqs are contiguous from 0 and
/// assigned only to chunks that were written to disk; `ackedThrough` = the server's `have_contiguous`.
public struct MeshMapLedger: Codable, Equatable {
    public enum State: String, Codable { case capturing, finishing, processing, done, failed, empty }

    public var uploadID: String
    public var mapID: String
    public var created: Double
    public var nextSeq = 0
    public var ackedThrough = -1
    public var registered = false                   // PUT /v1/meshmap/{id} answered
    public var counts: [String: Int] = [:]
    public var bytes: Int64 = 0                     // written to the spool
    public var sentBytes: Int64 = 0
    public var state: State = .capturing
    public var lastSeq: Int?                        // set when capture stopped (finish body)
    public var serverState: String?
    public var resultVersion: Int?
    public var resultText: String?
    public var error: String?
    public var updated: Double = 0

    public init(uploadID: String, mapID: String, created: Double) {
        self.uploadID = uploadID; self.mapID = mapID; self.created = created; self.updated = created
    }

    public var keyframes: Int { counts[MeshMapKind.keyframe.rawValue] ?? 0 }
    public var frames: Int { (counts[MeshMapKind.depth.rawValue] ?? 0) + keyframes }
    /// Chunks written but not yet confirmed by the server.
    public var pending: Int { max(0, nextSeq - 1 - ackedThrough) }

    /// A chunk of `kind` was spooled: its seq.
    public mutating func add(_ kind: MeshMapKind, bytes n: Int, now: Double) -> Int {
        let s = nextSeq
        nextSeq += 1
        counts[kind.rawValue, default: 0] += 1
        bytes += Int64(n)
        updated = now
        return s
    }

    /// Server answer for a chunk PUT: `haveContiguous` never goes backwards here (a restarted server re-reports).
    public mutating func acked(haveContiguous: Int, bytes n: Int, now: Double) {
        if haveContiguous > ackedThrough { ackedThrough = haveContiguous }
        sentBytes += Int64(n)
        updated = now
    }

    /// Capture is over: finish once everything is acknowledged. Nothing captured → `empty` (no server job).
    public mutating func stopCapture(now: Double) {
        guard state == .capturing else { return }
        lastSeq = nextSeq - 1
        state = .finishing
        updated = now
    }

    public var readyToFinish: Bool { state == .finishing && ackedThrough >= (lastSeq ?? Int.max) }
    public var terminal: Bool { state == .done || state == .failed || state == .empty }
}

/// GET /v1/meshmap/{id} (the parts the app uses).
public struct MeshMapStatus: Decodable, Equatable {
    public var uploadID: String
    public var state: String
    public var haveContiguous: Int?
    public var error: String?
    public var job: Job?
    public var result: Result?

    public struct Job: Decodable, Equatable {
        public var jobID: Int?
        public var state: String?
        enum CodingKeys: String, CodingKey { case jobID = "job_id", state }
    }
    public struct Result: Decodable, Equatable {
        public var mapID: String?
        public var baseVersion: Int?
        public var version: Int?
        public var cells: [[Int]]?
        public var framesUsed: Int?
        public var keyframesUsed: Int?
        public var trianglesAdded: Int?
        enum CodingKeys: String, CodingKey {
            case mapID = "map_id", baseVersion = "base_version", version, cells, framesUsed = "frames_used"
            case keyframesUsed = "keyframes_used", trianglesAdded = "triangles_added"
        }
    }
    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id", state, haveContiguous = "have_contiguous", error, job, result
    }
}

// MARK: - wording

public enum MeshMapText {
    public static func mb(_ bytes: Int64) -> String {
        let m = Double(bytes) / 1_048_576
        return m < 10 ? String(format: "%.1f MB", m) : String(format: "%.0f MB", m)
    }

    /// The small line under the localization pill: "mapping · 34 MB · 12 kf", "mapping · paused (too hot) · 34 MB",
    /// "mapping · 34 MB · 12 kf · offline, 40 queued", "uploading map · 6 left", "map update on the server…",
    /// "map updated v11 ✓".
    public static func line(capturing: Bool, paused: String?, ledger: MeshMapLedger?, online: Bool) -> String? {
        guard let l = ledger else { return capturing ? "mapping · starting" : nil }
        switch l.state {
        case .capturing:
            var s = "mapping"
            if let p = paused { s += " · paused (\(p))" }
            s += " · \(mb(l.bytes)) · \(l.keyframes) kf"
            if !online && l.pending > 0 { s += " · offline, \(l.pending) queued" }
            else if l.pending > 20 { s += " · \(l.pending) to send" }
            return s
        case .finishing:
            if !online { return "map upload waiting (offline) · \(l.pending) left" }
            return l.pending > 0 ? "uploading map · \(l.pending) left" : "uploading map · finishing"
        case .processing:
            return "map update on the server…"
        case .done:
            return l.resultVersion.map { "map updated v\($0) ✓" } ?? "map updated ✓"
        case .failed:
            return "map update failed" + (l.error.map { ": \($0)" } ?? "")
        case .empty:
            return nil
        }
    }

    /// Toast when the server finished.
    public static func done(_ s: MeshMapStatus) -> String {
        switch s.state {
        case "done":
            var t = "House map updated"
            if let v = s.result?.version { t += " · v\(v)" }
            if let c = s.result?.cells?.count, c > 0 { t += " · \(c) area\(c == 1 ? "" : "s") re-meshed" }
            if let k = s.result?.keyframesUsed, k > 0 { t += " · \(k) photos" }
            return t
        case "empty":
            return "Mapping: nothing new to add (no placed frames)"
        default:
            return "Map update failed" + (s.error.map { ": \($0)" } ?? "")
        }
    }
}
