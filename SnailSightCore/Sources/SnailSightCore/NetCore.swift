import Foundation

/// Pure networking decisions for the snailsight `/v1` client (docs/SNAILSIGHT-API.md). No URLSession here.

public enum AgentID {
    /// `phone-<8 lowercase hex>`; the server accepts `^[A-Za-z0-9_-]{3,64}$`.
    public static func make(prefix: String = "phone", random: UInt32 = UInt32.random(in: .min ... .max)) -> String {
        "\(prefix)-\(String(format: "%08x", random))"
    }

    public static func isValid(_ s: String) -> Bool {
        guard (3...64).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
    }

    /// Log/file names the server accepts: `^[A-Za-z0-9._-]{1,128}$`.
    public static func isValidName(_ s: String) -> Bool {
        guard (1...128).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-" || c == "."
        }
    }
}

public struct ServerCandidate: Equatable, Codable {
    public var label: String      // "override", "tailnet", "lan"
    public var base: String       // "http://192.168.1.10:8904" (no trailing slash)
    public init(label: String, base: String) { self.label = label; self.base = base }
}

public enum ServerConfig {
    /// Default servers are NOT compiled in (public source). They come from the app's Info.plist keys
    /// `SnailSightServerTailnet` / `SnailSightServerLAN`, filled at build time (xcodebuild settings
    /// `SNAILSIGHT_SERVER_TAILNET` / `SNAILSIGHT_SERVER_LAN`) or injected into the unsigned IPA before signing by the
    /// private release chain. Empty = no default; the user sets a server in Settings (override).
    public static let tailnet = infoString("SnailSightServerTailnet")
    public static let lan = infoString("SnailSightServerLAN")
    public static let apiVersion = "v1"

    static func infoString(_ key: String, bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Normalise a user-typed URL: trim, add http:// if missing, drop trailing slashes. nil if empty/invalid.
    public static func normalise(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return s
    }

    /// Probe order: override (if any) → last working → tailnet → LAN, without duplicates.
    public static func candidates(override: String?, lastGood: String?,
                                  tailnet: String = ServerConfig.tailnet, lan: String = ServerConfig.lan) -> [ServerCandidate] {
        var out: [ServerCandidate] = []
        func add(_ label: String, _ base: String?) {
            guard let b = normalise(base), !out.contains(where: { $0.base == b }) else { return }
            out.append(ServerCandidate(label: label, base: b))
        }
        add("override", override)
        if let lg = normalise(lastGood) { add(label(for: lg, override: override, tailnet: tailnet, lan: lan), lg) }
        add("tailnet", tailnet)
        add("lan", lan)
        return out
    }

    public static func label(for base: String, override: String?,
                             tailnet: String = ServerConfig.tailnet, lan: String = ServerConfig.lan) -> String {
        if base == normalise(override) { return "override" }
        if let t = normalise(tailnet), base == t { return "tailnet" }
        if let l = normalise(lan), base == l { return "lan" }
        return "custom"
    }
}

/// Resumable chunked upload: the next byte range to send.
public enum ChunkPlanner {
    public static let defaultChunk = 4 * 1024 * 1024

    /// Range [offset, offset+len) to send next, or nil when everything is sent.
    public static func next(received: Int, total: Int, chunk: Int = defaultChunk) -> (offset: Int, length: Int)? {
        guard total > 0, chunk > 0, received >= 0, received < total else { return nil }
        return (received, min(chunk, total - received))
    }

    /// All ranges from `received` (for tests / progress).
    public static func plan(received: Int, total: Int, chunk: Int = defaultChunk) -> [(offset: Int, length: Int)] {
        var out: [(Int, Int)] = []
        var r = received
        while let n = next(received: r, total: total, chunk: chunk) { out.append(n); r += n.length }
        return out
    }
}

/// Append-by-offset log upload bookkeeping: per log file, how many bytes the server holds.
public struct LogUploadState: Codable, Equatable {
    public var uploaded: [String: Int] = [:]
    public init(uploaded: [String: Int] = [:]) { self.uploaded = uploaded }

    public enum Action: Equatable {
        case upToDate
        case send(offset: Int, length: Int)
    }

    /// What to send for `name` given its local size. A local file smaller than what we think the server has
    /// (rotated/replaced) restarts from 0. At most `maxChunk` bytes per request (server limit 8 MB).
    public func action(name: String, localSize: Int, maxChunk: Int = 4 * 1024 * 1024) -> Action {
        var off = uploaded[name] ?? 0
        if off > localSize { off = 0 }
        guard localSize > off else { return .upToDate }
        return .send(offset: off, length: min(maxChunk, localSize - off))
    }

    /// Server accepted: it now holds `size` bytes.
    public mutating func accepted(name: String, size: Int) { uploaded[name] = size }

    /// Server answered 409 with its current size: resume from there (or from 0 if it holds more than we do,
    /// which means our file was replaced — the next send with offset 0 replaces the server copy).
    public mutating func conflict(name: String, serverSize: Int, localSize: Int) {
        uploaded[name] = serverSize <= localSize ? serverSize : 0
    }

    /// Forget files that no longer exist locally.
    public mutating func prune(keeping names: Set<String>) {
        uploaded = uploaded.filter { names.contains($0.key) }
    }
}

public enum CaptureNaming {
    /// "cap-20261012-140501" (UTC), sortable.
    public static func clientSessionID(start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "cap-\(f.string(from: start))"
    }

    /// "000042" frame file stem (StrayScanner uses 6 digits).
    public static func frameStem(_ i: Int) -> String { String(format: "%06d", i) }

    /// Captures to delete locally: those the server holds (uploaded or later), oldest first, keeping the newest `keep`.
    public static func toPrune(_ ids: [String], serverHas: Set<String>, keep: Int = 3) -> [String] {
        let sorted = ids.sorted()
        let protected = Set(sorted.suffix(keep))
        return sorted.filter { serverHas.contains($0) && !protected.contains($0) }
    }
}

/// Retry delay with exponential backoff (seconds), capped.
public enum Backoff {
    public static func delay(attempt: Int, base: Double = 2, cap: Double = 60) -> Double {
        min(cap, base * pow(2, Double(max(0, attempt))))
    }
}

/// 12.17: which transport failures mean "the server is gone". Only connection-level ones: a timeout on an ordinary
/// request (a slow or hung backend behind the map server) must not flip the whole app offline; the caller re-probes
/// `GET /v1` instead, and only that probe failing marks it offline. Codes are `URLError.Code.rawValue` (NSURLError*),
/// kept as Int so this stays pure on every platform.
public enum NetFailure {
    public static let timedOut = -1001
    /// cannotFindHost, cannotConnectToHost, networkConnectionLost, dnsLookupFailed, notConnectedToInternet,
    /// internationalRoamingOff, callIsActive, dataNotAllowed, secureConnectionFailed, cannotLoadFromNetwork.
    public static let connectionCodes: Set<Int> = [-1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020, -1200, -2000]

    /// Does this failure of an ordinary request mark the server offline at once?
    public static func marksOffline(code: Int) -> Bool { connectionCodes.contains(code) }

    public static let cancelled = -999

    /// Should it trigger a background `GET /v1` re-probe instead? Timeouts and any other transport error that is not
    /// a connection failure (those go offline at once) or a cancellation (ours, says nothing about the server).
    public static func wantsProbe(code: Int) -> Bool { code != cancelled && !marksOffline(code: code) }

    /// Rate limit for those re-probes: at most one per `interval` seconds.
    public static func probeDue(now: Double, last: Double?, interval: Double = 10) -> Bool {
        guard let last else { return true }
        return now - last >= interval
    }
}
