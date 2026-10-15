import Foundation

// SnailSight 10 "Live map" (plan §8.9 L1, wire contract docs/SNAILSIGHT-API.md §6b): the phone streams keyframes to
// `WS /v1/agents/{agent_id}/live`. Everything here is pure (no URLSession / ARKit / file system) so the macOS CI runner
// tests it: the binary keyframe frame, the capture gate (rate + stillness), the resume / ack bookkeeping of the disk
// spool, the reconnect backoff and the HUD line. The app side is Sources/Live/LiveStreamer.swift.

// MARK: - stream ids

public enum LiveStreamID {
    /// "ar-" + 8 lowercase hex: one id per ARKit odometry frame (a new one after a reset / relocalization jump).
    public static func make(random: UInt32 = UInt32.random(in: .min ... .max)) -> String {
        "ar-" + String(format: "%08x", random)
    }

    public static func isValid(_ s: String) -> Bool {
        guard s.hasPrefix("ar-"), s.count == 11 else { return false }
        return s.dropFirst(3).unicodeScalars.allSatisfy { c in (c >= "0" && c <= "9") || (c >= "a" && c <= "f") }
    }
}

// MARK: - binary keyframe frame

/// Header of one keyframe (API §6b): everything except `blobs`, which `LiveKeyframe.encode` fills from the payloads.
public struct LiveKeyframeHeader: Equatable {
    public var seq: Int
    public var streamID: String
    public var t: Double                 // ARKit timestamp
    public var wall: Double              // UNIX time at capture
    public var T: [Double]               // T_arkit_cam, camera → world, row-major 16
    public var K: [Double]               // fx, fy, cx, cy for imageSize
    public var imageSize: [Int]          // [w, h] the size K refers to (camera.imageResolution)
    public var tracking: String

    public init(seq: Int, streamID: String, t: Double, wall: Double, T: [Double], K: [Double], imageSize: [Int],
                tracking: String = "normal") {
        self.seq = seq; self.streamID = streamID; self.t = t; self.wall = wall
        self.T = T; self.K = K; self.imageSize = imageSize; self.tracking = tracking
    }
}

public enum LiveKeyframe {
    public static let magic: [UInt8] = Array("SSKF".utf8)

    private static func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }   // JSONSerialization traps on NaN / inf

    /// The header JSON object, `blobs` = [[name, byteLength], …] in payload order.
    public static func headerObject(_ h: LiveKeyframeHeader, blobs: [(name: String, length: Int)]) -> [String: Any] {
        [
            "seq": h.seq,
            "stream_id": h.streamID,
            "t": fin(h.t),
            "wall": fin(h.wall),
            "T_arkit_cam": h.T.map(fin),
            "K": h.K.map(fin),
            "image_size": h.imageSize,
            "tracking": h.tracking,
            "blobs": blobs.map { [$0.name, $0.length] as [Any] },
        ]
    }

    /// `b"SSKF"` + uint32 big-endian header length + header JSON (UTF-8) + blobs back to back. nil only if the header
    /// cannot be serialised (never with finite numbers).
    public static func encode(_ h: LiveKeyframeHeader, blobs: [(name: String, data: Data)]) -> Data? {
        let obj = headerObject(h, blobs: blobs.map { (name: $0.name, length: $0.data.count) })
        guard JSONSerialization.isValidJSONObject(obj),
              let header = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return frame(header: header, blobs: blobs.map { $0.data })
    }

    public static func frame(header: Data, blobs: [Data]) -> Data {
        var out = Data(capacity: 8 + header.count + blobs.reduce(0) { $0 + $1.count })
        out.append(contentsOf: magic)
        let n = UInt32(header.count)
        out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(header)
        for b in blobs { out.append(b) }
        return out
    }

    /// Inverse of `encode` (tests, and reading a spooled file's seq / stream back). nil on any inconsistency.
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

    /// Row-major 4×4 from column vectors (simd_float4x4 `columns.0…3`, each [x, y, z, w]).
    public static func rowMajor(columns c: [[Double]]) -> [Double] {
        var m = [Double](repeating: 0, count: 16)
        for col in 0..<4 { for row in 0..<4 { m[row * 4 + col] = c[col][row] } }
        return m
    }
}

// MARK: - capture gate (rate + stillness)

/// Take a keyframe at most every 1 / rateHz s, and only when the phone moved ≥ 2 cm or turned ≥ 2° since the last
/// keyframe (a still phone sends nothing; no keep-alive frames).
public struct LiveGate {
    public enum Decision: Equatable { case capture, tooSoon, still }
    public static let minMoveM = 0.02
    public static let minTurnDeg = 2.0
    public static let allowedRates: [Double] = [1, 2]

    public var rateHz: Double
    public private(set) var lastT: Double?
    private var lastPos: [Double]?
    private var lastQ: CaptureFormat.Quat?

    public init(rateHz: Double = 2) { self.rateHz = Self.clampRate(rateHz) }

    public static func clampRate(_ r: Double) -> Double { r <= 1.5 ? 1 : 2 }

    public mutating func reset() { lastT = nil; lastPos = nil; lastQ = nil }

    /// `T` = row-major camera → world.
    public func check(t: Double, T: [Double]) -> Decision {
        guard T.count == 16, let lt = lastT, let lp = lastPos, let lq = lastQ else { return .capture }
        if t - lt < 1 / rateHz - 0.005 { return .tooSoon }          // 5 ms slack: 60 fps frames land on the grid
        let dx = T[3] - lp[0], dy = T[7] - lp[1], dz = T[11] - lp[2]
        let moved = (dx * dx + dy * dy + dz * dz).squareRoot()
        let turned = AdaptiveCapture.rotationDegrees(lq, Self.quat(T))
        return moved >= Self.minMoveM || turned >= Self.minTurnDeg ? .capture : .still
    }

    public mutating func commit(t: Double, T: [Double]) {
        guard T.count == 16 else { return }
        lastT = t
        lastPos = [T[3], T[7], T[11]]
        lastQ = Self.quat(T)
    }

    static func quat(_ T: [Double]) -> CaptureFormat.Quat {
        CaptureFormat.quaternion(rows: [[T[0], T[1], T[2]], [T[4], T[5], T[6]], [T[8], T[9], T[10]]])
    }
}

// MARK: - spool bookkeeping

/// One spooled keyframe file: Caches/livespool/<stream>/<seq>.kf; `order` = the stream's creation time.
public struct LiveSpoolKey: Hashable, Comparable {
    public var stream: String
    public var order: Double
    public var seq: Int
    public init(stream: String, order: Double, seq: Int) { self.stream = stream; self.order = order; self.seq = seq }
    public static func < (a: LiveSpoolKey, b: LiveSpoolKey) -> Bool {
        if a.order != b.order { return a.order < b.order }
        if a.stream != b.stream { return a.stream < b.stream }
        return a.seq < b.seq
    }
}

public enum LiveSpool {
    public static let cap = 2400
    public static let maxAgeS: Double = 24 * 3600

    public static func fileName(_ seq: Int) -> String { String(format: "%08d.kf", seq) }

    public static func seq(fromFile name: String) -> Int? {
        guard name.hasSuffix(".kf") else { return nil }
        return Int(name.dropLast(3))
    }

    /// On `welcome {last_seq}`: drop every spooled seq ≤ last_seq (the server has them contiguously), resend the rest
    /// in seq order.
    public static func afterWelcome(spooled: [Int], lastSeq: Int) -> (drop: [Int], resend: [Int]) {
        let s = spooled.sorted()
        return (s.filter { $0 <= lastSeq }, s.filter { $0 > lastSeq })
    }

    /// Spool over the cap: the oldest files go (oldest stream first, then lowest seq).
    public static func evictions(_ keys: [LiveSpoolKey], cap: Int = LiveSpool.cap) -> [LiveSpoolKey] {
        guard keys.count > cap else { return [] }
        return Array(keys.sorted().prefix(keys.count - cap))
    }
}

/// The send window for the stream the socket is bound to: seqs queued for (re)sending in seq order, at most `limit`
/// unacknowledged at once, re-queued when an ack does not come back in time.
public struct LiveWindow {
    public let limit: Int
    public private(set) var queued: [Int] = []          // sorted, not in flight
    public private(set) var inFlight: [Int: Double] = [:]   // seq → time sent
    public private(set) var resends: [Int: Int] = [:]

    public init(limit: Int = 8) { self.limit = max(1, limit) }

    public var pending: Int { queued.count + inFlight.count }
    public var isEmpty: Bool { queued.isEmpty && inFlight.isEmpty }

    /// After a welcome: exactly these seqs (any order) are to be sent; nothing is in flight.
    public mutating func reset(_ seqs: [Int]) {
        queued = Array(Set(seqs)).sorted()
        inFlight = [:]
        resends = [:]
    }

    public mutating func clear() { reset([]) }

    /// A newly spooled keyframe.
    public mutating func add(_ seq: Int) {
        guard inFlight[seq] == nil, !queued.contains(seq) else { return }
        if let last = queued.last, seq < last {
            queued.insert(seq, at: queued.firstIndex(where: { $0 > seq }) ?? queued.count)
        } else {
            queued.append(seq)
        }
    }

    /// The next seq to send now (moved to in-flight), nil when the window is full or nothing is queued.
    public mutating func next(now: Double) -> Int? {
        guard inFlight.count < limit, !queued.isEmpty else { return nil }
        let s = queued.removeFirst()
        inFlight[s] = now
        return s
    }

    /// `ack {seq, last_seq}`: returns every seq that is now settled on the server (that seq plus everything ≤ the
    /// contiguous last_seq still in the window) — their spool files can go.
    @discardableResult
    public mutating func acked(_ seq: Int, contiguous: Int) -> [Int] {
        var done = Set<Int>([seq])
        for s in inFlight.keys where s <= contiguous { done.insert(s) }
        for s in queued where s <= contiguous { done.insert(s) }
        for s in done { inFlight[s] = nil; resends[s] = nil }
        queued.removeAll { done.contains($0) }
        return done.sorted()
    }

    /// In-flight seqs older than `timeout` go back to the front of the queue (their resend count goes up).
    public mutating func expire(now: Double, timeout: Double) -> [Int] {
        let late = inFlight.filter { now - $0.value >= timeout }.map { $0.key }.sorted()
        for s in late {
            inFlight[s] = nil
            resends[s, default: 0] += 1
            add(s)
        }
        return late
    }

    /// The server rejected a frame (`error`): put the oldest in-flight seq back in the queue.
    @discardableResult
    public mutating func requeueOldest() -> Int? {
        guard let s = inFlight.min(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) })?.key
        else { return nil }
        inFlight[s] = nil
        resends[s, default: 0] += 1
        add(s)
        return s
    }

    /// The socket dropped: everything in flight is unacknowledged again.
    public mutating func requeueAll() {
        let back = Array(inFlight.keys)
        inFlight = [:]                                   // first: add() skips seqs still marked in flight
        for s in back { add(s) }
    }

    /// A seq left the spool (evicted by the cap).
    public mutating func remove(_ seq: Int) {
        inFlight[seq] = nil
        resends[seq] = nil
        queued.removeAll { $0 == seq }
    }
}

// MARK: - reconnect + transport choice

public enum LiveBackoff {
    /// 1, 2, 4, 8, 10, 10 … s (attempt 0 = the first retry).
    public static func delay(attempt: Int) -> Double {
        min(10, pow(2, Double(max(0, min(attempt, 10)))))
    }
}

/// WebSocket first; after 3 consecutive failed WS connects use the HTTP endpoints, and try the WS again after a while.
public struct LiveTransportChoice: Equatable {
    public static let wsFailuresBeforeHTTP = 3
    public static let httpRetryWSAfterS: Double = 60

    public private(set) var useHTTP = false
    public private(set) var wsFailures = 0
    private var httpSince: Double = 0

    public init() {}

    public mutating func wsConnected() { wsFailures = 0 }

    /// Returns true when this failure switched to HTTP.
    @discardableResult
    public mutating func wsFailed(now: Double) -> Bool {
        wsFailures += 1
        guard !useHTTP, wsFailures >= Self.wsFailuresBeforeHTTP else { return false }
        useHTTP = true
        httpSince = now
        return true
    }

    /// Time to try the WS again (true once, then the next WS attempt decides).
    public mutating func shouldRetryWS(now: Double) -> Bool {
        guard useHTTP, now - httpSince >= Self.httpRetryWSAfterS else { return false }
        useHTTP = false
        wsFailures = 0
        return true
    }
}

// MARK: - stats + HUD

public enum LiveText {
    public static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func rate(_ hz: Double) -> String { hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz) }

    /// "LIVE 2 Hz · sent 120 · acked 118 · queue 2 · lag 180 ms · placed via anchors" when the server answers,
    /// "LIVE offline · queue 37 (resuming)" when not; `paused` (recording, Scans, tracking) replaces the rate.
    public static func line(online: Bool, rateHz: Double, sent: Int, acked: Int, queue: Int, lagMs: Double?,
                            placed: Bool?, via: String?, http: Bool = false, paused: String? = nil,
                            draining: Bool = false) -> String {
        if !online {
            var s = draining ? "LIVE off · draining" : "LIVE offline"
            s += " · queue \(queue)"
            if queue > 0 { s += " (resuming)" }
            return s
        }
        var parts: [String] = []
        if draining { parts.append("LIVE off · draining") }
        else if let p = paused { parts.append("LIVE paused (\(p))") }
        else { parts.append("LIVE \(rate(rateHz))\(http ? " http" : "")") }
        parts.append("sent \(sent)")
        parts.append("acked \(acked)")
        parts.append("queue \(queue)")
        if let l = lagMs { parts.append(String(format: "lag %.0f ms", l)) }
        if let p = placed {
            if p { parts.append("placed" + ((via ?? "").isEmpty ? "" : " via \(via!)")) }
            else { parts.append("unplaced") }
        }
        return parts.joined(separator: " · ")
    }
}
