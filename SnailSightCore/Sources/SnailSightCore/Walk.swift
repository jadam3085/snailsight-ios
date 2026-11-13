import Foundation

// SnailSight 12.26 "one-tap walk" (owner 2026-11-13: "prioritize ensuring the iphone app is streamlined so that we can
// do a walk test soon to validate"). Start walk = AR explore + warm localizer + Live map on, with ONE status line:
// finding position → locked → streaming (keyframes sent / accepted / trusted, server delay) → problems in plain words.
// Stop walk = Live map off (the stream's bye lets the server promote it: ~2 min, then auto-improve + object detection)
// and a short summary. Everything here is pure (Linux-tested, WalkTests); the app side is Sources/Live/WalkController.

public enum WalkPhase: String, Equatable {
    case starting, finding, locked, streaming, stopping
}

public enum WalkTone: Equatable { case working, good, problem }

/// What the walk reads each tick (main thread snapshot of AppModel / MapLocalizer / LiveStreamer).
public struct WalkInputs: Equatable {
    public var now: Double
    public var arRunning = false
    public var tracking = "normal"            // TrackingStatus.code: "normal" | "limited:excessiveMotion" | … | "notAvailable"
    public var server = false                 // a map server answers
    public var liveOnline = false             // the uplink has a welcome
    public var locked = false                 // MapLocalizer has a (server / carried) lock
    public var sigmaCm: Double?
    public var placed: Bool?                  // live graph correction says placed
    public var sent = 0
    public var acked = 0
    public var queue = 0
    public var lagMs: Double?
    public var serverDelayMs: Double?         // capture → drawn (LiveStages.totalMs) when known
    public var gate: String?                  // trusted | probation | quarantined | pending
    public var gateWhy: String?
    public var paused: String?                // LivePause reason ("Scans", "3D map", "too hot", "tracking")
    public var rateHz = 2.0
    public var rateCapHz: Double?
    public var memLevel = "normal"
    public init(now: Double) { self.now = now }
}

public struct WalkLine: Equatable {
    public var phase: WalkPhase
    public var tone: WalkTone
    public var title: String                  // "Finding your position… 12 s" / "Streaming · 42 sent · 40 accepted · 35 trusted"
    public var detail: String?                // "server delay 1.8 s" / "placed in the house map"
    public var problem: String?               // the most important problem, plain words
}

/// 4 m areas visited (the cells auto-improve re-integrates are (level, 4 m column)); heading coverage per area in
/// 30° bins. Map frame (z up) once locked, else the ARKit frame (y up) as its own set.
public struct WalkCoverage: Equatable {
    public static let cellM = 4.0
    public static let storeyM = 2.7
    public static let bins = 12
    public private(set) var mapCells: [String: UInt16] = [:]     // "level/x/y" → heading bins seen
    public private(set) var arCells: [String: UInt16] = [:]
    public private(set) var current: String?
    public private(set) var enteredAt = 0.0
    public init() {}

    public static func key(x: Double, y: Double, z: Double) -> String {
        "\(Int((z / storeyM).rounded(.down)))/\(Int((x / cellM).rounded(.down)))/\(Int((y / cellM).rounded(.down)))"
    }

    public static func bin(yaw: Double) -> Int {
        let d = (yaw * 180 / .pi).truncatingRemainder(dividingBy: 360)
        return Int(((d < 0 ? d + 360 : d) / (360 / Double(bins)) + 1e-6).rounded(.down)) % bins
    }

    /// Camera position + view yaw (radians, about up). `map` = map frame (x, y, z up); false = ARKit (x, z ground, y up).
    public mutating func visit(position p: [Double], yaw: Double, map: Bool, now: Double) {
        guard p.count >= 3, p.allSatisfy(\.isFinite) else { return }
        let k = map ? Self.key(x: p[0], y: p[1], z: p[2]) : "ar/" + Self.key(x: p[0], y: -p[2], z: p[1])
        let b = UInt16(1) << UInt16(Self.bin(yaw: yaw))
        if map { mapCells[k, default: 0] |= b } else { arCells[k, default: 0] |= b }
        if k != current { current = k; enteredAt = now }
    }

    public var cells: Int { mapCells.isEmpty ? arCells.count : mapCells.count }
    public var inMap: Bool { !mapCells.isEmpty }

    /// Seconds in the current area and the share of headings seen there.
    public func here(now: Double) -> (inAreaS: Double, share: Double)? {
        guard let c = current, let m = mapCells[c] ?? arCells[c] else { return nil }
        return (now - enteredAt, Double(m.nonzeroBitCount) / Double(Self.bins))
    }

    /// Mean heading share over the visited areas.
    public var meanShare: Double {
        let v = Array((mapCells.isEmpty ? arCells : mapCells).values)
        guard !v.isEmpty else { return 0 }
        return v.reduce(0.0) { $0 + Double($1.nonzeroBitCount) / Double(Self.bins) } / Double(v.count)
    }
}

/// The server's ack `rate` hint (API §6b ack, live 0.15): {max_hz: null | tier, taken, why}. The app obeys it down to
/// `floorHz` (1 Hz, the phone's lowest rate): stored keyframes are the evidence auto-improve and promotion rebuild from,
/// so the phone keeps ≥ 1 Hz even while the live world sheds. A lower cap applies at once; going back up waits
/// `upHoldS` of "keeping up" (or a higher hint) so the rate does not oscillate.
public struct LiveRateCap: Equatable {
    public static let floorHz = 1.0
    public static let upHoldS = 20.0
    public private(set) var capHz: Double?
    private var changedAt = -1e9
    private var keepingSince: Double?
    public private(set) var hints = 0
    public private(set) var minHz: Double?
    public init() {}

    public struct Hint: Equatable {
        public var maxHz: Double?
        public var taken: Double?
        public var why: String
    }

    public static func parse(_ ack: [String: Any]) -> Hint? {
        guard let r = ack["rate"] as? [String: Any] else { return nil }
        let m = (r["max_hz"] as? NSNumber)?.doubleValue
        return Hint(maxHz: m.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, taken: (r["taken"] as? NSNumber)?.doubleValue,
                    why: r["why"] as? String ?? "")
    }

    /// Returns true when the cap changed.
    @discardableResult
    public mutating func apply(_ h: Hint, now: Double) -> Bool {
        hints += 1
        if let m = h.maxHz {
            minHz = min(minHz ?? m, m)
            keepingSince = nil
            let target = max(Self.floorHz, m)
            if let c = capHz {
                if target < c { return set(target, now) }
                if target > c, now - changedAt >= Self.upHoldS { return set(target >= 2 ? nil : target, now) }
                return false
            }
            return target < 2 ? set(target, now) : false
        }
        guard let c = capHz else { return false }
        let since = keepingSince ?? now
        keepingSince = since
        guard now - since >= Self.upHoldS, now - changedAt >= Self.upHoldS else { return false }
        keepingSince = now
        return set(c * 2 >= 2 ? nil : c * 2, now)
    }

    private mutating func set(_ v: Double?, _ now: Double) -> Bool {
        guard v != capHz else { return false }
        capHz = v
        changedAt = now
        return true
    }

    public func effective(user: Double) -> Double { min(user, capHz ?? user) }
}

/// One walk: phase, counters, status line, summary.
public struct WalkSession: Equatable {
    public let startedAt: Double
    public let cause: String
    public private(set) var phase: WalkPhase = .starting
    public private(set) var lockedAt: Double?
    public private(set) var lockSource: String?
    public private(set) var firstAckAt: Double?
    public private(set) var trusted = 0
    public private(set) var acks = 0
    public private(set) var dups = 0
    public private(set) var everPlaced = false
    public private(set) var streams: [String] = []
    public private(set) var errors = 0
    public private(set) var memMax = "normal"
    public var coverage = WalkCoverage()
    /// The sent / acked counters of the uplink when the walk started (its counters are per app run).
    public let sentBase: Int
    public let ackedBase: Int
    public private(set) var sent = 0
    public private(set) var acked = 0

    public init(now: Double, cause: String, sentBase: Int = 0, ackedBase: Int = 0) {
        startedAt = now; self.cause = cause; self.sentBase = sentBase; self.ackedBase = ackedBase
    }

    public mutating func stream(_ id: String) { if !id.isEmpty, !streams.contains(id) { streams.append(id) } }
    public mutating func error() { errors += 1 }

    /// An uplink ack: counts accepted (not dup) and trusted (the stream's gate verdict at ack time is trusted).
    public mutating func ack(gate: String?, dup: Bool) {
        if dup { dups += 1; return }
        acks += 1
        if gate == "trusted" { trusted += 1 }
    }

    static let memOrder = ["normal", "trim", "shed", "critical"]   // MemLevel.label
    public mutating func memory(_ level: String) {
        if (Self.memOrder.firstIndex(of: level) ?? 0) > (Self.memOrder.firstIndex(of: memMax) ?? 0) { memMax = level }
    }

    public func elapsed(_ now: Double) -> Double { max(0, now - startedAt) }

    /// One tick: the phase (returned with whether it changed) and the status line.
    public mutating func update(_ i: WalkInputs) -> (status: WalkLine, phaseChanged: Bool) {
        sent = max(0, i.sent - sentBase)
        acked = max(0, i.acked - ackedBase)
        if (i.locked || i.placed == true), lockedAt == nil { lockedAt = i.now }
        if i.placed == true { everPlaced = true }
        if acked > 0, firstAckAt == nil { firstAckAt = i.now }
        memory(i.memLevel)
        let old = phase
        if phase != .stopping {
            if !i.arRunning { phase = .starting }
            else if lockedAt == nil { phase = .finding }
            else if acked > 0 && i.liveOnline { phase = .streaming }
            else { phase = .locked }
        }
        return (status(i), phase != old)
    }

    public mutating func stopping() { phase = .stopping }

    /// The most important problem now, in plain words (nil = none).
    public func problem(_ i: WalkInputs) -> String? {
        if !i.server { return "Can't reach the map server: keyframes are kept and sent when it's back" }
        if let p = i.paused, p != "tracking" {
            if p == "too hot" { return "Paused: the phone is too hot. Let it cool for a minute" }
            return "Paused while \(p) is open"
        }
        let tr = i.tracking.hasPrefix("limited:") ? String(i.tracking.dropFirst(8)) : i.tracking
        switch tr {
        case "normal": break
        case "excessiveMotion": return "Moving too fast: slow down"
        case "insufficientFeatures": return "Too dark or too plain to track: point at something with detail"
        case "initializing", "relocalizing": return "Tracking is starting: hold the phone steady"
        default: return "Tracking lost: hold the phone steady"
        }
        if i.arRunning, i.queue > 30 { return "Upload behind: \(i.queue) keyframes waiting" }
        if i.gate == "quarantined" {
            return "The server doesn't trust the position right now" + (Self.gateWords(i.gateWhy).map { " (\($0))" } ?? "")
                + ": walk back into a mapped room"
        }
        if phase == .finding, elapsed(i.now) > 45 {
            return "Not found in the house map yet: walk to a room the map knows, or keep going (it becomes a new area)"
        }
        if i.memLevel == "critical" { return "Memory is tight: far map detail is hidden" }
        return nil
    }

    /// The gate's `why` (locgate reasons, comma list) in plain words (first known reason).
    public static func gateWords(_ why: String?) -> String? {
        guard let w = why else { return nil }
        for r in w.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            switch r {
            case "fitness", "rmse", "structure": return "the view doesn't match the map"
            case "degenerate": return "too little shape in view"
            case "correction", "shift", "jump", "unsettled": return "the position keeps jumping"
            case "tracking": return "tracking was limited"
            case "no_lock": return "waiting for a position lock"
            case "warming", "probation": return "checking the first keyframes"
            default: continue
            }
        }
        return nil
    }

    public func status(_ i: WalkInputs) -> WalkLine {
        let t = Int(elapsed(i.now).rounded())
        let p = problem(i)
        var title: String, detail: String?
        var tone: WalkTone = .working
        switch phase {
        case .starting:
            title = "Starting the camera…"
        case .finding:
            title = "Finding your position… \(t) s"
            detail = i.sent > sentBase ? "keyframes are already being sent" : nil
        case .locked:
            title = "Locked" + (i.sigmaCm.map { String(format: " ±%.0f cm", $0) } ?? "") + ": starting the live map"
            tone = .good
        case .streaming:
            title = "Streaming · \(sent) sent · \(acked) accepted · \(trusted) trusted"
            var parts: [String] = []
            if let d = i.serverDelayMs ?? i.lagMs { parts.append(String(format: "server delay %.1f s", d / 1000)) }
            if let g = i.gate, g != "trusted" {
                parts.append(g == "probation" || g == "pending" ? "checking position" : g)
            }
            if let c = i.rateCapHz, c < i.rateHz { parts.append(String(format: "server busy: %.0f kf/s", c)) }
            parts.append("\(coverage.cells) area\(coverage.cells == 1 ? "" : "s")")
            detail = parts.joined(separator: " · ")
            tone = .good
        case .stopping:
            title = "Finishing: sending the last keyframes…"
            detail = i.queue > 0 ? "\(i.queue) to go" : nil
        }
        if p != nil, phase != .stopping { tone = .problem }
        return WalkLine(phase: phase, tone: tone, title: title, detail: detail, problem: p)
    }

    public var trustedPct: Double { acks > 0 ? Double(trusted) / Double(acks) * 100 : 0 }
}

/// The short summary after Stop walk.
public struct WalkSummary: Equatable {
    public var durationS: Double
    public var sent: Int
    public var accepted: Int
    public var trusted: Int
    public var trustedPct: Double
    public var lockS: Double?
    public var areas: Int
    public var inMap: Bool
    public var placed: Bool
    public var queueLeft: Int

    public init(_ w: WalkSession, now: Double, queue: Int) {
        durationS = w.elapsed(now)
        sent = w.sent
        accepted = w.acks
        trusted = w.trusted
        trustedPct = w.trustedPct
        lockS = w.lockedAt.map { $0 - w.startedAt }
        areas = w.coverage.cells
        inMap = w.coverage.inMap
        placed = w.everPlaced || w.lockedAt != nil
        queueLeft = queue
    }

    public static func duration(_ s: Double) -> String {
        let m = Int(s) / 60, r = Int(s) % 60
        return m > 0 ? "\(m) min \(r) s" : "\(r) s"
    }

    /// Lines for the summary card.
    public var lines: [String] {
        var out = ["Walked \(Self.duration(durationS))" + (lockS.map { " · locked after \(Int($0.rounded())) s" } ?? " · never locked")]
        out.append("Keyframes: \(sent) sent · \(accepted) accepted · \(trusted) trusted (\(Int(trustedPct.rounded())) %)")
        out.append("\(areas) area\(areas == 1 ? "" : "s") of 4 m covered" + (inMap ? "" : " (not in the house map)"))
        if queueLeft > 0 { out.append("\(queueLeft) keyframes still uploading: keep the app open a moment") }
        return out
    }

    /// What happens next, plain words.
    public var next: String {
        if !placed {
            return "This walk was not placed in the house map: the server keeps it as a new area and joins it when a later walk connects it."
        }
        return "The server will now improve the map and detect objects: about 2 min to take the walk in, then about 10 min more while nobody is streaming."
    }
}
