import Foundation
import XCTest
@testable import SnailSightCore

/// 12.23 walk simulation harness (snailCOP services/snailsight/tools/walk_sim.py, docs/SNAILSIGHT-WALK-SIM-2026-10-31.md).
/// Env-gated: SNAILSIGHT_WALKSIM = a fixture dir from `walk_sim gen`, SNAILSIGHT_WALKSIM_OUT = where to write.
/// The REAL core logic per frame, as the app runs it:
///  - LiveGate + LivePause: which 30 Hz frames become live keyframes (Record off / on; 12.22 paused for Record).
///  - TileSelect at the owner's memory level (MemPlan trim, 10-31 log): which base tiles are loaded; a (re)loaded tile
///    registers its faces with the device surface, an evicted one unregisters (12.22: no hysteresis; 12.23: 4 m).
///  - DeviceSurfaceEngine with the MemPlan cadence / rebuild pacing: 12.22 hideSeen vs 12.23 confirm.
/// Writes vis-<variant>.bin (per depth frame, a bit per base face: drawn now) and keyframes-<scenario>.json.
final class WalkSimTests: XCTestCase {
    struct Variant {
        let name: String
        let policy: StoredFacePolicy?          // nil = device surface off (every loaded face drawn)
        let keepBonusM: Double
        var hybridRadius: Float? = nil         // confirm within R of the camera, 12.22 rule beyond
        var hiddenWhileRecording = false       // 12.22: no map and no tile loads while Record is on
        var useNormals = true
    }

    func testWalk() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SNAILSIGHT_WALKSIM"] else { throw XCTSkip("SNAILSIGHT_WALKSIM not set") }
        let out = URL(fileURLWithPath: env["SNAILSIGHT_WALKSIM_OUT"] ?? dir)
        let fx = URL(fileURLWithPath: dir)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.appendingPathComponent("meta.json"))) as! [String: Any]
        let nFaces = meta["faces"] as! Int
        let dw = meta["depth_w"] as! Int, dh = meta["depth_h"] as! Int
        let K = (meta["K"] as! [Double]).map(Float.init)
        let frames = meta["frames"] as! [[String: Any]]
        let tiles = meta["tiles"] as! [[String: Any]]
        let al = (meta["align_shown"] as! [Double])
        let align = Align4(x: al[0], y: al[1], z: al[2], yaw: al[3])
        let exposure = meta["exposure_s"] as! Double
        func f32(_ name: String) throws -> [Float] {
            let d = try Data(contentsOf: fx.appendingPathComponent(name))
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let cent = try f32("centroids.f32")
        let nrm = (try? Data(contentsOf: fx.appendingPathComponent("normals.i8"))).map { d in d.map { Int8(bitPattern: $0) } } ?? []
        let depthAll = try f32("depth.f32")
        let confAll = [UInt8](try Data(contentsOf: fx.appendingPathComponent("conf.u8")))
        XCTAssertEqual(cent.count, nFaces * 3)
        let px = dw * dh

        // ── live keyframes: LiveGate + LivePause on every 30 Hz frame ───────────────────────────────────────────────
        var kfReport: [String: Any] = [:]
        let recEnd = (meta["rec"] as! [Double])[1]
        // rec_on_1222_owner = the 10-31 walk: Live paused while recording AND Live off 2.7 s after Record stopped
        for (scen, rec, pauseRec) in [("rec_off", false, false), ("rec_on_1222", true, true), ("rec_on_1223", true, false),
                                      ("rec_on_1222_owner", true, true)] {
            var gate = LiveGate(rateHz: 2)
            var prev: (t: Double, pos: [Double], q: CaptureFormat.Quat)?
            var kfs: [[String: Any]] = []
            var still = 0, blurry = 0, paused = 0
            for (i, fr) in frames.enumerated() {
                let t = fr["t"] as! Double
                let c = (fr["cam"] as! [Double])
                var T = [Double](repeating: 0, count: 16)       // row-major camera -> world from column-major
                for col in 0..<4 { for r in 0..<4 { T[r * 4 + col] = c[col * 4 + r] } }
                let recording = rec && (fr["rec"] as! Bool)
                if scen == "rec_on_1222_owner" && t > recEnd + 2.7 { paused += 1; continue }   // Live map went off
                if LivePause.reason(recording: recording, scansOpen: false, map3DOpen: false, thermalCritical: false,
                                    trackingNormal: true, pauseWhileRecording: pauseRec) != nil {
                    paused += 1; prev = nil; continue
                }
                let pos = [T[3], T[7], T[11]]
                let q = CaptureFormat.quaternion(rows: [[T[0], T[1], T[2]], [T[4], T[5], T[6]], [T[8], T[9], T[10]]])
                var blur: Double?
                if let p = prev, t > p.t {
                    let dt = t - p.t
                    let dx = pos[0] - p.pos[0], dy = pos[1] - p.pos[1], dz = pos[2] - p.pos[2]
                    blur = KeyframeQuality.predictedBlurPx(
                        angularSpeedRadS: AdaptiveCapture.rotationDegrees(p.q, q) * .pi / 180 / dt,
                        linearSpeedMS: (dx * dx + dy * dy + dz * dz).squareRoot() / dt, depthM: 1.5,
                        exposureS: exposure, focalPx: 1337.86)
                }
                prev = (t, pos, q)
                switch gate.decide(t: t, T: T, blurPx: blur) {
                case .capture:
                    gate.commit(t: t, T: T)
                    kfs.append(["i": i, "t": t, "blur": blur ?? 0])
                case .still: still += 1
                case .blurry: blurry += 1
                case .tooSoon: break
                }
            }
            let dur = frames.last?["t"] as? Double ?? 0
            let doc: [String: Any] = ["scenario": scen, "keyframes": kfs, "count": kfs.count, "still_frames": still,
                                      "blurry_frames": blurry, "paused_frames": paused, "duration_s": dur]
            try JSONSerialization.data(withJSONObject: doc).write(to: out.appendingPathComponent("keyframes-\(scen).json"))
            kfReport[scen] = ["count": kfs.count, "still": still, "blurry": blurry, "paused": paused,
                              "hz": Double(kfs.count) / max(dur, 1)]
        }
        // the owner's walk "Live map with Record" is the real starvation case: the 12.23 stream equals Record off
        XCTAssertEqual((kfReport["rec_on_1223"] as! [String: Any])["count"] as! Int,
                       (kfReport["rec_off"] as! [String: Any])["count"] as! Int)

        // ── base tiles + device surface per variant ─────────────────────────────────────────────────────────────────
        let plan = MemPlan.plan(level: .trim, thermal: .nominal)     // the owner's 10-31 walk ran at trim most of the time
        var nodes: [TileNode] = []
        var range: [String: (Int, Int)] = [:]
        for t in tiles {
            let key = t["key"] as! String
            let b = t["box"] as! [Double]
            nodes.append(TileNode(key: key, level: 0, size: 4, box: [b[0], b[1], b[2], b[3], 0, 0, 0, b[4], 0, 0, 0, b[5]],
                                  uri: "\(key).usdz", mem: t["mem"] as! Int))
            range[key] = (t["start"] as! Int, t["count"] as! Int)
        }
        let variants = [Variant(name: "off", policy: nil, keepBonusM: 0),
                        Variant(name: "v1222", policy: .hideSeen, keepBonusM: 0),
                        Variant(name: "v1222_rec", policy: .hideSeen, keepBonusM: 0, hiddenWhileRecording: true),
                        Variant(name: "v1223_rec", policy: .confirm, keepBonusM: 4),
                        Variant(name: "v1223_nohyst", policy: .confirm, keepBonusM: 0),
                        Variant(name: "v1223_nonormal", policy: .confirm, keepBonusM: 4, useNormals: false),
                        Variant(name: "hybrid3", policy: .confirm, keepBonusM: 4, hybridRadius: 3),
                        Variant(name: "v1223", policy: .confirm, keepBonusM: 4)]
        var report: [String: Any] = ["keyframes": kfReport, "plan": ["level": "trim", "tileNearMB": plan.tileNearMB,
                                                                     "maskRebuildMinS": plan.maskRebuildMinS,
                                                                     "deviceEveryS": plan.deviceEveryS]]
        for v in variants {
            var engine = DeviceSurfaceEngine()
            var hybrid = DeviceSurfaceEngine()                       // hideSeen twin for the hybrid's far rule
            var loaded = Set<String>(), loading: [String: Double] = [:]
            var mask: [String: [Bool]] = [:]                          // applied (drawn) masks per tile
            var motion = TileMotion()
            var lastTick = -1.0, lastObs = -1e9
            var visBytes = Data()
            var loads = 0, evicts = 0, registers = 0, flashFaces = 0
            var obsMs: [Double] = []
            let per = (nFaces + 7) / 8
            for fr in frames {
                let t = fr["t"] as! Double
                let c = (fr["cam"] as! [Double]).map(Float.init)
                let camMap = align.toMap([Double(c[12]), Double(c[13]), Double(c[14])])
                // TileStreamer tick every 0.5 s: select, finish loads (0.5 s each, <= plan.tileConcurrent), evict
                let recNow = fr["rec"] as! Bool
                if t - lastTick >= TileSelect.stepS && !(v.hiddenWhileRecording && recNow) {
                    lastTick = t
                    motion.add(t: t, x: camMap[0], y: camMap[1])
                    let fwd = align.toMap([Double(c[12] - c[8]), Double(c[13] - c[9]), Double(c[14] - c[10])])
                    let heading = TileMotion.heading(forward: [fwd[0] - camMap[0], fwd[1] - camMap[1], fwd[2] - camMap[2]])
                    let want = TileSelect.select(nodes, cam: camMap, heading: heading, speed: motion.speed,
                                                 nearBudget: plan.tileNearMB << 20, midBudget: plan.tileMidMB << 20,
                                                 keep: loaded, keepBonusM: v.keepBonusM)
                    for k in loading.keys where want[k] == nil { loading[k] = nil }
                    for (k, t0) in loading where t - t0 >= 0.5 {
                        loading[k] = nil
                        loaded.insert(k)
                        loads += 1
                        let (s, n) = range[k]!
                        let cs = Array(cent[(s * 3)..<((s + n) * 3)])
                        let ns = nrm.count == cent.count ? Array(nrm[(s * 3)..<((s + n) * 3)]) : []
                        if let p = v.policy {
                            registers += 1
                            let d = engine.register(id: k, centroids: cs, normals: v.useNormals ? ns : [], policy: p,
                                                    active: true, now: t)
                            mask[k] = d?.hidden ?? []
                            if v.hybridRadius != nil { _ = hybrid.register(id: k, centroids: cs, policy: .hideSeen, active: true, now: t) }
                            if p == .hideSeen && d == nil && engine.grid.count > 0 { flashFaces += 0 }
                        } else { mask[k] = [] }
                    }
                    for k in loaded where want[k] == nil {
                        loaded.remove(k); evicts += 1; mask[k] = nil
                        engine.unregister(id: k); hybrid.unregister(id: k)
                    }
                    for w in TileSelect.fetchOrder(want, loaded: loaded) where loading.count < plan.tileConcurrent && loading[w.node.key] == nil {
                        loading[w.node.key] = t
                    }
                }
                // device surface: one depth frame per deviceEveryS
                guard let di = fr["depth"] as? Int else { continue }
                if v.policy != nil, t - lastObs >= plan.deviceEveryS - 1e-6 {
                    lastObs = t
                    let d = Array(depthAll[(di * px)..<((di + 1) * px)])
                    let cf = Array(confAll[(di * px)..<((di + 1) * px)])
                    let t0 = Date()
                    let cy = engine.observe(depth: d, width: dw, height: dh, confidence: cf, K: K, camToWorld: c,
                                            align: align, plan: plan, now: t)
                    obsMs.append(Date().timeIntervalSince(t0) * 1000)
                    for dl in cy.deliveries where loaded.contains(dl.id) { mask[dl.id] = dl.hidden }
                    if v.hybridRadius != nil {
                        _ = hybrid.observe(depth: d, width: dw, height: dh, confidence: cf, K: K, camToWorld: c,
                                           align: align, plan: plan, now: t)
                    }
                }
                // what is drawn right now (one bit per base face)
                var bits = [UInt8](repeating: 0, count: per)
                for k in loaded where !(v.hiddenWhileRecording && recNow) {
                    let (s, n) = range[k]!
                    var m = mask[k] ?? []
                    if let R = v.hybridRadius, let cm = engine.mask(k), let hm = hybrid.mask(k) {
                        m = [Bool](repeating: false, count: n)
                        for f in 0..<n {
                            let i = s + f
                            let dx = cent[i * 3] - Float(camMap[0]), dy = cent[i * 3 + 1] - Float(camMap[1])
                            let near = (dx * dx + dy * dy).squareRoot() <= R
                            let seen = hm.isEmpty ? false : hm[f]
                            m[f] = near ? cm[f] : seen
                        }
                    }
                    for f in 0..<n where m.isEmpty || !m[f] {
                        let i = s + f
                        bits[i >> 3] |= UInt8(1 << (i & 7))
                    }
                }
                visBytes.append(contentsOf: bits)
            }
            try visBytes.write(to: out.appendingPathComponent("vis-\(v.name).bin"))
            let ms = obsMs.sorted()
            report[v.name] = ["tile_loads": loads, "tile_evictions": evicts, "registers": registers,
                              "observe_ms_p50": ms.isEmpty ? -1 : ms[ms.count / 2], "observe_ms_max": ms.last ?? -1,
                              "hits_voxels": engine.hits.count, "coverage_cells": engine.grid.count,
                              "faces": engine.faces, "hidden_end": engine.hidden]
            _ = flashFaces
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("swift-report.json"))
        print("WALKSIM", String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
