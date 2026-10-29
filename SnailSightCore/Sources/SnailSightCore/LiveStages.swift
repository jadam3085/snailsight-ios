import Foundation

// SnailSight 12.18: M0 latency line (live world build 2026-10-28 item 2; server livestages.py, API §6b.9 / §6b.8).
// The uplink `ack` carries `"stages": {"seq", "ms": {"<stage>": ms since capture}, "total_ms"}` (the newest keyframe of
// this stream that reached a client) and `"gate": {"state": "trusted"|"probation"|"quarantined", "why"}`. The app adds
// its own two stages from the downlink: `phone` = a live tile carrying our keyframe arrived (now − its capture wall
// time `hw_wall`), `drawn` = it was on screen. Server and phone clocks are both NTP-synced (the server's lag_ms relies
// on the same). Pure, Linux-tested (LiveStagesTests).

public struct LiveStages: Equatable {
    public static let order = ["ingest", "frontend", "align", "gate", "integrate", "mesh", "commit", "publish"]

    public var seq: Int?
    public var ms: [String: Double] = [:]
    public var totalMs: Double?
    public var gate: String?
    public var gateWhy: String?
    /// App-side: capture → the tile with our keyframe arrived / was drawn.
    public var phoneMs: Double?
    public var drawnMs: Double?

    public init() {}

    /// Updates from an uplink ack (JSON object). Returns true when anything changed.
    @discardableResult
    public mutating func ack(_ o: [String: Any]) -> Bool {
        let old = self
        if let s = o["stages"] as? [String: Any] {
            seq = (s["seq"] as? NSNumber)?.intValue ?? seq
            if let m = s["ms"] as? [String: Any] {
                var out: [String: Double] = [:]
                for (k, v) in m { if let d = (v as? NSNumber)?.doubleValue { out[k] = d } }
                if !out.isEmpty { ms = out }
            }
            totalMs = (s["total_ms"] as? NSNumber)?.doubleValue ?? ms["publish"] ?? totalMs
        }
        if let g = o["gate"] as? [String: Any] {
            gate = g["state"] as? String ?? gate
            gateWhy = g["why"] as? String
        }
        return self != old
    }

    /// A downlink tile fused our stream: `hwWall` = capture wall time of its newest keyframe.
    public mutating func tileArrived(hwWall: Double, now: Double) {
        let d = (now - hwWall) * 1000
        guard d > -2000, d < 600_000 else { return }          // clocks badly off: ignore
        phoneMs = max(0, d)
    }

    public mutating func tileDrawn(hwWall: Double, now: Double) {
        let d = (now - hwWall) * 1000
        guard d > -2000, d < 600_000 else { return }
        drawnMs = max(0, d)
    }

    public var hasAny: Bool { !ms.isEmpty || phoneMs != nil || gate != nil }

    public static func fmt(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.1f s", ms / 1000) : String(format: "%.0f ms", ms)
    }

    /// One short line for the HUD: "capture→drawn 2.2 s · server 1.9 s · gate trusted".
    public var short: String? {
        guard hasAny else { return nil }
        var p: [String] = []
        if let d = drawnMs { p.append("capture→drawn \(Self.fmt(d))") }
        else if let d = phoneMs { p.append("capture→phone \(Self.fmt(d))") }
        if let t = totalMs { p.append("server \(Self.fmt(t))") }
        if let g = gate { p.append("gate \(g)") }
        return p.joined(separator: " · ")
    }

    /// The detail: every stage in order (ms since capture), then the phone's own.
    public var detail: String? {
        guard hasAny else { return nil }
        var p: [String] = []
        for k in Self.order { if let v = ms[k] { p.append("\(k) \(Self.fmt(v))") } }
        for (k, v) in ms.sorted(by: { $0.key < $1.key }) where !Self.order.contains(k) && k != "capture" {
            p.append("\(k) \(Self.fmt(v))")
        }
        if let d = phoneMs { p.append("phone \(Self.fmt(d))") }
        if let d = drawnMs { p.append("drawn \(Self.fmt(d))") }
        var s = p.joined(separator: " → ")
        if let g = gate { s += (s.isEmpty ? "" : " · ") + "gate \(g)" + (gateWhy.map { " (\($0))" } ?? "") }
        if let q = seq { s += " · kf \(q)" }
        return s
    }
}
