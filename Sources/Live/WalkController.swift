// SnailSight 12.26 one-tap walk (owner 2026-11-13: "prioritize ensuring the iphone app is streamlined so that we can do a
// walk test soon to validate"; walk test script snailCOP docs/SNAILSIGHT-WALK-TEST.md, scorer
// services/snailsight/tools/walk_validate.py). Start walk (sheet quick action, launch chooser, the snailCOP pill menu or
// snailsight://walk): AR explore → close full-screen views → warm + resume the localizer → Live map on. ONE status line
// (SnailSightCore WalkSession): finding position → locked → streaming (sent / accepted / trusted, server delay) →
// problems in plain words, plus at most one gentle capture hint (CaptureGuidance, off switch Mapping ▸ Walk hints).
// Stop walk: Live map off (the stream drains and says bye with `recorded`, so the server promotes it in ~2 min and
// auto-improve + object detection follow) and a short summary card. Record stays optional and separate.
// Logs (contract with walk_validate): walk_start, walk_phase, walk_lock, walk_progress (30 s), walk_hint, walk_stop.
import ARKit
import Foundation
import SnailSightCore

final class WalkController: ObservableObject {
    private unowned let model: AppModel
    @Published private(set) var session: WalkSession?
    @Published private(set) var line: WalkLine?
    @Published private(set) var hint: WalkHintKind?
    @Published private(set) var summary: WalkSummary?
    @Published var expanded = false
    /// Mapping ▸ Walk hints (default on, remembered).
    @Published var hintsOn: Bool = UserDefaults.standard.object(forKey: "walk.hints") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hintsOn, forKey: "walk.hints")
            if hintsOn != oldValue { model.log.event("walk_hints", ["on": .bool(hintsOn)]) }
            if !hintsOn { hint = nil }
        }
    }
    private var guidance = WalkGuidance()
    private var lastQ: (q: CaptureQuality, t: Double)?
    private var confMissing = 0
    private var lastProgress = 0.0
    private var lastTick = 0.0
    private var prevPose: (p: SIMD3<Float>, f: SIMD3<Float>, t: Double)?
    private var wasRecording = false
    private var stopAt: Double?
    private var stopCause = ""

    init(model: AppModel) { self.model = model }

    var active: Bool { session != nil && stopAt == nil }
    /// 12.27: Record ran during this walk (the Rescan finish says `recorded`).
    var recordedDuringWalk: Bool { wasRecording || model.recording }
    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: start / stop

    /// The one tap. From any mode; AR starts on demand (12.25 setMode).
    func start(cause: String) {
        guard !active else { return }
        let from = model.appMode?.rawValue ?? "chooser"
        if model.appMode != .ar { model.setMode(.ar, cause: "walk") }
        guard model.appMode == .ar else { return }
        summary = nil
        expanded = false
        // the walk is the camera view: close what would pause the localizer / Live map
        model.showMap = false
        model.showMap3D = false
        model.showScans = false
        model.showSettings = false
        model.sheetDetent = .collapsed
        if model.spawnMode { model.endSpawnMode() }
        let liveWas = model.liveOn
        let snap = model.liveStreamer.current
        var s = WalkSession(now: now, cause: cause, sentBase: liveWas ? 0 : snap.sent, ackedBase: liveWas ? 0 : snap.acked)
        s.stream(model.liveStreamer.streamID)
        session = s
        guidance = WalkGuidance()
        lastQ = nil
        confMissing = 0
        lastProgress = now
        prevPose = nil
        stopAt = nil
        hint = nil
        model.log.event("walk_start", ["cause": .string(cause), "from_mode": .string(from), "map_id": .string(model.liveMapID),
                                       "rate_hz": .double(model.liveRateHz), "hints": .bool(hintsOn),
                                       "live_was_on": .bool(liveWas), "server": .bool(model.serverBase != nil),
                                       "locked": .bool(model.mapLocalizer.isLocked),
                                       "features": .string(model.serverFeatures.list.sorted().joined(separator: ","))])
        model.warmLocalizer(reason: "walk")
        if !model.mapLocalizer.isLocked { model.mapLocalizer.resume(why: "walk") }
        if !model.liveOn { model.setLive(true, cause: "walk_start") }
        if !model.meshLive { model.meshLive = true }
        model.flash(cause == "rescan" ? "Rescan started: scan slowly, 1-2.5 m from surfaces" : "Walk started: finding your position",
                    seconds: 2.5)
        tick(frame: nil)
    }

    /// Stop walk (or the walk ended because Live map went off / the app left AR).
    func stop(cause: String) {
        guard var s = session, stopAt == nil else { return }
        stopAt = now
        stopCause = cause
        s.stopping()
        session = s
        if model.liveOn { model.setLive(false, cause: "walk_stop") }
        let snap = model.liveStreamer.current
        let sum = WalkSummary(s, now: now, queue: snap.queue)
        summary = sum
        hint = nil
        let m = guidance.means
        var ev: [String: LogValue] = [
            "cause": .string(cause), "duration_s": .double(sum.durationS.rounded()), "sent": .int(s.sent), "acked": .int(s.acks),
            "dups": .int(s.dups), "trusted": .int(s.trusted), "trusted_pct": .double((s.trustedPct * 10).rounded() / 10),
            "placed": .bool(sum.placed), "lock_s": .double(sum.lockS.map { ($0 * 10).rounded() / 10 } ?? -1),
            "cells": .int(s.coverage.cells), "in_map": .bool(s.coverage.inMap),
            "coverage": .double((s.coverage.meanShare * 100).rounded() / 100),
            "streams": .string(s.streams.joined(separator: ",")),
            "rate_hints": .int(model.liveStreamer.rateCap.hints), "rate_min_hz": .double(model.liveStreamer.rateCap.minHz ?? -1),
            "hints_shown": .string(guidance.shownText), "hints_on": .bool(hintsOn),
            "conf_missing": .int(confMissing), "mem_level_max": .string(s.memMax), "errors": .int(s.errors),
            "recorded": .bool(wasRecording), "queue": .int(snap.queue), "kf_measured": .int(guidance.samples),
        ]
        if let m {
            ev["q_conf_low"] = .double((m.conf * 1000).rounded() / 1000)
            ev["q_far"] = .double((m.far * 1000).rounded() / 1000)
            ev["q_graze"] = .double((m.graze * 1000).rounded() / 1000)
            ev["q_nodepth"] = .double((m.nodepth * 1000).rounded() / 1000)
        }
        model.log.event("walk_stop", ev)
        model.syncLogs()                                     // the scorer reads this session's log on the server
        model.rescan.walkStopped(cause: cause)               // 12.27: a walk that ends during a Rescan is its Finish
    }

    /// The summary card's Done.
    func dismissSummary() {
        summary = nil
        session = nil
        line = nil
        stopAt = nil
    }

    // MARK: inputs from the rest of the app

    /// Every uplink ack with stages / gate / rate (main).
    func ack(_ o: [String: Any]) {
        guard var s = session, stopAt == nil else { return }
        let g = (o["gate"] as? [String: Any])?["state"] as? String
        s.ack(gate: g, dup: (o["dup"] as? Bool) == true)
        session = s
    }

    /// A live keyframe was encoded: its measured depth quality (nil = no confidence map / not measured).
    func keyframe(quality q: CaptureQuality?, conf: Bool, stream: String) {
        guard var s = session, stopAt == nil else { return }
        if !conf { confMissing += 1 }
        s.stream(stream)
        session = s
        guard let q else { return }
        guidance.keyframe(q)
        lastQ = (q, now)
    }

    func liveError() {
        guard var s = session, stopAt == nil else { return }
        s.error()
        session = s
    }

    /// Live map went off by itself (thermal kill, mode switch, owner tap in Mapping): the walk ends with it.
    func liveTurnedOff(cause: String) {
        guard active, cause != "walk_stop" else { return }
        stop(cause: "live_off:" + cause)
    }

    // MARK: tick (AR HUD tick, 2 Hz)

    func tick(frame: ARFrame?) {
        guard var s = session else { return }
        let t = now
        if stopAt != nil {
            // keep the summary's "still uploading" honest while the spool drains
            let q = model.liveStreamer.current.queue
            if let sum = summary, sum.queueLeft != q { var x = sum; x.queueLeft = q; summary = x }
            return
        }
        lastTick = t
        if model.recording { wasRecording = true }
        let snap = model.liveStreamer.current
        var i = WalkInputs(now: t)
        i.arRunning = model.arActive && !model.arSuspended
        i.tracking = model.tracking.code
        i.server = model.serverBase != nil
        i.liveOnline = snap.online
        i.locked = model.mapLocalizer.isLocked
        i.sigmaCm = model.mapLocalizer.lastSigmaCm ?? model.mapLocalizer.errorEstimate
        i.placed = snap.placed
        i.sent = snap.sent
        i.acked = snap.acked
        i.queue = snap.queue
        i.lagMs = snap.lagMs
        i.serverDelayMs = model.liveStages.totalMs
        i.gate = model.liveStages.gate
        i.gateWhy = model.liveStages.gateWhy
        i.paused = model.liveStreamer.pausedNow
        i.rateHz = model.liveRateHz
        i.rateCapHz = model.liveStreamer.rateCap.capHz
        i.memLevel = model.memPlan.level.label
        let wasLocked = s.lockedAt != nil
        // coverage + speed from the camera
        var turn: Double?, move: Double?
        if let f = frame {
            let M = f.camera.transform
            let p = SIMD3<Float>(M.columns.3.x, M.columns.3.y, M.columns.3.z)
            let fw = -SIMD3<Float>(M.columns.2.x, M.columns.2.y, M.columns.2.z)
            if let pv = prevPose, t > pv.t {
                let dt = t - pv.t
                move = Double(simd_length(p - pv.p)) / dt
                let c = max(-1, min(1, Double(simd_dot(simd_normalize(fw), simd_normalize(pv.f)))))
                turn = acos(c) * 180 / .pi / dt
            }
            prevPose = (p, fw, t)
            if let mp = model.lastMapPose, t - mp.t < 2, mp.cam.count >= 3, mp.ahead.count >= 2 {
                s.coverage.visit(position: mp.cam, yaw: atan2(mp.ahead[1] - mp.cam[1], mp.ahead[0] - mp.cam[0]), map: true, now: t)
            } else {
                s.coverage.visit(position: [Double(p.x), Double(p.y), Double(p.z)], yaw: atan2(Double(-fw.z), Double(fw.x)),
                                 map: false, now: t)
            }
        }
        let (status, changed) = s.update(i)
        session = s
        if line != status { line = status }
        if changed {
            model.log.event("walk_phase", ["phase": .string(status.phase.rawValue), "t_s": .double((s.elapsed(t) * 10).rounded() / 10),
                                           "why": .string(status.problem ?? "")])
        }
        if !wasLocked, let l = s.lockedAt {
            model.log.event("walk_lock", ["t_s": .double(((l - s.startedAt) * 10).rounded() / 10),
                                          "source": .string(i.placed == true && !i.locked ? "live_placed" : model.mapLocalizer.lockSource),
                                          "sigma_cm": .double(i.sigmaCm ?? -1)])
        }
        // capture guidance: one gentle hint at a time
        if hintsOn {
            let q = lastQ.flatMap { t - $0.t < 2.5 ? $0.q : nil }
            let holds = WalkGuidance.conditions(q: q, blurPx: model.liveStreamer.lastBlurPx, turnDegS: turn, moveMS: move,
                                                coverage: s.coverage.here(now: t))
            if let c = guidance.step(holds, now: t) {
                hint = c.on ? c.kind : nil
                var ev: [String: LogValue] = ["kind": .string(c.kind.rawValue), "on": .bool(c.on)]
                if let q {
                    switch c.kind {
                    case .conf: ev["share"] = .double((q.confLow * 100).rounded() / 100)
                    case .far: ev["share"] = .double((q.far * 100).rounded() / 100)
                    case .graze: ev["share"] = .double((q.graze * 100).rounded() / 100)
                    case .nodepth: ev["share"] = .double(((1 - q.valid) * 100).rounded() / 100)
                    default: break
                    }
                }
                model.log.event("walk_hint", ev)
            }
        }
        if t - lastProgress >= 30 {
            lastProgress = t
            model.log.event("walk_progress", [
                "t_s": .double(s.elapsed(t).rounded()), "sent": .int(s.sent), "acked": .int(s.acks), "trusted": .int(s.trusted),
                "gate": .string(i.gate ?? ""), "gate_why": .string(i.gateWhy ?? ""), "placed": .bool(i.placed ?? false),
                "lag_ms": .double(i.lagMs ?? -1), "queue": .int(i.queue), "rate_hz": .double(model.liveStreamer.rateHz),
                "rate_max_hz": .double(i.rateCapHz ?? -1), "cells": .int(s.coverage.cells), "hint": .string(hint?.rawValue ?? ""),
                "phase": .string(s.phase.rawValue),
            ])
        }
    }
}
