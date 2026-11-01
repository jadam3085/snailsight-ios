// SnailSight 12.18: the device surface is truth near you (live world build 2026-10-28 item 1; SnailSightCore
// DeviceCoverage.swift has the rule and its tests).
//
//  - Every ~0.4 s while the house map is drawn in AR and LiDAR depth flows, one depth frame (256×192, confidence ≥
//    medium, ≤ 4.5 m) marks the 10 cm cells of the ARKit world its rays crossed or ended in (a background queue).
//  - Every stored mesh drawn in the map frame (base tiles: TileStreamer; server live tiles: LiveMapClient) registers its
//    face centroids. A face whose DRAWN place is an observed cell is hidden for the rest of the session; its owner
//    rebuilds the mesh without it (≤ 3 rebuilds per cycle, only when ≥ 24 faces or ≥ 1 % more are hidden).
//  - What you see there instead: the camera picture (the real room), RealityKit's occlusion from the ARKit scene mesh
//    (depth-only) and, with Layers ▸ Mesh (live), the faint wire of this phone's own scene mesh.
//  - Off (Layers ▸ Device surface near you) = every stored face back; ARKit world frame change = coverage cleared.
//  - 12.23 show on confirm (SnailSightCore SurfaceConfirm.swift): BASE tiles are drawn only where this phone's depth
//    agrees with them (a return within 4 cm of the face's plane, facing the same way, not crossed since); a (re)loaded
//    tile starts hidden. Live surfaces (server live tiles, Layer B) keep the 12.18 hide-after-seen rule.
// Logs: device_surface (every 10 s), device_surface_first_hide, device_surface_toggle, device_surface_reset.
import ARKit
import Foundation
import QuartzCore
import SnailSightCore

final class DeviceSurface {
    typealias Apply = (_ hidden: [Bool], _ hiddenCount: Int) -> Void

    private unowned let model: AppModel
    private let q = DispatchQueue(label: "snailsight.devicesurface", qos: .userInitiated)

    // queue-owned: 12.23 the whole cycle is SnailSightCore.DeviceSurfaceEngine (the walk sim runs the same code)
    private var engine = DeviceSurfaceEngine()

    // main-owned
    private var appliers: [String: Apply] = [:]
    private var busy = false
    private var lastObserve: TimeInterval = 0
    private var wasOn = false
    private var lastLog: TimeInterval = 0
    private var firstHideLogged = false
    private var stats = (frames: 0, observeMs: [Double](), rebuilds: 0, rebuildMs: 0.0, marked: 0, hits: 0, passes: 0)
    private var snapshot = (cells: 0, sets: 0, faces: 0, hidden: 0, saturated: false, voxels: 0)
    /// 12.20 `mem` accounting: coverage grid + surface voxels + per-mesh face sets (bytes, queue-computed).
    private(set) var bytes = (grid: 0, faces: 0)
    private(set) var prunedTotal = 0
    private(set) var depthWanted = false

    static let everyS = 0.4
    /// 12.23: base tiles are drawn only where this phone's depth confirms them (walk sim: ghost exposure 8.5 % -> 0.9 %).
    static let basePolicy: StoredFacePolicy = .confirm

    init(model: AppModel) { self.model = model }

    /// The rule is on (setting + 3D world shown in AR + a LiDAR phone).
    var active: Bool { model.deviceTruth && model.worldOn && !model.arSuspended && ARSessionController.supportsDepth }

    /// Confirm meshes start hidden while the rule is on (owners mask before the first delivery).
    var failClosed: Bool { active }

    /// LiDAR depth frames are needed while the house is drawn after a lock (ARSessionController.makeConfiguration).
    var wantsDepth: Bool {
        active && model.mapLocalizer.alignment != nil && model.drawHouse != .off && ARSessionController.supportsDepth
    }

    /// "Device surface · 41 k base faces hidden near you" for the Layers sheet.
    var summary: String {
        guard model.deviceTruth else { return "Off: the stored map is drawn even where the phone sees the room" }
        let s = snapshot
        if s.cells == 0 && s.voxels == 0 { return "Waiting for LiDAR depth near the drawn map" }
        let shown = s.faces - s.hidden
        let k = shown >= 1000 ? String(format: "%.1f k", Double(shown) / 1000) : "\(shown)"
        return "\(k) stored faces drawn where this phone's depth confirms them"
    }

    // MARK: registration (main)

    /// A drawn mesh: `centroids` = x, y, z per face in the MAP frame (+ `normals` ×127 for confirm meshes). `apply` is
    /// called on main with the hidden mask whenever it changes enough (empty = everything drawn).
    func register(id: String, centroids: [Float], normals: [Int8] = [], policy: StoredFacePolicy = .hideSeen,
                  apply: @escaping Apply) {
        appliers[id] = apply
        let on = active
        let now = CACurrentMediaTime()
        q.async { [weak self] in
            guard let self else { return }
            if let d = self.engine.register(id: id, centroids: centroids, normals: normals, policy: policy, active: on,
                                            now: now) {
                DispatchQueue.main.async { self.deliver(d.id, d.hidden, d.hiddenCount) }
            }
        }
    }

    func unregister(id: String) {
        appliers[id] = nil
        q.async { [weak self] in self?.engine.unregister(id: id) }
    }

    private func deliver(_ id: String, _ mask: [Bool], _ n: Int) {
        guard let a = appliers[id] else { return }
        let t0 = CACurrentMediaTime()
        a(mask, n)
        stats.rebuilds += 1
        stats.rebuildMs += (CACurrentMediaTime() - t0) * 1000
        if n > 0 && n < mask.count && !firstHideLogged {
            firstHideLogged = true
            let since = model.mapLocalizer.lockedAt.map { Date().timeIntervalSince1970 - $0 } ?? -1
            model.log.event("device_surface_first_hide", ["id": .string(id), "hidden": .int(n), "faces": .int(mask.count),
                                                          "since_lock_s": .double((since * 10).rounded() / 10),
                                                          "cells": .int(snapshot.cells), "voxels": .int(snapshot.voxels),
                                                          "policy": .string(Self.basePolicy.rawValue)])
        }
    }

    // MARK: frames (main)

    /// Every AR frame, after MapARLayer.frame (`align` = the alignment the map is DRAWN with).
    func frame(_ f: ARFrame, align: Align4?) {
        let on = active
        if on != wasOn {
            wasOn = on
            model.log.event("device_surface_toggle", ["on": .bool(on), "setting": .bool(model.deviceTruth),
                                                      "policy": .string(Self.basePolicy.rawValue)])
            if on { activateAll() } else { restoreAll() }
        }
        let plan = model.memPlan                                   // 12.20: cadence / caps from the memory + heat plan
        guard on, !busy, let al = align, f.timestamp - lastObserve >= max(Self.everyS, plan.deviceEveryS) else { return }
        guard case .normal = f.camera.trackingState, let sd = f.sceneDepth ?? f.smoothedSceneDepth else { return }
        lastObserve = f.timestamp
        let dm = sd.depthMap
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)
        guard w > 0, h > 0, CVPixelBufferGetPixelFormatType(dm) == kCVPixelFormatType_DepthFloat32 else { return }
        let depth = Self.floats(dm, w: w, h: h)
        let conf = sd.confidenceMap.map { Self.bytes($0, w: w, h: h) }
        let img = f.camera.imageResolution
        let sx = Float(w) / Float(img.width), sy = Float(h) / Float(img.height)
        let k = f.camera.intrinsics
        let K: [Float] = [k[0][0] * sx, k[1][1] * sy, k[2][0] * sx, k[2][1] * sy]
        let m = f.camera.transform
        let M: [Float] = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                          m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                          m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                          m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        busy = true
        let now = CACurrentMediaTime()
        q.async { [weak self] in
            guard let self else { return }
            let t0 = CACurrentMediaTime()
            let cy = self.engine.observe(depth: depth, width: w, height: h, confidence: conf, K: K, camToWorld: M,
                                         align: al, plan: plan, now: now)
            let e = self.engine
            let snap = (e.grid.count, e.ids.count, e.faces, e.hidden, e.grid.saturated, e.hits.count)
            let gridBytes = e.grid.estimatedBytes + e.hits.estimatedBytes, faceBytes = e.faceBytes, prunedNow = e.pruned
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                self.busy = false
                guard self.active else { return }                   // switched off meanwhile: restoreAll ran
                self.snapshot = snap
                self.bytes = (gridBytes, faceBytes)
                self.prunedTotal = prunedNow
                self.stats.frames += 1
                self.stats.marked += cy.coverage.marked
                self.stats.hits += cy.surface.hits
                self.stats.passes += cy.surface.passes
                self.stats.observeMs.append(ms)
                for d in cy.deliveries { self.deliver(d.id, d.hidden, d.hiddenCount) }
                self.maybeLog()
            }
        }
    }

    /// Tick (main, 2 Hz): keep LiDAR depth on while it is wanted.
    func tick() {
        let w = wantsDepth
        guard w != depthWanted else { return }
        depthWanted = w
        if !model.arSuspended && !model.recording { model.controller.rerunConfiguration() }
    }

    /// The ARKit world frame changed (session reset / relocalization jump): what the device saw belongs to the old one.
    func worldReset() {
        model.log.event("device_surface_reset", ["cells": .int(snapshot.cells), "hidden": .int(snapshot.hidden),
                                                 "voxels": .int(snapshot.voxels)])
        let now = CACurrentMediaTime()
        q.async { [weak self] in
            guard let self else { return }
            let ds = self.engine.reset(now: now)
            DispatchQueue.main.async { for d in ds { self.deliver(d.id, d.hidden, d.hiddenCount) } }
        }
        snapshot = (0, snapshot.sets, snapshot.faces, 0, false, 0)
        firstHideLogged = false
    }

    /// Rule off: every stored face back; what the device saw is forgotten.
    private func restoreAll() {
        let ids = Array(appliers.keys)
        for id in ids { appliers[id]?([], 0) }
        q.async { [weak self] in _ = self?.engine.reset() }
        snapshot = (0, snapshot.sets, snapshot.faces, 0, false, 0)
        firstHideLogged = false
    }

    /// Rule on: confirm meshes go to their current mask (hidden until confirmed).
    private func activateAll() {
        let now = CACurrentMediaTime()
        q.async { [weak self] in
            guard let self else { return }
            let ds = self.engine.activate(now: now)
            DispatchQueue.main.async { for d in ds { self.deliver(d.id, d.hidden, d.hiddenCount) } }
        }
    }

    private func maybeLog() {
        let t = CACurrentMediaTime()
        guard t - lastLog >= 10 else { return }
        lastLog = t
        let ms = stats.observeMs.sorted()
        let p50 = ms.isEmpty ? -1 : ms[ms.count / 2], mx = ms.last ?? -1
        model.log.event("device_surface", [
            "cells": .int(snapshot.cells), "sets": .int(snapshot.sets), "faces": .int(snapshot.faces),
            "hidden": .int(snapshot.hidden), "shown": .int(snapshot.faces - snapshot.hidden),
            "voxels": .int(snapshot.voxels), "policy": .string(Self.basePolicy.rawValue),
            "frames": .int(stats.frames), "marked": .int(stats.marked), "hits": .int(stats.hits),
            "passes": .int(stats.passes),
            "observe_ms_p50": .double((p50 * 10).rounded() / 10), "observe_ms_max": .double((mx * 10).rounded() / 10),
            "rebuilds": .int(stats.rebuilds), "rebuild_ms": .double((stats.rebuildMs * 10).rounded() / 10),
            "saturated": .bool(snapshot.saturated), "pruned": .int(prunedTotal),
            "grid_mb": .double((Double(bytes.grid) / 1_048_576 * 10).rounded() / 10),
        ])
        stats = (0, [], 0, 0, 0, 0, 0)
    }

    // MARK: pixel buffers

    private static func floats(_ pb: CVPixelBuffer, w: Int, h: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let row = CVPixelBufferGetBytesPerRow(pb)
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let src = base.advanced(by: y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<w { dst[y * w + x] = src[x] }
            }
        }
        return out
    }

    private static func bytes(_ pb: CVPixelBuffer, w: Int, h: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb) == w,
              CVPixelBufferGetHeight(pb) == h else { return [] }
        let row = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let src = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { dst[y * w + x] = src[x] }
            }
        }
        return out
    }
}
