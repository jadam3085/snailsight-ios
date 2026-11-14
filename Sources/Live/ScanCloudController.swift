// SnailSight 12.27 Scan view: the live coloured point cloud on the device (owner 2026-11-14, "why do scanning apps show a
// coloured point cloud instantly?"). ARKit sceneDepth + confidence + the camera image -> SnailSightCore ScanCloud on a
// utility queue (≤ 6 Hz, ~12 k samples a frame, voxel dedupe by range, quality from confidence / range / incidence),
// drawn by ScanCloudRenderer (AR post-process, 60 fps; ScanOrbitView when paused).
//  - Scan view is a toggle in a normal walk (walk bar, Mapping ▸ Scan view, remembered) and the default during a Rescan.
//  - Memory governor: MemPlan.cloudMaxPoints / cloudKeepRadiusM (enforced each second: far chunks evicted, then the
//    farthest decimated to 6 cm, then dropped); `mb_scan_cloud` in the `mem` log (CPU estimate + the GPU copies).
//  - Logs: scan_cloud (on / off + cause), scan_cloud_stats (30 s), scan_cloud_orbit, scan_cloud_render (a renderer
//    failure, once).
import ARKit
import Foundation
import RealityKit
import SnailSightCore

final class ScanCloudController: ObservableObject {
    private unowned let model: AppModel
    let renderer = ScanCloudRenderer()
    private let q = DispatchQueue(label: "snailsight.scancloud", qos: .utility)

    /// Owner toggle (remembered): Scan view in a normal walk.
    @Published var on: Bool = UserDefaults.standard.bool(forKey: "view.scanCloud") {
        didSet {
            guard on != oldValue else { return }
            UserDefaults.standard.set(on, forKey: "view.scanCloud")
            changed(cause: "toggle")
        }
    }
    /// A Rescan forces it on (its default look).
    @Published private(set) var forced = false
    /// Faint (low-confidence / far / oblique) points drawn faint; off = hidden.
    @Published var showFaint: Bool = UserDefaults.standard.object(forKey: "view.scanCloudFaint") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFaint, forKey: "view.scanCloudFaint"); refreshUpload() }
    }
    /// The orbitable 3D view (integration paused, Live map paused).
    @Published var orbitOpen = false {
        didSet {
            guard orbitOpen != oldValue else { return }
            renderer.drawInAR = active && !orbitOpen
            model.log.event("scan_cloud_orbit", ["open": .bool(orbitOpen), "points": .int(points)])
        }
    }
    // HUD (main, ~2 Hz)
    @Published private(set) var points = 0
    @Published private(set) var coverage = ScanCoverage.Summary()
    @Published private(set) var topDown: [UInt8] = []
    @Published private(set) var heading: Float = 0               // camera yaw for the mini map arrow

    // queue state
    private var cloud = ScanCloud()
    private var busy = false
    private var lastIntegrate = 0.0
    private var lastEnforce = 0.0
    private var lastUpload = 0.0
    private var lastPublish = 0.0
    private var lastStats = 0.0
    private var dirty = false
    private var stats = (frames: 0, samples: 0, added: 0, good: 0, faint: 0, ms: 0.0)
    private var cam = SIMD3<Float>(0, 0, 0)
    private var cpuBytes = 0
    private var evicted = 0, decimated = 0
    private var renderLogged = false
    private var attached = false

    static let maxHz = 6.0

    init(model: AppModel) { self.model = model }

    /// Drawn / integrating now.
    var active: Bool { (on || forced) && model.appMode == .ar && model.arActive }
    /// The session needs LiDAR depth for it.
    var wantsDepth: Bool { (on || forced) && model.appMode == .ar }
    /// CPU estimate + GPU copies (the `mb_scan_cloud` line).
    var estimatedBytes: Int { cpuBytes + renderer.gpuBytes }
    var evictedChunks: Int { evicted }
    var decimatedChunks: Int { decimated }

    /// Hook the AR view's post-process pass (once).
    func attach(_ arView: ARView) {
        guard !attached else { return }
        attached = true
        let r = renderer
        arView.renderCallbacks.postProcess = { ctx in r.postProcess(ctx) }
    }

    func setForced(_ f: Bool, cause: String) {
        guard f != forced else { return }
        forced = f
        changed(cause: cause)
    }

    private func changed(cause: String) {
        renderer.drawInAR = active && !orbitOpen
        model.log.event("scan_cloud", ["on": .bool(on || forced), "toggle": .bool(on), "forced": .bool(forced),
                                       "cause": .string(cause), "points": .int(points)])
        if !model.arSuspended { model.controller.rerunConfiguration() }     // .sceneDepth on / off
        if !(on || forced) { orbitOpen = false }
    }

    /// Clear the cloud (a new Rescan, or the ARKit world frame changed: old points are in the old frame).
    func reset(why: String) {
        q.async {
            let n = self.cloud.count
            self.cloud.clear()
            self.renderer.clear()
            self.dirty = false
            DispatchQueue.main.async {
                self.points = 0
                self.coverage = ScanCoverage.Summary()
                self.topDown = []
                if n > 0 { self.model.log.event("scan_cloud_reset", ["why": .string(why), "points": .int(n)]) }
            }
        }
    }

    func worldFrameChanged(_ reason: String) { reset(why: "world_frame:" + reason) }

    /// Leaving AR (snailCOP mode): the drawing stops; the points stay for when AR comes back (same session).
    func leftAR() {
        renderer.drawInAR = false
        orbitOpen = false
    }

    func enteredAR() { renderer.drawInAR = active && !orbitOpen }

    /// The coverage summary right now (Finish of a Rescan).
    func snapshot() -> (coverage: ScanCoverage.Summary, points: Int) {
        q.sync { (cloud.coverage.summary, cloud.count) }
    }

    // MARK: frames (main)

    func frame(_ f: ARFrame) {
        guard active else { return }
        renderer.setARView(model.controller.arView.cameraTransform.matrix)
        guard !orbitOpen, !busy else { return }
        let t = f.timestamp
        guard t - lastIntegrate >= 1 / Self.maxHz else { return }
        guard case .normal = f.camera.trackingState, let depth = f.sceneDepth else { return }
        lastIntegrate = t
        busy = true
        let input = Self.input(f, depth: depth)
        let M = f.camera.transform
        let c = SIMD3<Float>(M.columns.3.x, M.columns.3.y, M.columns.3.z)
        let fw = -SIMD3<Float>(M.columns.2.x, M.columns.2.y, M.columns.2.z)
        let plan = model.memPlan
        let faint: UInt8 = showFaint ? 90 : 0
        q.async { [weak self] in
            guard let self else { return }
            let t0 = CACurrentMediaTime()
            var st = CloudIntegrateStats()
            if let input { st = self.cloud.integrate(input) }
            self.cam = c
            let now = CACurrentMediaTime()
            if now - self.lastEnforce >= 1 {
                self.lastEnforce = now
                let r = self.cloud.enforce(camX: c.x, camY: c.y, camZ: c.z, maxPoints: plan.cloudMaxPoints,
                                           keepRadiusM: Float(plan.cloudKeepRadiusM))
                self.evicted += r.evictedChunks
                self.decimated += r.decimatedChunks
                if r.evictedPoints > 0 || r.decimatedChunks > 0 { self.dirty = true }
            }
            if st.added > 0 || st.merged > 0 { self.dirty = true }
            if self.dirty, now - self.lastUpload >= 0.2 {
                self.lastUpload = now
                self.dirty = false
                self.renderer.upload(self.cloud, maxPoints: max(1, plan.cloudMaxPoints), faintAlpha: faint)
            }
            self.cpuBytes = self.cloud.estimatedBytes
            let ms = (CACurrentMediaTime() - t0) * 1000
            self.stats.frames += 1; self.stats.samples += st.samples; self.stats.added += st.added
            self.stats.good += st.good; self.stats.faint += st.faint; self.stats.ms += ms
            var pub: (Int, ScanCoverage.Summary, [UInt8])?
            if now - self.lastPublish >= 0.5 {
                self.lastPublish = now
                pub = (self.cloud.count, self.cloud.coverage.summary, self.cloud.coverage.topDown(camX: c.x, camZ: c.z))
            }
            var statsEv: [String: LogValue]?
            if now - self.lastStats >= 30 {
                self.lastStats = now
                statsEv = self.statsEvent(plan)
            }
            DispatchQueue.main.async {
                self.busy = false
                if let p = pub {
                    self.points = p.0
                    if self.coverage != p.1 { self.coverage = p.1 }
                    self.topDown = p.2
                    self.heading = atan2(fw.x, -fw.z)
                }
                if let e = statsEv { self.model.log.event("scan_cloud_stats", e) }
                if let fail = self.renderer.renderFailed, !self.renderLogged {
                    self.renderLogged = true
                    self.model.log.event("scan_cloud_render", ["error": .string(fail)])
                }
            }
        }
    }

    /// The 30 s `scan_cloud_stats` (cloud queue); resets the window counters. Plain statements (the Xcode type checker
    /// times out on long mixed-type dictionary literals).
    private func statsEvent(_ plan: MemPlan) -> [String: LogValue] {
        let s = stats
        let n = s.good + s.faint
        let share: Double = n > 0 ? Double(s.good) / Double(n) : 0
        let ms: Double = s.frames > 0 ? s.ms / Double(s.frames) : 0
        let mb = Double(cloud.estimatedBytes + renderer.gpuBytes) / 1_048_576
        var e: [String: LogValue] = [:]
        e["points"] = .int(cloud.count)
        e["good"] = .int(cloud.goodCount)
        e["chunks"] = .int(cloud.chunkCount)
        e["frames"] = .int(s.frames)
        e["samples"] = .int(s.samples)
        e["added"] = .int(s.added)
        e["good_share"] = .double((share * 1000).rounded() / 1000)
        e["ms_avg"] = .double((ms * 10).rounded() / 10)
        e["evicted_chunks"] = .int(evicted)
        e["decimated_chunks"] = .int(decimated)
        e["max_points"] = .int(plan.cloudMaxPoints)
        e["keep_m"] = .double(plan.cloudKeepRadiusM)
        e["mb"] = .double((mb * 10).rounded() / 10)
        e["coverage_pct"] = .int(cloud.coverage.summary.coveragePct)
        stats = (0, 0, 0, 0, 0, 0)
        return e
    }

    /// Copies what the accumulator needs out of the frame (main, ~1 ms): depth (Float32), confidence, RGB sampled from
    /// the camera's YCbCr image at the depth resolution, K scaled to the depth map, T camera → world (row-major).
    private static func input(_ f: ARFrame, depth: ARDepthData) -> CloudFrameInput? {
        let dm = depth.depthMap
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)
        guard w > 8, h > 8, CVPixelBufferGetPixelFormatType(dm) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(dm) else { return nil }
        let rb = CVPixelBufferGetBytesPerRow(dm)
        var d = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rb).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { d[y * w + x] = row[x] }
        }
        var conf: [UInt8]?
        if let cm = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            if let cb = CVPixelBufferGetBaseAddress(cm), CVPixelBufferGetWidth(cm) == w, CVPixelBufferGetHeight(cm) == h {
                let crb = CVPixelBufferGetBytesPerRow(cm)
                var c = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h {
                    let row = cb.advanced(by: y * crb).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { c[y * w + x] = row[x] }
                }
                conf = c
            }
            CVPixelBufferUnlockBaseAddress(cm, .readOnly)
        }
        let rgb = sampleRGB(f.capturedImage, w: w, h: h)
        let K = f.camera.intrinsics
        let imgW = Float(f.camera.imageResolution.width)
        let s = Float(w) / max(1, imgW)
        let M = f.camera.transform
        var T = [Float](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { T[r * 4 + c] = M[c][r] } }
        return CloudFrameInput(depth: d, conf: conf, width: w, height: h, K: [K[0][0] * s, K[1][1] * s, K[2][0] * s, K[2][1] * s],
                               T: T, rgb: rgb, colorW: rgb == nil ? 0 : w, colorH: rgb == nil ? 0 : h)
    }

    /// The camera image (420f / 420v bi-planar YCbCr) sampled at w x h (BT.601 full range).
    private static func sampleRGB(_ pb: CVPixelBuffer, w: Int, h: Int) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        guard yw > 0, yh > 0, cw > 0, ch > 0 else { return nil }
        let video = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let Y = yb.assumingMemoryBound(to: UInt8.self), C = cb.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for v in 0..<h {
            let py = min(yh - 1, (v * yh + yh / (2 * h)) / h), pc = min(ch - 1, py * ch / yh)
            for u in 0..<w {
                let px = min(yw - 1, (u * yw + yw / (2 * w)) / w), qx = min(cw - 1, px * cw / yw)
                var yy = Float(Y[py * yr + px])
                if video { yy = (yy - 16) * 1.164 }
                let cbv = Float(C[pc * cr + qx * 2]) - 128, crv = Float(C[pc * cr + qx * 2 + 1]) - 128
                let r = yy + 1.402 * crv, g = yy - 0.344136 * cbv - 0.714136 * crv, b = yy + 1.772 * cbv
                let o = (v * w + u) * 3
                out[o] = UInt8(max(0, min(255, r)))
                out[o + 1] = UInt8(max(0, min(255, g)))
                out[o + 2] = UInt8(max(0, min(255, b)))
            }
        }
        return out
    }

    // MARK: orbit view

    /// Centre + radius for the orbit camera (cloud queue).
    func bounds() -> (center: SIMD3<Float>, radius: Float)? {
        q.sync {
            guard let b = cloud.bounds else { return nil }
            return (SIMD3(b.center[0], b.center[1], b.center[2]), b.radius)
        }
    }

    var cameraPosition: SIMD3<Float> { q.sync { cam } }

    /// Re-upload now (the faint toggle in the orbit view).
    func refreshUpload() {
        let plan = model.memPlan, faint: UInt8 = showFaint ? 90 : 0
        q.async { self.renderer.upload(self.cloud, maxPoints: max(1, plan.cloudMaxPoints), faintAlpha: faint) }
    }
}
