import Foundation

// 9.1.61 crash-safety for captures (docs/SNAILSIGHT-API.md §4.4a). Owner run 2026-10-12: an 8-minute whole-house
// recording was killed by iOS (memory limit, footprint ~3 GB) and the capture never reached the server, because the
// 9.1.60 queue only re-adds capture folders that have a capture.json — which is written at Stop.
//
// Layout stays StrayScanner (one file per frame, odometry.csv appended per frame), so a process kill loses only the frames
// that were in the encoder (≤ 3) plus the unflushed IMU buffer (≤ ~1 s). On top of that the recorder writes
// `capture.partial.json` (a CaptureCheckpoint) at start and every segment (~10 s): the metadata capture.json would carry,
// plus the frame range of every closed segment. On the next launch `CaptureRecovery.recover` turns such a folder into a
// normal capture: it drops truncated files and half-written CSV lines, removes frames whose odometry row is missing (or
// rows whose frame files are missing), and writes capture.json with `recovered: true, partial: true, stop_reason`.
// Everything here is pure Foundation, so `swift test` covers it on the CI host.

/// One closed ~10 s segment of a recording (frame indices inclusive).
public struct CaptureSegment: Codable, Equatable {
    public var index: Int
    public var firstFrame: Int
    public var lastFrame: Int
    public var t0: Double          // ARKit frame timestamps (seconds, device uptime clock)
    public var t1: Double
    public init(index: Int, firstFrame: Int, lastFrame: Int, t0: Double, t1: Double) {
        self.index = index; self.firstFrame = firstFrame; self.lastFrame = lastFrame; self.t0 = t0; self.t1 = t1
    }
    enum CodingKeys: String, CodingKey {
        case index, firstFrame = "first_frame", lastFrame = "last_frame", t0, t1
    }
}

/// capture.partial.json: written at start and at every segment boundary while recording; deleted at a clean Stop.
public struct CaptureCheckpoint: Codable, Equatable {
    public static let fileName = "capture.partial.json"
    public var schema = CaptureFormat.schema
    public var clientSessionID: String
    public var started: Double                   // seconds since 1970
    public var updated: Double                   // seconds since 1970 (last checkpoint)
    public var frames = 0                        // frames fully written so far
    public var lastFrame = -1
    public var dropped = 0
    public var rateHz = 10.0
    public var thermal = "nominal"
    public var fullSize: [Int]?
    public var depthSize: [Int]?
    public var segments: [CaptureSegment] = []
    public var meta: [String: String] = [:]      // agent_id, agent_type, app_version, device

    public init(clientSessionID: String, started: Double, meta: [String: String] = [:]) {
        self.clientSessionID = clientSessionID; self.started = started; self.updated = started; self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case schema, clientSessionID = "client_session_id", started, updated, frames, lastFrame = "last_frame", dropped,
             rateHz = "rate_hz", thermal, fullSize = "full_size", depthSize = "depth_size", segments, meta
    }

    public init(from d: Decoder) throws {               // tolerant: a checkpoint from any build must stay readable
        let c = try d.container(keyedBy: CodingKeys.self)
        clientSessionID = try c.decode(String.self, forKey: .clientSessionID)
        started = try c.decodeIfPresent(Double.self, forKey: .started) ?? 0
        updated = try c.decodeIfPresent(Double.self, forKey: .updated) ?? started
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? CaptureFormat.schema
        frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        lastFrame = try c.decodeIfPresent(Int.self, forKey: .lastFrame) ?? -1
        dropped = try c.decodeIfPresent(Int.self, forKey: .dropped) ?? 0
        rateHz = try c.decodeIfPresent(Double.self, forKey: .rateHz) ?? 10
        thermal = try c.decodeIfPresent(String.self, forKey: .thermal) ?? "?"
        fullSize = try c.decodeIfPresent([Int].self, forKey: .fullSize)
        depthSize = try c.decodeIfPresent([Int].self, forKey: .depthSize)
        segments = try c.decodeIfPresent([CaptureSegment].self, forKey: .segments) ?? []
        meta = try c.decodeIfPresent([String: String].self, forKey: .meta) ?? [:]
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

/// Segment bookkeeping while recording (pure; the recorder calls `frameWritten` for every saved frame).
public struct SegmentTracker: Equatable {
    public var seconds: Double
    public private(set) var closed: [CaptureSegment] = []
    private var open: CaptureSegment?

    public init(seconds: Double = 10) { self.seconds = seconds }

    /// Returns the segment that this frame closed (the caller then writes a checkpoint), else nil.
    public mutating func frameWritten(index: Int, t: Double) -> CaptureSegment? {
        guard var s = open else {
            open = CaptureSegment(index: closed.count, firstFrame: index, lastFrame: index, t0: t, t1: t)
            return nil
        }
        s.lastFrame = max(s.lastFrame, index)
        s.t1 = max(s.t1, t)
        if s.t1 - s.t0 >= seconds {
            closed.append(s)
            open = nil
            return s
        }
        open = s
        return nil
    }

    /// Close the open segment (clean Stop).
    public mutating func finish() {
        if let s = open { closed.append(s); open = nil }
    }
}

public struct RecoveryResult: Equatable, Sendable {
    public var clientSessionID: String
    public var frames = 0                 // frames kept (odometry rows with rgb + depth)
    public var rowsDropped = 0            // odometry rows without complete frame files / half-written lines
    public var filesRemoved = 0           // truncated files + frame files without an odometry row
    public var imuLinesDropped = 0
    public var bytes = 0                  // folder size after repair
    public var checkpoint = false         // a capture.partial.json was found (9.1.61+); false = 9.1.60 folder
    public var segments = 0
    public var durationS: Double = 0
    public var discarded = false          // nothing usable: folder deleted
    public var keyframes = 0              // full-resolution keyframes kept (keyframes/ + keyframes.csv)
}

public enum CaptureRecovery {
    public static let stopReasonKilled = "app_killed"

    /// A capture folder needs recovery when it has an odometry.csv but no capture.json (the recorder never reached Stop).
    public static func needsRecovery(fileNames: Set<String>) -> Bool {
        fileNames.contains("odometry.csv") && !fileNames.contains("capture.json")
    }

    /// Keep the header and every complete, well-formed line (`columns` comma-separated numbers ending in "\n").
    /// Drops a half-written last line and any malformed one. Returns (repaired text, dropped line count).
    public static func repairCSV(_ text: String, columns: Int) -> (String, Int) {
        var lines = text.components(separatedBy: "\n")
        let complete = text.hasSuffix("\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return ("", 0) }
        let header = lines.removeFirst()
        var out = header + "\n"
        var dropped = 0
        for (i, l) in lines.enumerated() {
            let isLast = i == lines.count - 1
            if isLast && !complete { dropped += 1; continue }
            let cols = l.split(separator: ",", omittingEmptySubsequences: false)
            if cols.count != columns || cols.contains(where: { Double($0.trimmingCharacters(in: .whitespaces)) == nil }) {
                dropped += 1
                continue
            }
            out += l + "\n"
        }
        return (out, dropped)
    }

    /// odometry.csv rows → frame index (second column), for well-formed rows only.
    public static func odometryFrames(_ text: String) -> [Int] {
        text.split(separator: "\n").dropFirst().compactMap { l in
            let c = l.split(separator: ",")
            return c.count >= 2 ? Int(c[1].trimmingCharacters(in: .whitespaces)) : nil
        }
    }

    /// Drop odometry rows whose frame is not in `present` (header kept). Returns (text, kept frames, dropped).
    public static func filterOdometry(_ text: String, present: Set<Int>, column: Int = 1) -> (String, [Int], Int) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return ("", [], 0) }
        var out = lines.removeFirst() + "\n"
        var kept: [Int] = [], dropped = 0, seen = Set<Int>()
        for l in lines {
            let c = l.split(separator: ",")
            guard c.count > column, let n = Int(c[column].trimmingCharacters(in: .whitespaces)), present.contains(n),
                  !seen.contains(n) else { dropped += 1; continue }
            seen.insert(n)
            kept.append(n)
            out += l + "\n"
        }
        return (out, kept, dropped)
    }

    /// A JPEG is complete when it ends with the EOI marker (FF D9); a PNG when its last chunk is IEND.
    public static func isComplete(_ data: Data, ext: String) -> Bool {
        let b = [UInt8](data.suffix(12))
        switch ext {
        case "jpg", "jpeg":
            return data.count > 4 && data.prefix(2) == Data([0xFF, 0xD8]) && b.suffix(2) == [0xFF, 0xD9]
        case "png":
            return data.count > 20 && b.count == 12 && b[4] == 0x49 && b[5] == 0x45 && b[6] == 0x4E && b[7] == 0x44
        default:
            return !data.isEmpty
        }
    }

    /// PNG width/height from the IHDR chunk.
    public static func pngSize(_ data: Data) -> (Int, Int)? {
        let b = [UInt8](data.prefix(24))
        guard b.count == 24, b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 else { return nil }
        let w = b[16..<20].reduce(0) { $0 << 8 | Int($1) }, h = b[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return (w, h)
    }

    /// "cap-20261012-035412" → its UTC start time.
    public static func startFromName(_ id: String) -> Double? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        guard id.hasPrefix("cap-") else { return nil }
        return f.date(from: String(id.dropFirst(4)))?.timeIntervalSince1970
    }

    private static func frameIndex(_ name: String) -> (Int, String)? {
        let parts = name.split(separator: ".")
        guard parts.count == 2, let n = Int(parts[0]) else { return nil }
        return (n, String(parts[1]).lowercased())
    }

    /// Repair an unfinished capture folder in place and write its capture.json. `fallbackMeta` fills fields a 9.1.60
    /// folder (no checkpoint) cannot know (agent_id, app_version, device). `verifyTail` = how many of the highest frame
    /// indices get their bytes checked for truncation (only frames still in the encoder at the kill can be truncated;
    /// checking all of them would read the whole capture at launch).
    @discardableResult
    public static func recover(dir: URL, fallbackMeta: [String: Any] = [:], stopReason: String = stopReasonKilled,
                               verifyTail: Int = 24, now: Double = Date().timeIntervalSince1970) throws -> RecoveryResult {
        let fm = FileManager.default
        let id = dir.lastPathComponent
        var r = RecoveryResult(clientSessionID: id)
        var cp: CaptureCheckpoint?
        let cpURL = dir.appendingPathComponent(CaptureCheckpoint.fileName)
        if let d = try? Data(contentsOf: cpURL) {
            cp = try? JSONDecoder().decode(CaptureCheckpoint.self, from: d)
        }
        r.checkpoint = cp != nil
        r.segments = cp?.segments.count ?? 0

        // 1. frame files per stream; truncated tail files are deleted
        var present: [String: Set<Int>] = [:]
        var depthSize: [Int]? = cp?.depthSize
        for sub in ["rgb", "depth", "confidence"] {
            let sd = dir.appendingPathComponent(sub)
            let names = (try? fm.contentsOfDirectory(atPath: sd.path)) ?? []
            var idx: [Int: String] = [:]
            for n in names { if let (i, ext) = frameIndex(n) { idx[i] = ext } }
            let tail = Set(idx.keys.sorted().suffix(verifyTail))
            var ok = Set<Int>()
            for (i, ext) in idx {
                let u = sd.appendingPathComponent("\(CaptureNaming.frameStem(i)).\(ext)")
                if tail.contains(i) {
                    let data = (try? Data(contentsOf: u)) ?? Data()
                    guard isComplete(data, ext: ext) else { try? fm.removeItem(at: u); r.filesRemoved += 1; continue }
                    if sub == "depth", depthSize == nil, let (w, h) = pngSize(data) { depthSize = [w, h] }
                } else if ((try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) == 0 {
                    try? fm.removeItem(at: u); r.filesRemoved += 1; continue
                }
                ok.insert(i)
            }
            present[sub] = ok
        }
        let usable = (present["rgb"] ?? []).intersection(present["depth"] ?? [])

        // 2. odometry: whole lines only, then only rows whose rgb + depth exist
        let odoURL = dir.appendingPathComponent("odometry.csv")
        let odoText = (try? String(contentsOf: odoURL, encoding: .utf8)) ?? CaptureFormat.odometryHeader
        let (clean, bad) = repairCSV(odoText, columns: 9)
        let (filtered, kept, missing) = filterOdometry(clean.isEmpty ? CaptureFormat.odometryHeader : clean, present: usable)
        r.rowsDropped = bad + missing
        r.frames = kept.count
        try Data(filtered.utf8).write(to: odoURL, options: .atomic)

        // 3. frame files without a kept odometry row (written just before the kill) are unusable: remove them
        let keep = Set(kept)
        for sub in ["rgb", "depth", "confidence"] {
            let sd = dir.appendingPathComponent(sub)
            for n in (try? fm.contentsOfDirectory(atPath: sd.path)) ?? [] {
                guard let (i, _) = frameIndex(n), !keep.contains(i) else { continue }
                try? fm.removeItem(at: sd.appendingPathComponent(n))
                r.filesRemoved += 1
            }
        }

        // 3b. keyframes/ + keyframes.csv: complete JPEGs of kept frames only
        let kfDir = dir.appendingPathComponent("keyframes")
        let kfURL = dir.appendingPathComponent("keyframes.csv")
        if fm.fileExists(atPath: kfDir.path) || fm.fileExists(atPath: kfURL.path) {
            var kfOK = Set<Int>()
            let names = (try? fm.contentsOfDirectory(atPath: kfDir.path)) ?? []
            let idx = names.compactMap { frameIndex($0) }.map(\.0)
            let tail = Set(idx.sorted().suffix(8))
            for n in names {
                guard let (i, ext) = frameIndex(n) else { continue }
                let u = kfDir.appendingPathComponent(n)
                let good: Bool
                if !keep.contains(i) { good = false }
                else if tail.contains(i) { good = isComplete((try? Data(contentsOf: u)) ?? Data(), ext: ext) }
                else { good = ((try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) > 0 }
                if good { kfOK.insert(i) } else { try? fm.removeItem(at: u); r.filesRemoved += 1 }
            }
            let text = (try? String(contentsOf: kfURL, encoding: .utf8)) ?? CaptureFormat.keyframesHeader
            // 8 columns (9.1.61) or 13 with the 9.4 quality columns: the header says which
            let kfColumns = text.split(separator: "\n", maxSplits: 1).first.map { $0.split(separator: ",").count } ?? 8
            let (clean, _) = repairCSV(text, columns: kfColumns)
            let (kept, rows, _) = filterOdometry(clean.isEmpty ? CaptureFormat.keyframesHeader : clean, present: kfOK,
                                                       column: 0)
            r.keyframes = rows.count
            try? Data(kept.utf8).write(to: kfURL, options: .atomic)
            for i in kfOK.subtracting(rows) {          // file without a row: unusable without intrinsics
                try? fm.removeItem(at: kfDir.appendingPathComponent("\(CaptureNaming.frameStem(i)).jpg"))
                r.filesRemoved += 1
            }
        }

        // 4. imu.csv: drop a half-written last line
        let imuURL = dir.appendingPathComponent("imu.csv")
        if let t = try? String(contentsOf: imuURL, encoding: .utf8) {
            let (c, d) = repairCSV(t, columns: 7)
            r.imuLinesDropped = d
            if d > 0 { try? Data((c.isEmpty ? CaptureFormat.imuHeader : c).utf8).write(to: imuURL, options: .atomic) }
        }

        guard r.frames > 0, fm.fileExists(atPath: dir.appendingPathComponent("camera_matrix.csv").path) else {
            try? fm.removeItem(at: dir)
            r.discarded = true
            return r
        }

        // 5. capture.json (same keys as a clean Stop + the recovery flags)
        let stamps = filtered.split(separator: "\n").dropFirst().compactMap { l in
            Double(l.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
        }
        r.durationS = (stamps.max() ?? 0) - (stamps.min() ?? 0)
        let started = cp?.started ?? startFromName(id) ?? now
        var m: [String: Any] = fallbackMeta
        for (k, v) in cp?.meta ?? [:] { m[k] = v }
        m["client_session_id"] = id
        m["schema"] = CaptureFormat.schema
        m["started"] = started
        m["ended"] = started + r.durationS
        m["frames"] = r.frames
        m["dropped"] = cp?.dropped ?? 0
        m["rate_hz"] = cp?.rateHz ?? 10
        m["rgb_size"] = [CaptureFormat.rgbSize.width, CaptureFormat.rgbSize.height]
        m["depth_size"] = depthSize ?? [256, 192]
        m["full_size"] = cp?.fullSize ?? [1920, 1440]
        m["world_alignment"] = "gravity"
        m["events"] = [[String: Any]]()
        m["recovered"] = true
        m["partial"] = true
        m["stop_reason"] = stopReason
        m["keyframes"] = r.keyframes
        m["recovery"] = ["recovered_at": now, "checkpoint": r.checkpoint, "segments": r.segments,
                         "rows_dropped": r.rowsDropped, "files_removed": r.filesRemoved,
                         "imu_lines_dropped": r.imuLinesDropped, "last_checkpoint": cp?.updated ?? 0,
                         "keyframes": r.keyframes,
                         "duration_s": (r.durationS * 10).rounded() / 10] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("capture.json"), options: .atomic)
        try? fm.removeItem(at: cpURL)
        r.bytes = folderSize(dir)
        return r
    }

    public static func folderSize(_ dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}
