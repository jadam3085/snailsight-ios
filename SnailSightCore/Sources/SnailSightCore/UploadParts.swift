import Foundation

// Capture upload in independent parts (docs/SNAILSIGHT-API.md §4.2b, SnailSight 9.1.60+).
//
// 9.1.59 zipped the whole capture with NSFileCoordinator (deflate over JPEG/PNG that do not compress: slow, no gain)
// and then streamed it by offset from the foreground app only, so a 253 MB capture never left the phone once the app
// was backgrounded (owner run 2026-10-12, cap-20261012-030807). Now the capture folder is split into ~16 MB
// store-only zip parts (a straight copy + CRC, about a second for 250 MB) and every part is one file-based upload
// task on a background URLSession, which iOS keeps transferring while the app is suspended or the phone is locked.
// Everything here is pure (no URLSession / UIKit) so the macOS CI runner tests it.

// MARK: - CRC-32 (zip / IEEE 802.3)

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 { update(0, data) }

    /// Continue a running CRC (`crc` = the previous result, 0 to start).
    public static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for b in buf { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return ~c
    }
}

// MARK: - plan

/// One file of the capture, `path` relative to the capture folder ("rgb/000042.jpg").
public struct CaptureFile: Codable, Equatable {
    public var path: String
    public var size: Int
    public init(path: String, size: Int) { self.path = path; self.size = size }
}

public struct PartPlan: Codable, Equatable {
    public var index: Int
    public var files: [CaptureFile]
    public var size: Int              // exact size of the store-only zip
}

public enum PartPlanner {
    public static let defaultTarget = 16 * 1024 * 1024        // server cap per part: 64 MB

    /// Name inside the zip: "<capture id>/<path>" (the server looks for the folder holding odometry.csv, like
    /// NSFileCoordinator's zips which wrap the folder in one top-level directory).
    public static func entryName(root: String, path: String) -> String { "\(root)/\(path)" }

    /// Exact store-only zip size: local headers + data + central directory + end record (no zip64, no extras).
    public static func zipSize(root: String, files: [CaptureFile]) -> Int {
        var n = 22
        for f in files {
            let name = entryName(root: root, path: f.path).utf8.count
            n += 30 + name + f.size + 46 + name
        }
        return n
    }

    /// Deterministic split: files sorted by path, filled greedily up to `target` bytes per part (a file larger than
    /// `target` gets a part of its own). The same folder always gives the same plan, so a re-plan after an app
    /// restart matches the parts the server already holds.
    public static func plan(root: String, files: [CaptureFile], target: Int = defaultTarget) -> [PartPlan] {
        let sorted = files.sorted { $0.path < $1.path }
        var out: [PartPlan] = []
        var cur: [CaptureFile] = []
        var curSize = 22
        func close() {
            guard !cur.isEmpty else { return }
            out.append(PartPlan(index: out.count, files: cur, size: curSize))
            cur = []
            curSize = 22
        }
        for f in sorted {
            let name = entryName(root: root, path: f.path).utf8.count
            let cost = 30 + name + f.size + 46 + name
            if !cur.isEmpty && curSize + cost > target { close() }
            cur.append(f)
            curSize += cost
        }
        close()
        return out
    }

    /// Every regular file under `dir` (relative paths, sizes), skipping hidden files.
    public static func listFiles(in dir: URL) throws -> [CaptureFile] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [CaptureFile] = []
        for case let u as URL in en {
            let v = try u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(CaptureFile(path: String(p.dropFirst(base.count + 1)), size: v.fileSize ?? 0))
        }
        return out.sorted { $0.path < $1.path }
    }
}

// MARK: - store-only zip writer

public enum StoreZipError: LocalizedError {
    case tooLarge(String)
    case missing(String)
    public var errorDescription: String? {
        switch self {
        case .tooLarge(let p): return "file too large for a zip part: \(p)"
        case .missing(let p): return "capture file missing: \(p)"
        }
    }
}

public enum StoreZip {
    private static func le16(_ v: Int, _ d: inout Data) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
    private static func le32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }

    /// Build the zip for `part` from the files under `dir` in memory (a part is ~16 MB). Entries are STORED
    /// (method 0) with real CRCs, so Python's zipfile verifies every file on extract.
    public static func build(part: PartPlan, root: String, dir: URL) throws -> Data {
        var out = Data()
        out.reserveCapacity(part.size)
        var central = Data()
        var count = 0
        for f in part.files {
            let url = dir.appendingPathComponent(f.path)
            guard let data = try? Data(contentsOf: url) else { throw StoreZipError.missing(f.path) }
            guard data.count < Int(UInt32.max), out.count < Int(UInt32.max) else { throw StoreZipError.tooLarge(f.path) }
            let name = Data(PartPlanner.entryName(root: root, path: f.path).utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            // local file header
            le32(0x0403_4B50, &out); le16(10, &out); le16(0, &out); le16(0, &out)   // sig, version 1.0, flags, stored
            le16(0, &out); le16(0x21, &out)                                          // time 00:00, date 1980-01-01
            le32(crc, &out); le32(UInt32(data.count), &out); le32(UInt32(data.count), &out)
            le16(name.count, &out); le16(0, &out)
            out.append(name)
            out.append(data)
            // central directory entry
            le32(0x0201_4B50, &central); le16(20, &central); le16(10, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le16(0x21, &central)
            le32(crc, &central); le32(UInt32(data.count), &central); le32(UInt32(data.count), &central)
            le16(name.count, &central); le16(0, &central); le16(0, &central)        // name, extra, comment
            le16(0, &central); le16(0, &central); le32(0, &central)                 // disk, internal, external attrs
            le32(offset, &central)
            central.append(name)
            count += 1
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out)
        le16(count, &out); le16(count, &out)
        le32(UInt32(central.count), &out); le32(cdOffset, &out); le16(0, &out)
        return out
    }
}

// MARK: - queue state

/// One part of one capture upload. `taskID` is the background URLSessionTask identifier while iOS holds the transfer.
public struct PartState: Codable, Equatable {
    public var index: Int
    public var size: Int
    public var packaged = false        // part file written to Documents/uploads/<capture>/NNNNN.zip
    public var done = false            // server holds it
    public var taskID: Int?
    public var sent = 0                // bytes of this part sent in the current attempt (progress only)
    public var attempts = 0
    public var nextAttempt: Double = 0
    public var lastError: String?

    public init(index: Int, size: Int) { self.index = index; self.size = size }

    enum CodingKeys: String, CodingKey { case index, size, packaged, done, taskID, sent, attempts, nextAttempt, lastError }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        size = try c.decode(Int.self, forKey: .size)
        packaged = try c.decodeIfPresent(Bool.self, forKey: .packaged) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        taskID = try c.decodeIfPresent(Int.self, forKey: .taskID)
        sent = try c.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttempt = try c.decodeIfPresent(Double.self, forKey: .nextAttempt) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// One capture in the upload queue (Documents/upload_queue.json). Decoding tolerates every older field set
/// (9.1.59 wrote no `mode`/`parts`): a missing key takes its default instead of failing the whole file, which in
/// 9.1.59's synthesized Codable would have silently emptied the queue.
public struct UploadItem: Codable, Identifiable, Equatable {
    public var id: String { clientSessionID }
    public var clientSessionID: String
    public var frames: Int
    public var captureBytes: Int
    public var bytesTotal = 0          // sum of part sizes (parts) or zip size (legacy stream)
    public var sha256: String?
    public var sessionID: String?
    public var received = 0
    public var state = "recorded"      // recorded → planned → uploading → uploaded/processing/processed/failed (server)
    public var error: String?
    public var attempts = 0
    public var nextAttempt: Double = 0
    public var lastPoll: Double = 0
    public var localDeleted = false
    public var created: Double = Date().timeIntervalSince1970
    public var mode = "parts"          // "parts" (9.1.60+) | "stream" (9.1.59, only kept for finished items)
    public var parts: [PartState] = []
    public var dropped: Int?
    public var report: String?         // one-line room report once processed
    /// 9.3: "session" (room capture → /v1/sessions) | "object" (object scan → /v1/objects, API §9). `sessionID` holds
    /// the server id of either. Older queue files have no key: derived from the capture id (UploadRoute).
    public var target: String

    public init(clientSessionID: String, frames: Int, captureBytes: Int) {
        self.clientSessionID = clientSessionID; self.frames = frames; self.captureBytes = captureBytes
        self.target = UploadRoute.target(for: clientSessionID)
    }

    enum CodingKeys: String, CodingKey {
        case clientSessionID, frames, captureBytes, bytesTotal, sha256, sessionID, received, state, error, attempts,
             nextAttempt, lastPoll, localDeleted, created, mode, parts, dropped, report, target
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        clientSessionID = try c.decode(String.self, forKey: .clientSessionID)
        frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        captureBytes = try c.decodeIfPresent(Int.self, forKey: .captureBytes) ?? 0
        bytesTotal = try c.decodeIfPresent(Int.self, forKey: .bytesTotal) ?? 0
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        received = try c.decodeIfPresent(Int.self, forKey: .received) ?? 0
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "recorded"
        error = try c.decodeIfPresent(String.self, forKey: .error)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttempt = try c.decodeIfPresent(Double.self, forKey: .nextAttempt) ?? 0
        lastPoll = try c.decodeIfPresent(Double.self, forKey: .lastPoll) ?? 0
        localDeleted = try c.decodeIfPresent(Bool.self, forKey: .localDeleted) ?? false
        created = try c.decodeIfPresent(Double.self, forKey: .created) ?? Date().timeIntervalSince1970
        parts = try c.decodeIfPresent([PartState].self, forKey: .parts) ?? []
        dropped = try c.decodeIfPresent(Int.self, forKey: .dropped)
        report = try c.decodeIfPresent(String.self, forKey: .report)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "stream"     // absent = written by 9.1.59
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? UploadRoute.target(for: clientSessionID)
    }

    public var finished: Bool { state == "processed" || state == "failed" }
    /// The server holds every byte (state moved past uploading).
    public var serverHasAll: Bool {
        if ["uploaded", "processing", "processed", "failed"].contains(state) { return true }
        if mode == "parts" { return !parts.isEmpty && parts.allSatisfy(\.done) }
        return bytesTotal > 0 && received >= bytesTotal
    }
    /// Bytes on the server plus bytes of parts in flight.
    public var sentBytes: Int {
        if mode == "parts" { return parts.reduce(0) { $0 + ($1.done ? $1.size : min($1.sent, $1.size)) } }
        return received
    }
    public var progress: Double { bytesTotal > 0 ? min(1, Double(sentBytes) / Double(bytesTotal)) : 0 }
    /// Every part not yet on the server is held by iOS (background transfer): leaving the app is safe.
    public var backgroundSafe: Bool {
        mode == "parts" && !parts.isEmpty && sessionID != nil && parts.allSatisfy { $0.done || $0.taskID != nil }
    }

    /// 9.1.59 → 9.1.60: an unfinished legacy (streamed zip) item restarts as a parts upload. The server's session
    /// for the same client_session_id is reused and switched to parts on the next POST (API §4.2b).
    /// Returns true if the item changed.
    public mutating func migrateToParts() -> Bool {
        guard mode != "parts", !serverHasAll else { return false }
        mode = "parts"
        parts = []
        bytesTotal = 0
        sha256 = nil
        received = 0
        sessionID = nil
        attempts = 0
        nextAttempt = 0
        error = nil
        state = "recorded"
        return true
    }

    /// The server says it holds these part indices (POST / GET result `parts_received`).
    public mutating func markHeld(_ held: [Int]) {
        let s = Set(held)
        for i in parts.indices where s.contains(parts[i].index) { parts[i].done = true; parts[i].taskID = nil }
    }

    /// Parts ready to hand to the background session now.
    public func schedulable(now: Double) -> [Int] {
        parts.filter { $0.packaged && !$0.done && $0.taskID == nil && $0.nextAttempt <= now }.map(\.index)
    }

    /// Forget task ids that iOS no longer has (app was killed / reinstalled): those parts get scheduled again.
    public mutating func dropStaleTasks(live: Set<Int>) -> [Int] {
        var dropped: [Int] = []
        for i in parts.indices {
            if let t = parts[i].taskID, !live.contains(t) { parts[i].taskID = nil; parts[i].sent = 0; dropped.append(parts[i].index) }
        }
        return dropped
    }
}

// MARK: - progress text

public enum UploadText {
    /// "Uploading 42 % · 110/253 MB · ~3 min"
    public static func progressLine(sent: Int, total: Int, bytesPerSecond: Double?) -> String {
        let pct = total > 0 ? Int((Double(sent) / Double(total) * 100).rounded(.down)) : 0
        var s = "Uploading \(min(100, pct)) % · \(mb(sent))/\(mb(total)) MB"
        if let r = bytesPerSecond, r > 1, total > sent { s += " · " + eta(seconds: Double(total - sent) / r) }
        return s
    }

    static func mb(_ b: Int) -> String { String(Int((Double(b) / 1_048_576).rounded())) }

    public static func eta(seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "" }
        if seconds < 10 { return "<10 s" }
        if seconds < 90 { return "~\(Int((seconds / 10).rounded()) * 10) s" }
        if seconds < 3600 { return "~\(Int((seconds / 60).rounded())) min" }
        return String(format: "~%.1f h", seconds / 3600)
    }
}

/// Smoothed upload rate from (time, total bytes sent) samples.
public struct RateMeter {
    private var lastT: Double?
    private var lastB = 0
    public private(set) var bytesPerSecond: Double?
    public var alpha = 0.3
    public init() {}

    public mutating func add(t: Double, bytes: Int) {
        defer { if lastT == nil || t - lastT! >= 1 { lastT = t; lastB = bytes } }
        guard let lt = lastT, t - lt >= 1 else { return }
        let r = Double(max(0, bytes - lastB)) / (t - lt)
        bytesPerSecond = bytesPerSecond.map { $0 * (1 - alpha) + r * alpha } ?? r
    }
}
