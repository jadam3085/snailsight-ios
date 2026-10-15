// P1 capture recorder: StrayScanner layout (docs/SNAILSIGHT-API.md §4.4, schema snailsight.capture/1) in
// Documents/captures/<client_session_id>/. ~10 Hz while tracking is normal: rgb/NNNNNN.jpg (1024×768), depth/NNNNNN.png
// (16-bit mm, 256×192), confidence/NNNNNN.png (8-bit 0/1/2), odometry.csv (raw ARKit camera→world), camera_matrix.csv
// (full-size intrinsics), imu.csv (CoreMotion ~100 Hz), capture.json at stop.
// Threading: `process(frame:)` runs on the main thread (ARSession delegate) and only COPIES depth/confidence bytes and
// keeps the CVPixelBuffer of the colour image; all encoding/writing happens on one serial queue, so stop() drains it in
// order. At most 3 frames are in flight; extra frames are dropped (counted), never queued, so ARKit's buffer pool is safe.
// 9.1.60: every drop is logged with its cause (encoder backpressure + encode time + thermal, ev "rec_drop", ≤ 1/s) and
// record_stop / capture.json carry encode timings and bytes per stream, so size and drops are diagnosable from logs.
// JPEG via CIContext.jpegRepresentation (GPU path) at quality 0.65 (was ImageIO at 0.75): ~25 % smaller RGB, still far
// above what feature matching needs (StrayScanner itself stores H.264). Depth/confidence stay lossless 16/8-bit PNG.
// 9.1.61 (2026-10-12 kill: footprint ~3 GB after 8 min, iOS killed the app, the capture was never uploaded):
//  - memory: the encode queue drains its autorelease pool per work item (`.workItem` + explicit autoreleasepool; a
//    continuously busy GCD serial queue otherwise keeps CIImage/CGImage/NSData temporaries until the thread idles),
//    capture.json `events` capped, IMU flushed every ~4 KB (≈ 0.4 s), no ARFrame is ever retained (only the colour
//    CVPixelBuffer of ≤ 3 in-flight frames).
//  - adaptive: rate + JPEG quality come from AdaptiveCapture (thermal + available memory) via `apply(_:)`; a keyframe
//    gate skips frames when the phone has not moved/turned (≥ 2 cm or ≥ 2°, keep-alive 1 s).
//  - crash-safety: capture.partial.json (CaptureCheckpoint) at start and at every ~10 s segment boundary, deleted at
//    Stop; a killed capture is repaired + uploaded on the next launch (UploadQueue → CaptureRecovery). Stop carries a
//    `stop_reason` (user | thermal_critical | memory_low | background).
//  - texture keyframes (owner: scan mesh looks low-res): the full 1920×1440 camera image of a saved frame as
//    keyframes/NNNNNN.jpg (q0.75) + a keyframes.csv row (frame, timestamp, size, full-res intrinsics) every ~0.4 m or 15°
//    (≥ 1.5 s apart; AdaptiveCapture.isKeyframe). Same frame index as rgb/depth/odometry, so the pose is that odometry
//    row. Uses the frame's own capturedImage (no captureHighResolutionFrame: that is a separate still capture that
//    stalls the video stream and costs more heat for 4032×3024 we do not need for 256×192-depth meshes).
// 9.4 blur-aware keyframes (owner: splat photos show motion blur): every ARFrame updates the camera's angular + linear
//  speed; × ARCamera.exposureDuration × focal length = predicted blur in pixels (KeyframeQuality.predictedBlurPx),
//  which drives the on-screen "slow down" hint (MotionHint). When the spacing rule says a keyframe is due, a window of
//  ≤ 0.6 s opens (KeyframeWindow; extended up to 2× while everything was predicted blurry); every saved frame in it is
//  scored on the encode queue (variance of the Laplacian of the 4× box-downscaled Y plane, ~3 ms) and only the SHARPEST
//  is written as the keyframe (KeyframePicker; ≤ 1 extra camera buffer held). keyframes.csv gains sharpness, blur_px,
//  exposure_s, iso (EXIF of that frame) and candidates. capture.json `camera` = CameraTuner settings + exposure / ISO
//  statistics over the saved frames.
import ARKit
import CoreImage
import CoreMotion
import ImageIO
import UniformTypeIdentifiers
import SnailSightCore

struct RecordStats {
    var frames = 0
    var dropped = 0
    var bytes = 0
    var elapsed: Double = 0
    var keyframes = 0
    var slowDown = false                       // 9.4: predicted motion blur high → HUD "Slow down"
}

enum RecorderError: LocalizedError {
    case cannotStart
    var errorDescription: String? { "recording could not start (already recording or no Documents folder)" }
}

struct CaptureSummary {
    var clientSessionID: String
    var directory: URL
    var frames: Int
    var bytes: Int
    var dropped: Int
    var stats: [String: LogValue] = [:]       // encode timings, bytes per stream, drop causes (→ record_stop log)
}

final class CaptureRecorder {
    static var capturesDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("captures")
    }

    var onStats: ((RecordStats) -> Void)?          // called on main
    var onEvent: ((String, [String: LogValue]) -> Void)?   // session log (called on main)
    private(set) var isRecording = false
    var rateHz = AdaptiveCapture.baseRateHz           // set by apply(_:) from the adaptive policy (main thread)
    var jpegQuality = AdaptiveCapture.baseQuality
    static let maxInFlight = 3
    static let maxEvents = 2000
    static let imuFlushBytes = 4096

    /// The capture folder being written right now (read by the upload queue's launch-time recovery from another thread).
    private static let activeLock = NSLock()
    private static var _active: String?
    static var activeCaptureID: String? {
        get { activeLock.lock(); defer { activeLock.unlock() }; return _active }
        set { activeLock.lock(); _active = newValue; activeLock.unlock() }
    }

    private let queue = DispatchQueue(label: "snailsight.recorder", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()

    // main-thread state
    private var inFlight = 0
    private var lastSaved: Double?
    private var nextIndex = 0
    private var dropped = 0
    private var firstStamp: Double?
    private var wroteIntrinsics = false
    private var meta: [String: Any] = [:]
    private var lastTracking = ""
    private var noDepth = 0
    private var lastDropLog: Double = 0
    private var lastEncMs: Double = 0
    private var droppedThermal = 0
    private var skippedStill = 0
    private var lastPos: [Double]?
    private var lastQuat: CaptureFormat.Quat?
    private var rateChanges: [[String: Any]] = []
    var keyframeScale = 1.0                            // from apply(_:)
    var keyframeProfileScale = 1.0                     // 9.3 object scan: ObjectProfile.keyframeScale (set before start)
    private var kfPos: [Double]?
    private var kfQuat: CaptureFormat.Quat?
    private var kfStamp: Double?
    private var keyframesQueued = 0
    // 9.4 motion / blur (main thread, every ARFrame)
    private var motionPrev: (t: Double, pos: [Double], quat: CaptureFormat.Quat)?
    private(set) var motionHint = MotionHint()
    private var kfWindow = KeyframeWindow(length: KeyframeWindow.maxLength)
    private var exposures: [Double] = []
    private var isos: [Double] = []
    private var slowDownFrames = 0
    private var blurAll: [Double] = []

    /// One keyframe candidate (a saved frame inside a keyframe window), held by the queue's picker.
    struct KFCandidate {
        var index: Int
        var pixel: CVPixelBuffer
        var t: Double
        var w: Int, h: Int
        var fx: Double, fy: Double, cx: Double, cy: Double
        var blurPx: Double, exposureS: Double, iso: Double
    }
    private var picker = KeyframePicker<KFCandidate?>()     // queue state
    private var kfBlur: [Double] = [], kfCands: [Int] = []   // queue state: chosen keyframes' blur / window sizes

    // queue state
    private var dir: URL?
    private var odometry: FileHandle?
    private var imu: FileHandle?
    private var imuBuffer = ""
    private var bytes = 0
    private var saved = 0
    private var events: [[String: Any]] = []
    private var depthSize = [256, 192]
    private var fullSize = [1920, 1440]
    private var rgbBytes = 0, depthBytes = 0, confBytes = 0
    private var encSum: Double = 0, encMax: Double = 0
    private var jpegQualityLast = AdaptiveCapture.baseQuality
    private var checkpoint: CaptureCheckpoint?
    private var segments = SegmentTracker(seconds: 10)
    private var lastFrameWritten = -1
    private var keyframesFile: FileHandle?
    private var kfBytes = 0, kfSaved = 0

    init() { motionQueue.maxConcurrentOperationCount = 1 }

    // MARK: start / stop (main thread)

    func start(clientSessionID: String, meta: [String: Any]) throws -> URL {
        guard !isRecording, let root = Self.capturesDirectory else { throw RecorderError.cannotStart }
        let d = root.appendingPathComponent(clientSessionID)
        let fm = FileManager.default
        for sub in ["rgb", "depth", "confidence"] {
            try fm.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: d.appendingPathComponent("odometry.csv").path, contents: Data(CaptureFormat.odometryHeader.utf8))
        fm.createFile(atPath: d.appendingPathComponent("imu.csv").path, contents: Data(CaptureFormat.imuHeader.utf8))
        let odo = try FileHandle(forWritingTo: d.appendingPathComponent("odometry.csv"))
        let im = try FileHandle(forWritingTo: d.appendingPathComponent("imu.csv"))
        try fm.createDirectory(at: d.appendingPathComponent("keyframes"), withIntermediateDirectories: true)
        fm.createFile(atPath: d.appendingPathComponent("keyframes.csv").path, contents: Data(CaptureFormat.keyframesHeader.utf8))
        let kfh = try FileHandle(forWritingTo: d.appendingPathComponent("keyframes.csv"))
        odo.seekToEndOfFile(); im.seekToEndOfFile(); kfh.seekToEndOfFile()
        inFlight = 0; lastSaved = nil; nextIndex = 0; dropped = 0; firstStamp = nil; wroteIntrinsics = false
        lastTracking = ""
        noDepth = 0; lastDropLog = 0; lastEncMs = 0; droppedThermal = 0
        skippedStill = 0; lastPos = nil; lastQuat = nil; rateChanges = []
        keyframeScale = 1; kfPos = nil; kfQuat = nil; kfStamp = nil; keyframesQueued = 0
        motionPrev = nil; motionHint = MotionHint(); kfWindow = KeyframeWindow(length: KeyframeWindow.maxLength)
        exposures = []; isos = []; slowDownFrames = 0; blurAll = []
        rateHz = AdaptiveCapture.baseRateHz; jpegQuality = AdaptiveCapture.baseQuality
        var m = meta
        m["client_session_id"] = clientSessionID
        let started = Date().timeIntervalSince1970
        m["started"] = started
        self.meta = m
        var cp = CaptureCheckpoint(clientSessionID: clientSessionID, started: started,
                                   meta: meta.compactMapValues { $0 as? String })
        cp.rateHz = rateHz
        queue.sync {
            dir = d; odometry = odo; imu = im; imuBuffer = ""; bytes = 0; saved = 0; events = []
            rgbBytes = 0; depthBytes = 0; confBytes = 0; encSum = 0; encMax = 0
            segments = SegmentTracker(seconds: 10); lastFrameWritten = -1; jpegQualityLast = AdaptiveCapture.baseQuality
            checkpoint = cp
            keyframesFile = kfh; kfBytes = 0; kfSaved = 0
            picker = KeyframePicker<KFCandidate?>(); kfBlur = []; kfCands = []
            writeCheckpoint()
        }
        Self.activeCaptureID = clientSessionID
        isRecording = true
        CameraTuner.shared.recordingStarted(objectScan: meta["profile"] as? String == "object")
        startIMU()
        return d
    }

    /// Adaptive policy decision (main thread, every HUD tick while recording). Rate changes go into capture.json.
    func apply(_ d: CaptureDecision) {
        guard isRecording else { return }
        keyframeScale = d.keyframeScale
        if d.rateHz > 0, d.rateHz != rateHz || d.jpegQuality != jpegQuality {
            rateHz = d.rateHz
            jpegQuality = d.jpegQuality
            if rateChanges.count < 200 {
                rateChanges.append(["t": Date().timeIntervalSince1970, "rate_hz": d.rateHz, "jpeg_q": d.jpegQuality,
                                    "level": d.level])
            }
            let r = rateHz
            queue.async { [self] in checkpoint?.rateHz = r }
        }
    }

    func stop(reason: String = "user", completion: @escaping (CaptureSummary?) -> Void) {
        guard isRecording else { completion(nil); return }
        isRecording = false
        motion.stopDeviceMotionUpdates()
        var m = meta
        m["ended"] = Date().timeIntervalSince1970
        m["rate_hz"] = rateHz
        m["stop_reason"] = reason
        m["rate_changes"] = rateChanges
        m["skipped_still"] = skippedStill
        var camera = CameraTuner.shared.recordingStopped()
        let q = { (a: [Double], p: Double) -> Double in
            guard !a.isEmpty else { return 0 }
            let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        camera["frame_exposure_s"] = ["min": q(exposures, 0), "median": q(exposures, 0.5), "max": q(exposures, 1)]
        camera["frame_iso"] = ["min": q(isos, 0), "median": q(isos, 0.5), "max": q(isos, 1)]
        camera["blur_px"] = ["median": q(blurAll, 0.5), "p90": q(blurAll, 0.9)]
        camera["slow_down_frames"] = slowDownFrames
        m["camera"] = camera
        let camStats: [String: LogValue] = [
            "cam_mode": .string(CameraTuner.mode.rawValue),
            "exp_ms_med": .double((q(exposures, 0.5) * 1000 * 100).rounded() / 100),
            "exp_ms_max": .double((q(exposures, 1) * 1000 * 100).rounded() / 100),
            "iso_med": .double(q(isos, 0.5).rounded()), "iso_max": .double(q(isos, 1).rounded()),
            "blur_px_med": .double((q(blurAll, 0.5) * 10).rounded() / 10), "slow_down_frames": .int(slowDownFrames)]
        kfWindow.close()
        let droppedNow = dropped
        let noDepthNow = noDepth, droppedThermalNow = droppedThermal, stillNow = skippedStill
        let csid = m["client_session_id"] as? String ?? "cap"
        motionQueue.waitUntilAllOperationsAreFinished()
        queue.async { [self] in
            if let pick = picker.flush(), let c = pick.payload { writeKeyframe(c, score: pick.score, candidates: pick.candidates) }
            flushIMU()
            try? odometry?.close(); try? imu?.close(); try? keyframesFile?.close()
            odometry = nil; imu = nil; keyframesFile = nil
            m["keyframes"] = kfSaved
            m["keyframe_rule"] = ["metres": AdaptiveCapture.keyframeMetres, "degrees": AdaptiveCapture.keyframeDegrees,
                                  "min_interval_s": AdaptiveCapture.keyframeMinInterval,
                                  "jpeg_q": AdaptiveCapture.keyframeQuality, "size": fullSize,
                                  "profile_scale": keyframeProfileScale, "selection": "sharpest_in_window",
                                  "window_s": KeyframeWindow.length(scale: keyframeProfileScale),
                                  "blur_ok_px": KeyframeWindow.blurOK,
                                  "chosen_blur_px_median": kfBlur.isEmpty ? 0 : kfBlur.sorted()[kfBlur.count / 2],
                                  "candidates_avg": kfCands.isEmpty ? 0 : Double(kfCands.reduce(0, +)) / Double(kfCands.count)]
            m["frames"] = saved
            m["dropped"] = droppedNow
            m["schema"] = CaptureFormat.schema
            m["rgb_size"] = [CaptureFormat.rgbSize.width, CaptureFormat.rgbSize.height]
            m["depth_size"] = depthSize
            m["full_size"] = fullSize
            m["world_alignment"] = "gravity"
            m["events"] = events
            let encAvg = saved > 0 ? encSum / Double(saved) : 0
            let mb = { (b: Int) in (Double(b) / 1_048_576 * 10).rounded() / 10 }
            m["jpeg_quality"] = jpegQualityLast
            segments.finish()
            m["segments"] = segments.closed.map { ["index": $0.index, "first_frame": $0.firstFrame, "last_frame": $0.lastFrame] }
            m["encode_ms"] = ["avg": (encAvg * 10).rounded() / 10, "max": (encMax * 10).rounded() / 10]
            m["bytes_by_stream"] = ["rgb": rgbBytes, "depth": depthBytes, "confidence": confBytes, "keyframes": kfBytes]
            let durMin = max(1.0 / 60, ((m["ended"] as? Double ?? 0) - (m["started"] as? Double ?? 0)) / 60)
            m["mb_per_min"] = (Double(bytes) / 1_048_576 / durMin * 10).rounded() / 10
            m["dropped_reasons"] = ["encoder_backpressure": droppedNow, "while_thermal_serious": droppedThermalNow]
            m["skipped_no_depth"] = noDepthNow
            var stats: [String: LogValue] = [
                "enc_ms_avg": .double((encAvg * 10).rounded() / 10), "enc_ms_max": .double((encMax * 10).rounded() / 10),
                "rgb_mb": .double(mb(rgbBytes)), "depth_mb": .double(mb(depthBytes)), "conf_mb": .double(mb(confBytes)),
                "kb_per_frame": .double(saved > 0 ? Double(bytes) / Double(saved) / 1024 : 0),
                "drop_cause": .string(droppedNow == 0 ? "none" : "encoder_backpressure"),
                "dropped_thermal": .int(droppedThermalNow), "skipped_no_depth": .int(noDepthNow),
                "skipped_still": .int(stillNow), "jpeg_q": .double(jpegQualityLast), "reason": .string(reason),
                "segments": .int(segments.closed.count), "keyframes": .int(kfSaved), "kf_mb": .double(mb(kfBytes)),
                "mb_per_min": .double(m["mb_per_min"] as? Double ?? 0)]
            for (k, v) in camStats { stats[k] = v }
            if !kfCands.isEmpty { stats["kf_candidates_avg"] = .double((Double(kfCands.reduce(0, +)) / Double(kfCands.count) * 10).rounded() / 10) }
            var summary: CaptureSummary?
            if let d = dir {
                if let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: d.appendingPathComponent("capture.json"), options: .atomic)
                    bytes += data.count
                }
                try? FileManager.default.removeItem(at: d.appendingPathComponent(CaptureCheckpoint.fileName))
                summary = CaptureSummary(clientSessionID: csid, directory: d, frames: saved, bytes: bytes, dropped: droppedNow,
                                         stats: stats)
            }
            dir = nil
            checkpoint = nil
            DispatchQueue.main.async {
                if Self.activeCaptureID == csid { Self.activeCaptureID = nil }
                completion(summary)
            }
        }
    }

    /// Tracking changes while recording go into capture.json `events` (main thread).
    func trackingChanged(_ code: String) {
        guard isRecording, code != lastTracking else { return }
        lastTracking = code
        let e: [String: Any] = ["t": Date().timeIntervalSince1970, "ev": "tracking", "state": code]
        queue.async { [self] in if events.count < Self.maxEvents { events.append(e) } }
    }

    // MARK: frames (main thread)

    /// Called from the ARSession delegate (main thread). Reads what it needs from the frame and returns: the ARFrame
    /// itself is never stored (holding ARFrames starves ARKit's buffer pool).
    func process(frame: ARFrame, thermalSerious: Bool) {
        guard isRecording else { return }
        guard case .normal = frame.camera.trackingState else { return }
        let t = frame.timestamp
        let m = frame.camera.transform
        let rows: [[Double]] = (0..<3).map { r in (0..<3).map { c in Double(m[c][r]) } }
        let pos = [Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z)]
        let quat = CaptureFormat.quaternion(rows: rows)
        // 9.4: camera speed every frame → predicted blur → "slow down" hint + keyframe window
        let exposureS = frame.camera.exposureDuration
        let focal = Double(frame.camera.intrinsics[0][0])
        var blur = 0.0
        if let p = motionPrev, t > p.t {
            let dt = t - p.t
            let dx = pos[0] - p.pos[0], dy = pos[1] - p.pos[1], dz = pos[2] - p.pos[2]
            blur = KeyframeQuality.predictedBlurPx(
                angularSpeedRadS: AdaptiveCapture.rotationDegrees(p.quat, quat) * .pi / 180 / dt,
                linearSpeedMS: (dx * dx + dy * dy + dz * dz).squareRoot() / dt,
                depthM: keyframeProfileScale < 1 ? 0.5 : 1.5, exposureS: exposureS, focalPx: focal)
        }
        motionPrev = (t, pos, quat)
        let wasSlow = motionHint.active
        if motionHint.update(blurPx: blur, at: t) != wasSlow {
            onEvent?("motion_hint", ["slow": .bool(motionHint.active), "blur_px": .double((motionHint.smoothed * 10).rounded() / 10),
                                     "exposure_ms": .double((exposureS * 1000 * 100).rounded() / 100)])
        }
        guard CaptureFormat.shouldSave(now: t, last: lastSaved, rateHz: rateHz) else { return }
        if let lp = lastPos, let lq = lastQuat, let ls = lastSaved {
            let dx = pos[0] - lp[0], dy = pos[1] - lp[1], dz = pos[2] - lp[2]
            if !AdaptiveCapture.moved(translationM: (dx * dx + dy * dy + dz * dz).squareRoot(),
                                      rotationDeg: AdaptiveCapture.rotationDegrees(lq, quat), sinceLastS: t - ls) {
                skippedStill += 1
                return
            }
        }
        guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { noDepth += 1; return }
        lastSaved = t
        guard inFlight < Self.maxInFlight else {
            dropped += 1
            if thermalSerious { droppedThermal += 1 }
            if t - lastDropLog >= 1 {
                lastDropLog = t
                onEvent?("rec_drop", ["dropped": .int(dropped), "in_flight": .int(inFlight),
                                      "cause": .string("encoder_backpressure"), "last_enc_ms": .double(lastEncMs),
                                      "thermal_serious": .bool(thermalSerious), "frame": .int(nextIndex)])
            }
            return
        }
        if firstStamp == nil { firstStamp = t }
        lastPos = pos; lastQuat = quat
        let kfDist = kfPos.map { p in ((pos[0] - p[0]) * (pos[0] - p[0]) + (pos[1] - p[1]) * (pos[1] - p[1])
                                       + (pos[2] - p[2]) * (pos[2] - p[2])).squareRoot() }
        if !kfWindow.isOpen,
           AdaptiveCapture.isKeyframe(translationM: kfDist, rotationDeg: kfQuat.map { AdaptiveCapture.rotationDegrees($0, quat) },
                                      sinceLastS: kfStamp.map { t - $0 }, scale: keyframeScale * keyframeProfileScale) {
            kfPos = pos; kfQuat = quat; kfStamp = t; keyframesQueued += 1
            kfWindow.length = KeyframeWindow.length(scale: keyframeScale * keyframeProfileScale)
            kfWindow.open(at: t)
        }
        let win = kfWindow.candidate(at: t, blurPx: blur)
        let iso = Self.exifISO(frame)
        if exposures.count < 20000 { exposures.append(exposureS); isos.append(iso); blurAll.append(blur) }
        if motionHint.active { slowDownFrames += 1 }
        var kfInfo: (w: Int, h: Int, fx: Double, fy: Double, cx: Double, cy: Double)?
        if win != nil {
            let k = frame.camera.intrinsics
            kfInfo = (Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height),
                      Double(k[0][0]), Double(k[1][1]), Double(k[2][0]), Double(k[2][1]))
        }

        let index = nextIndex
        nextIndex += 1
        let (mm, dw, dh) = Self.copyDepth(depth.depthMap)
        let conf = depth.confidenceMap.map { Self.copyBytes($0) }
        let pixel = frame.capturedImage                    // retained only until the JPEG is written (≤ 3 in flight)
        let quality = jpegQuality
        let odoLine = CaptureFormat.odometryLine(timestamp: t, frame: index, position: pos, rotationRows: rows)
        var intrinsics: String?
        var full: [Int]?
        if !wroteIntrinsics {
            wroteIntrinsics = true
            let k = frame.camera.intrinsics
            intrinsics = CaptureFormat.cameraMatrix(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]))
            full = [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)]
        }
        let elapsed = t - (firstStamp ?? t)
        let droppedNow = dropped
        inFlight += 1
        queue.async { [self] in autoreleasepool {
            let t0 = CFAbsoluteTimeGetCurrent()
            var encMs: Double = 0
            defer { DispatchQueue.main.async { self.inFlight -= 1; self.lastEncMs = encMs } }
            guard let d = dir else { return }
            let stem = CaptureNaming.frameStem(index)
            var n = 0
            if let intrinsics {
                let data = Data(intrinsics.utf8)
                try? data.write(to: d.appendingPathComponent("camera_matrix.csv"))
                if let full { fullSize = full }
                depthSize = [dw, dh]
                checkpoint?.fullSize = fullSize
                checkpoint?.depthSize = depthSize
            }
            if let jpg = jpeg(pixel, quality: quality) {
                jpegQualityLast = quality
                try? jpg.write(to: d.appendingPathComponent("rgb/\(stem).jpg")); n += jpg.count; rgbBytes += jpg.count
            }
            if let png = Self.png(mm, width: dw, height: dh, bits: 16) {
                try? png.write(to: d.appendingPathComponent("depth/\(stem).png")); n += png.count; depthBytes += png.count
            }
            if let c = conf, let png = Self.png(c.0, width: c.1, height: c.2, bits: 8) {
                try? png.write(to: d.appendingPathComponent("confidence/\(stem).png")); n += png.count; confBytes += png.count
            }
            // 9.4: the sharpest saved frame of each keyframe window becomes the keyframe (written when the window ends)
            let cand = kfInfo.map { KFCandidate(index: index, pixel: pixel, t: t, w: $0.w, h: $0.h, fx: $0.fx, fy: $0.fy,
                                                cx: $0.cx, cy: $0.cy, blurPx: blur, exposureS: exposureS, iso: iso) }
            if let pick = picker.offer(window: win, payload: cand, score: { Self.sharpness(pixel) }), let c = pick.payload {
                writeKeyframe(c, score: pick.score, candidates: pick.candidates)
            }
            encMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            encSum += encMs
            encMax = max(encMax, encMs)
            let line = Data(odoLine.utf8)
            odometry?.write(line)
            n += line.count
            bytes += n
            saved += 1
            lastFrameWritten = index
            if segments.frameWritten(index: index, t: t) != nil {        // segment closed: checkpoint (≤ 1 per ~10 s)
                flushIMU()
                checkpoint?.dropped = droppedNow
                writeCheckpoint()
            }
            let s = RecordStats(frames: saved, dropped: droppedNow, bytes: bytes, elapsed: elapsed, keyframes: kfSaved)
            DispatchQueue.main.async {
                var s2 = s
                s2.slowDown = self.motionHint.active
                self.onStats?(s2)
            }
        } }
    }

    /// A window's chosen keyframe (on queue): keyframes/NNNNNN.jpg first, then its keyframes.csv row (recovery keeps a
    /// keyframe only when both exist).
    private func writeKeyframe(_ c: KFCandidate, score: Double, candidates: Int) {
        guard let d = dir, let kj = jpeg(c.pixel, quality: AdaptiveCapture.keyframeQuality, fullSize: true) else { return }
        let stem = CaptureNaming.frameStem(c.index)
        guard (try? kj.write(to: d.appendingPathComponent("keyframes/\(stem).jpg"))) != nil else { return }
        let row = Data(CaptureFormat.keyframeLine(frame: c.index, timestamp: c.t, width: c.w, height: c.h, fx: c.fx, fy: c.fy,
                                                  cx: c.cx, cy: c.cy, sharpness: score, blurPx: c.blurPx,
                                                  exposureS: c.exposureS, iso: c.iso, candidates: candidates).utf8)
        keyframesFile?.write(row)
        bytes += kj.count + row.count; kfBytes += kj.count; kfSaved += 1
        if kfBlur.count < 5000 { kfBlur.append(c.blurPx); kfCands.append(candidates) }
        DispatchQueue.main.async { [weak self] in           // 9.8: measured sharpness confirms / vetoes "slow down"
            self?.motionHint.keyframe(sharpness: score)
        }
    }

    /// Sharpness of a camera buffer's luma plane (on queue): KeyframeQuality.laplacianVariance, 4× box-downscaled.
    static func sharpness(_ pixel: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard CVPixelBufferIsPlanar(pixel), let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) else { return 0 }
        return KeyframeQuality.laplacianVariance(luma: base.assumingMemoryBound(to: UInt8.self),
                                                 width: CVPixelBufferGetWidthOfPlane(pixel, 0),
                                                 height: CVPixelBufferGetHeightOfPlane(pixel, 0),
                                                 bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0))
    }

    /// ISO of this frame from its EXIF (ARFrame.exifData, iOS 16+); 0 when absent.
    static func exifISO(_ frame: ARFrame) -> Double {
        let exif = frame.exifData
        let sub = exif[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? exif
        if let a = sub[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let v = a.first { return v.doubleValue }
        if let a = sub[kCGImagePropertyExifISOSpeedRatings as String] as? [Double], let v = a.first { return v }
        return 0
    }

    /// capture.partial.json, atomically (on queue). What recovery needs if the app is killed before Stop.
    private func writeCheckpoint() {
        guard let d = dir, var cp = checkpoint else { return }
        cp.updated = Date().timeIntervalSince1970
        cp.frames = saved
        cp.lastFrame = lastFrameWritten
        cp.segments = segments.closed
        checkpoint = cp
        try? cp.encoded().write(to: d.appendingPathComponent(CaptureCheckpoint.fileName), options: .atomic)
    }

    // MARK: IMU

    private func startIMU() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.01
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let a = [dm.userAcceleration.x + dm.gravity.x, dm.userAcceleration.y + dm.gravity.y, dm.userAcceleration.z + dm.gravity.z]
            let w = [dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z]
            let line = CaptureFormat.imuLine(timestamp: dm.timestamp, accelG: a, gyro: w)
            self.queue.async {
                self.imuBuffer += line
                if self.imuBuffer.utf8.count > Self.imuFlushBytes { self.flushIMU() }
            }
        }
    }

    private func flushIMU() {     // on queue
        guard !imuBuffer.isEmpty else { return }
        let d = Data(imuBuffer.utf8)
        imu?.write(d)
        bytes += d.count
        imuBuffer = ""
    }

    // MARK: encoding (queue)

    private func jpeg(_ pixel: CVPixelBuffer, quality: Double, fullSize: Bool = false) -> Data? {
        let img = CIImage(cvPixelBuffer: pixel)
        if fullSize {                                  // keyframe: the camera image as is (1920×1440)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            return ci.jpegRepresentation(of: img, colorSpace: space, options: [key: quality])
        }
        let w = CGFloat(CaptureFormat.rgbSize.width), h = CGFloat(CaptureFormat.rgbSize.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: w / img.extent.width, y: h / img.extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let d = ci.jpegRepresentation(of: scaled, colorSpace: space, options: [key: quality]) { return d }
        guard let cg = ci.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space)
        else { return nil }
        return Self.encode(cg, type: UTType.jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ cg: CGImage, type: UTType, options: [CFString: Any] = [:]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Grayscale PNG from tightly packed samples (16-bit little-endian or 8-bit).
    static func png(_ data: Data, width: Int, height: Int, bits: Int) -> Data? {
        guard width > 0, height > 0, data.count >= width * height * bits / 8,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        var info = CGImageAlphaInfo.none.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits,
                               bytesPerRow: width * bits / 8, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return encode(cg, type: UTType.png)
    }

    /// sceneDepth Float32 metres → packed UInt16 millimetres (little-endian), with its size.
    static func copyDepth(_ buf: CVPixelBuffer) -> (Data, Int, Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return (Data(), w, h) }
        var out = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { out[y * w + x] = CaptureFormat.depthMillimetres(row[x]).littleEndian }
        }
        return (out.withUnsafeBufferPointer { Data(buffer: $0) }, w, h)
    }

    /// One-byte-per-pixel buffer (confidence) → packed bytes, with its size.
    static func copyBytes(_ buf: CVPixelBuffer) -> (Data, Int, Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return (Data(), w, h) }
        var out = Data(count: w * h)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: y * w), base.advanced(by: y * bpr), w)
            }
        }
        return (out, w, h)
    }
}
