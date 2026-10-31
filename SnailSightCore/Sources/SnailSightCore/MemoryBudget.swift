import Foundation

// SnailSight 12.20 memory governor (owner report 2026-10-30, app 12.19.305: "I was walking but then it looked like it
// crashed" = an iOS jetsam kill after 130 s with Live map on: footprint 502 -> 3184 MB of 3376, 38 memory warnings, none
// of which shed anything because shedding only existed while recording).
//
// The rule: a long walk (30+ min) with Live map, the sim, Mesh and the device surface on plateaus well under the limit.
//  - Every subsystem that holds per-area state has a budget and a spatial LRU (SpatialLRU): base tiles (TileSelect
//    budgets), live downlink mesh tiles and Layer B tiles (near you only), the device-surface coverage grid (a spatial
//    cap), the ARKit mesh overlay copies (vertex cap, near anchors first) and ARKit's own reconstruction (a vertex cap
//    that resets it; it rebuilds around you in seconds).
//  - MemoryGovernor turns footprint / limit / memory warnings into a level (normal, trim, shed, critical) with
//    hysteresis; MemPlan turns level + thermal into the budgets. Higher levels only ever tighten (tested), and a level
//    names the actions it adds (MemPlan.actions) so the `mem` log says what was shed.
//  - Thermal SERIOUS steps the expensive work down (device-surface cadence, mask rebuilds, tile loads) independent of
//    memory.

public enum MemLevel: Int, Comparable, CaseIterable {
    case normal = 0, trim, shed, critical
    public static func < (a: MemLevel, b: MemLevel) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["normal", "trim", "shed", "critical"][rawValue] }
}

/// Footprint + warnings -> level. Raises at once, lowers one step at a time after `holdS` below the step's threshold
/// minus `hysteresisMB` (so a level does not flap at its edge).
public struct MemoryGovernor {
    public struct Config: Equatable {
        /// The steady state to stay under (the owner's target ~1.8 GB), capped at `targetShare` of the per-app limit.
        public var targetMB: Double = 1800
        public var targetShare: Double = 0.55
        /// trim from this share of the target
        public var trimShare: Double = 0.85
        /// critical from target + this, capped at `criticalShare` of the limit
        public var criticalOverMB: Double = 600
        public var criticalShare: Double = 0.75
        public var hysteresisMB: Double = 150
        public var holdS: Double = 20
        public var warningWindowS: Double = 60
        public init() {}
    }

    public var config: Config
    public private(set) var level: MemLevel = .normal
    public private(set) var peakLevel: MemLevel = .normal
    private var calmSince: Double?
    private var warnings: [Double] = []
    public private(set) var warningCount = 0

    public init(config: Config = Config()) { self.config = config }

    public func targetMB(limitMB: Double?) -> Double {
        guard let l = limitMB, l > 0 else { return config.targetMB }
        return min(config.targetMB, config.targetShare * l)
    }

    /// Footprint thresholds (MB) of trim / shed / critical.
    public func thresholds(limitMB: Double?) -> (trim: Double, shed: Double, critical: Double) {
        let t = targetMB(limitMB: limitMB)
        var c = t + config.criticalOverMB
        if let l = limitMB, l > 0 { c = min(c, config.criticalShare * l) }
        return (t * config.trimShare, t, max(c, t + 1))
    }

    /// The level the footprint alone asks for.
    public func levelFor(footprintMB f: Double, limitMB: Double?, margin: Double = 0) -> MemLevel {
        let th = thresholds(limitMB: limitMB)
        if f >= th.critical - margin { return .critical }
        if f >= th.shed - margin { return .shed }
        if f >= th.trim - margin { return .trim }
        return .normal
    }

    /// A UIApplication memory warning: iOS is already short. At least `shed`; 3 inside the window = critical.
    @discardableResult
    public mutating func warning(now: Double) -> MemLevel {
        warningCount += 1
        warnings.append(now)
        warnings.removeAll { now - $0 > config.warningWindowS }
        let want: MemLevel = warnings.count >= 3 ? .critical : .shed
        raise(to: want)
        calmSince = nil
        return level
    }

    /// A periodic sample (≥ 1 Hz). Returns the level after it.
    @discardableResult
    public mutating func update(footprintMB f: Double?, limitMB: Double?, now: Double) -> MemLevel {
        guard let f else { return level }
        warnings.removeAll { now - $0 > config.warningWindowS }
        let want = levelFor(footprintMB: f, limitMB: limitMB)
        if want > level {
            raise(to: want)
            calmSince = nil
            return level
        }
        // lower one step only after holdS clearly under the CURRENT level's threshold and no recent warning
        let floorByWarnings: MemLevel = warnings.isEmpty ? .normal : .trim
        let calm = levelFor(footprintMB: f, limitMB: limitMB, margin: config.hysteresisMB) < level && level > floorByWarnings
        if calm {
            if let c = calmSince {
                if now - c >= config.holdS {
                    level = MemLevel(rawValue: level.rawValue - 1) ?? .normal
                    calmSince = now
                }
            } else {
                calmSince = now
            }
        } else {
            calmSince = nil
        }
        return level
    }

    private mutating func raise(to l: MemLevel) {
        if l > level { level = l }
        if level > peakLevel { peakLevel = level }
    }
}

/// What the app may hold / do at a memory level and thermal state. Every knob is monotone: a higher level never
/// allows more (MemPlanTests).
public struct MemPlan: Equatable {
    public var level: MemLevel
    public var thermal: ThermalLevel
    // base tiles (TileSelect budgets, the server's mem estimate)
    public var tileNearMB: Int
    public var tileMidMB: Int
    /// Seconds an unwanted base tile stays loaded (stops reload churn at band edges); 0 = release at once.
    public var tileLingerS: Double
    public var tileLingerMB: Int
    public var tileConcurrent: Int
    // live downlink mesh tiles + Layer B tiles: near you only
    public var liveRadiusM: Double
    public var liveMaxTiles: Int
    public var layerBRadiusM: Double
    public var layerBMaxTiles: Int
    // 12.22 islands: live feeds of other frames (the island you are in first), and their mesh tiles in total
    public var islandMaxMaps: Int
    public var islandMaxTiles: Int
    public var islandRadiusM: Double
    // device surface
    public var deviceCellsMax: Int
    public var deviceKeepRadiusM: Double
    public var deviceEveryS: Double
    /// A masked tile is rebuilt at most this often (each rebuild re-reads and re-uploads the tile's indices).
    public var maskRebuildMinS: Double
    public var maskRebuildsPerCycle: Int
    // ARKit mesh
    /// Our wire overlay copies (vertices; 0 = overlay off) and the radius anchors are drawn in when over it.
    public var overlayMaxVertices: Int
    public var overlayRadiusM: Double
    /// ARKit's own reconstruction: over this many vertices it is reset (it rebuilds around you). 0 = reset now.
    public var arMeshVertexCap: Int
    /// ARKit environment probes (memory grows with the area walked).
    public var environmentProbes: Bool
    // sim
    public enum SimTemplates: String, Equatable { case all, inUse, none }
    public var simTemplates: SimTemplates

    public static let overlayVertexCap = [400_000, 250_000, 120_000, 0]
    public static let arMeshCap = [600_000, 400_000, 250_000, 0]

    /// `walking` = Live map streams (the area walked grows; environment probes grow with it).
    public static func plan(level: MemLevel, thermal: ThermalLevel, walking: Bool = false) -> MemPlan {
        let i = level.rawValue
        let hot = thermal == .serious || thermal == .critical
        var p = MemPlan(level: level, thermal: thermal,
                        tileNearMB: [300, 220, 150, 90][i], tileMidMB: [120, 60, 20, 0][i],
                        tileLingerS: [20, 0, 0, 0][i], tileLingerMB: [60, 0, 0, 0][i],
                        tileConcurrent: [3, 3, 2, 1][i],
                        liveRadiusM: [24, 18, 14, 10][i], liveMaxTiles: [64, 40, 28, 16][i],
                        layerBRadiusM: [24, 18, 14, 10][i], layerBMaxTiles: [64, 40, 28, 16][i],
                        islandMaxMaps: [3, 2, 1, 1][i], islandMaxTiles: [48, 32, 16, 8][i],
                        islandRadiusM: [40, 30, 20, 12][i],
                        deviceCellsMax: [800_000, 400_000, 200_000, 100_000][i],
                        deviceKeepRadiusM: [15, 10, 8, 6][i],
                        deviceEveryS: [0.4, 0.4, 0.8, 1.6][i],
                        maskRebuildMinS: [1.0, 1.5, 3.0, 6.0][i], maskRebuildsPerCycle: [3, 2, 1, 1][i],
                        overlayMaxVertices: overlayVertexCap[i], overlayRadiusM: [10, 8, 6, 0][i],
                        arMeshVertexCap: arMeshCap[i],
                        environmentProbes: i == 0 && !walking,
                        simTemplates: [.all, .inUse, .inUse, .none][i])
        if hot {                                       // thermal SERIOUS / CRITICAL: step the expensive work down
            p.deviceEveryS = max(p.deviceEveryS, thermal == .critical ? 2.0 : 1.2)
            p.maskRebuildMinS = max(p.maskRebuildMinS, thermal == .critical ? 8 : 4)
            p.maskRebuildsPerCycle = 1
            p.tileConcurrent = 1
            p.tileLingerS = max(p.tileLingerS, 30)    // reloading costs heat: keep what is loaded (within its MB)
            p.environmentProbes = false
        }
        return p
    }

    /// What this plan sheds compared with the normal one (for the `mem` log), in shed order.
    public var actions: [String] {
        var a: [String] = []
        let n = MemPlan.plan(level: .normal, thermal: .nominal)
        if !environmentProbes && n.environmentProbes { a.append("env_probes_off") }
        if tileLingerS == 0 && n.tileLingerS > 0 { a.append("tile_linger_off") }
        if simTemplates != .all { a.append(simTemplates == .none ? "sim_templates_all" : "sim_templates_unused") }
        if liveMaxTiles < n.liveMaxTiles { a.append("live_tiles_\(liveMaxTiles)") }
        if islandMaxTiles < n.islandMaxTiles { a.append("island_tiles_\(islandMaxMaps)x\(islandMaxTiles)") }
        if tileNearMB < n.tileNearMB { a.append("tiles_\(tileNearMB)_\(tileMidMB)mb") }
        if deviceCellsMax < n.deviceCellsMax { a.append("device_cells_\(deviceCellsMax / 1000)k") }
        if overlayMaxVertices < n.overlayMaxVertices { a.append(overlayMaxVertices == 0 ? "overlay_off" : "overlay_\(overlayMaxVertices / 1000)k") }
        if arMeshVertexCap < n.arMeshVertexCap { a.append(arMeshVertexCap == 0 ? "ar_mesh_reset" : "ar_mesh_cap_\(arMeshVertexCap / 1000)k") }
        if deviceEveryS > n.deviceEveryS { a.append("device_every_\(deviceEveryS)s") }
        if maskRebuildMinS > n.maskRebuildMinS { a.append("mask_rebuild_\(maskRebuildMinS)s") }
        return a
    }
}

/// Per-key spatial LRU: an entry has a 2D centre (map or world, the caller's choice), a size and a last use. Evicts
/// what is beyond `radius` first, then the farthest (oldest on ties) until count and bytes fit.
public struct SpatialLRU<Key: Hashable> {
    public struct Entry: Equatable {
        public var x: Double
        public var y: Double
        public var bytes: Int
        public var lastUse: Double
    }

    public private(set) var entries: [Key: Entry] = [:]
    public private(set) var totalBytes = 0
    public init() {}

    public var count: Int { entries.count }

    public mutating func put(_ k: Key, x: Double, y: Double, bytes: Int, now: Double) {
        remove(k)
        entries[k] = Entry(x: x, y: y, bytes: max(0, bytes), lastUse: now)
        totalBytes += max(0, bytes)
    }

    public mutating func touch(_ k: Key, now: Double) { entries[k]?.lastUse = now }

    @discardableResult
    public mutating func remove(_ k: Key) -> Entry? {
        guard let e = entries.removeValue(forKey: k) else { return nil }
        totalBytes -= e.bytes
        return e
    }

    /// Keys to drop (not removed here: the caller releases them, then calls remove). `protected` are never chosen.
    public func evictions(x: Double, y: Double, radius: Double, maxCount: Int, maxBytes: Int = .max,
                          protected: Set<Key> = []) -> [Key] {
        func d2(_ e: Entry) -> Double { (e.x - x) * (e.x - x) + (e.y - y) * (e.y - y) }
        let r2 = radius * radius
        var out: [Key] = []
        var cnt = entries.count, bytes = totalBytes
        let cands = entries.filter { !protected.contains($0.key) }
            .sorted { a, b in
                let da = d2(a.value), db = d2(b.value)
                return da != db ? da > db : a.value.lastUse < b.value.lastUse
            }
        for (k, e) in cands {
            let far = d2(e) > r2
            guard far || cnt > maxCount || bytes > maxBytes else { break }
            out.append(k)
            cnt -= 1
            bytes -= e.bytes
        }
        return out
    }
}

/// Per-subsystem memory accounting for the `mem` log (`mb_*` fields): estimates in bytes, named by subsystem.
public struct MemAccount: Equatable {
    public private(set) var bytes: [String: Int] = [:]
    public init() {}
    public mutating func set(_ name: String, _ b: Int) { bytes[name] = max(0, b) }
    public var totalMB: Double { Double(bytes.values.reduce(0, +)) / 1_048_576 }
    /// Flat log fields "mb_<name>" (MB, 0.1 resolution) + "mb_accounted" (the log format has no nested objects).
    public var fields: [String: LogValue] {
        var o: [String: LogValue] = [:]
        for (k, v) in bytes { o["mb_" + k] = .double((Double(v) / 1_048_576 * 10).rounded() / 10) }
        o["mb_accounted"] = .double((totalMB * 10).rounded() / 10)
        return o
    }
}

/// Unaccounted footprint (footprint − the accounted estimates) over time: the residual is what a future session log
/// attributes to "elsewhere" (RealityKit internals, ARKit). A residual that keeps growing over a walk is a leak.
public struct MemTrend {
    public private(set) var samples: [(t: Double, mb: Double)] = []
    public var windowS: Double
    public init(windowS: Double = 300) { self.windowS = windowS }
    public mutating func add(t: Double, mb: Double) {
        samples.append((t, mb))
        samples.removeAll { t - $0.t > windowS }
    }
    /// MB per minute over the window (least squares); nil with < 3 samples or < 30 s.
    public var slopeMBPerMin: Double? {
        guard samples.count >= 3, let f = samples.first, let l = samples.last, l.t - f.t >= 30 else { return nil }
        let n = Double(samples.count)
        let mt = samples.map(\.t).reduce(0, +) / n, mm = samples.map(\.mb).reduce(0, +) / n
        var num = 0.0, den = 0.0
        for s in samples { num += (s.t - mt) * (s.mb - mm); den += (s.t - mt) * (s.t - mt) }
        return den > 0 ? num / den * 60 : nil
    }
}

/// Layer B / live tile lag: `hw_wall` is the capture time of the newest keyframe fused into a tile. A frame that
/// repeats an older hw_wall (a block re-sent, a neighbour's change) is not a new capture: counting it as lag grew the
/// 12.19 lag_ms p50 to 39 s while the real lag was ~1-2 s. Only advances count.
public struct FreshLag {
    private var lastWall: [String: Double] = [:]
    public init() {}
    /// Lag in ms of this frame when it carries a NEWER capture for the key; nil otherwise.
    public mutating func lag(key: String, hwWall: Double?, now: Double) -> Double? {
        guard let w = hwWall, w > 0 else { return nil }
        if let p = lastWall[key], w <= p { return nil }
        lastWall[key] = w
        let l = (now - w) * 1000
        guard l > -2000, l < 600_000 else { return nil }
        return max(0, l)
    }
    public mutating func forget(_ key: String) { lastWall[key] = nil }
    public var count: Int { lastWall.count }
}
