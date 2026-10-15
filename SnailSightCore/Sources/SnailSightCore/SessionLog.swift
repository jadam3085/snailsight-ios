import Foundation

/// One line of the on-device debug log (JSON Lines). Schema `snailsight.log/1`, meant to be POSTed
/// unchanged to the snailsight service's `/v1/logs` once it exists (P1).
public struct LogEvent: Codable, Equatable {
    public var t: Double            // seconds since 1970 (UTC)
    public var ev: String           // event name: boot, tracking, mapping, place_cube, measure, ruler, fps, thermal, error, reset
    public var data: [String: LogValue]

    public init(t: Double, ev: String, data: [String: LogValue] = [:]) {
        self.t = t; self.ev = ev; self.data = data
    }
}

public enum LogValue: Codable, Equatable {
    case string(String), double(Double), int(Int), bool(Bool), doubles([Double])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode([Double].self) { self = .doubles(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .double(let v): try c.encode(v.isFinite ? v : 0)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .doubles(let v): try c.encode(v.map { $0.isFinite ? $0 : 0 })
        }
    }
}

public enum LogFormat {
    public static let schema = "snailsight.log/1"

    /// One JSON object + "\n" (sorted keys → stable diffs).
    public static func line(_ e: LogEvent) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var d = (try? enc.encode(e)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    /// "session-20261011-203000.jsonl" (UTC), sortable by name = by time.
    public static func fileName(start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "session-\(f.string(from: start)).jsonl"
    }

    /// Oldest session logs to delete so that at most `keep` remain (non-session files are never touched).
    public static func filesToPrune(_ names: [String], keep: Int) -> [String] {
        let logs = names.filter { $0.hasPrefix("session-") && $0.hasSuffix(".jsonl") }.sorted()
        return logs.count > keep ? Array(logs.prefix(logs.count - keep)) : []
    }
}
