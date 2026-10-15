// 9.4 camera settings for sharper captures (owner 2026-10-13: "a lot of splat photos have some motion blur").
// ARKit exposes the AVCaptureDevice behind its camera feed: ARConfiguration.configurableCaptureDeviceForPrimaryCamera
// (iOS 16+; https://developer.apple.com/documentation/arkit/arconfiguration/configurablecapturedeviceforprimarycamera:
// "By altering the device's configuration, your app indirectly adjusts the visual properties of each AR frame's
// capturedImage. Alter the device's settings with caution, as extreme changes can affect ARKit's features"). We change
// ONLY exposure / white-balance behaviour, never the format or frame rate (tracking depends on them):
//  - Sharp (default): continuous auto exposure with `activeMaxExposureDuration` capped at 1/250 s (AVCaptureDevice docs:
//    settable in auto-exposure modes between the format's min and max exposure; it resets to the default whenever the
//    format / session changes, so the cap is re-asserted on every HUD tick after a session re-run). AE then raises ISO
//    instead of lengthening the shutter: ~4× less motion blur than ARKit's default (up to 1/60 s at 60 fps indoors),
//    at the cost of more sensor noise in dim rooms.
//  - while recording: white balance locked after AWB settles (~0.8 s) so colours stay consistent along a walk (splats /
//    textures blend views); for an OBJECT scan exposure is locked too (one small, evenly lit area). Room recordings
//    keep auto exposure (rooms differ a lot in brightness; the splat trainer compensates per-image exposure).
//  - Auto: ARKit's defaults (cap reset to .invalid, nothing locked).
// Not used: the 4K video format (recommendedVideoFormatFor4KResolution, 30 fps, 3840×2880) and captureHighResolution
// Frame (out-of-band stills): both cost heat/memory the 2026-10-12 recording kill showed we do not have, and LiDAR
// depth stays 256×192 either way. Every change is logged (ev "camera") with the device's actual exposure / ISO.
import ARKit
import AVFoundation
import SnailSightCore

final class CameraTuner {
    static let shared = CameraTuner()
    static let modeKey = "camera.mode"

    static var mode: CameraMode {
        CameraMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .sharp
    }

    var log: ((String, [String: LogValue]) -> Void)?

    private var device: AVCaptureDevice? { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera }
    private var recording = false
    private var objectScan = false
    private var recordStart: Date?
    private var locked = (wb: false, exposure: false)
    private var reasserts = 0
    private var lastSnapshot: [String: Any] = [:]
    private var unavailableLogged = false

    var plan: CameraPlan { CameraPolicy.plan(mode: Self.mode, recording: recording, objectScan: objectScan) }

    /// After the session (re)runs, after a Settings change, and from every HUD tick (cheap when nothing changed).
    func apply(reason: String) {
        guard let d = device else {
            if !unavailableLogged {
                unavailableLogged = true
                log?("camera", ["why": .string(reason), "error": .string("no configurable capture device")])
            }
            return
        }
        let p = plan
        if reason == "tick" && !needsWork(d, p) { return }     // HUD tick: lock the device only when something is off
        var changed: [String] = []
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            // exposure cap (auto exposure modes only; a locked exposure keeps the values it was locked at)
            if !locked.exposure {
                if d.exposureMode == .locked || d.exposureMode == .custom, d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                    changed.append("ae_continuous")
                }
                if let s = p.maxExposureS {
                    let f = d.activeFormat
                    let v = CameraPolicy.clampExposure(s, minS: f.minExposureDuration.seconds, maxS: f.maxExposureDuration.seconds)
                    if !(abs(d.activeMaxExposureDuration.seconds - v) <= 1e-5) {
                        d.activeMaxExposureDuration = CMTime(seconds: v, preferredTimescale: 1_000_000)
                        changed.append("max_exposure")
                    }
                } else if reason == "settings" {
                    d.activeMaxExposureDuration = .invalid           // back to the device default for this format
                    changed.append("max_exposure_default")
                }
            }
            // locks while recording, after AE/AWB settled on the start view
            let settled = recordStart.map { Date().timeIntervalSince($0) >= CameraPolicy.settleS } ?? false
            if p.lockWhiteBalance && settled && !locked.wb, d.isWhiteBalanceModeSupported(.locked) {
                d.whiteBalanceMode = .locked
                locked.wb = true
                changed.append("wb_locked")
            }
            if p.lockExposure && settled && !locked.exposure, d.isExposureModeSupported(.locked) {
                d.exposureMode = .locked
                locked.exposure = true
                changed.append("exposure_locked")
            }
            if !recording || !p.lockWhiteBalance, locked.wb || (reason == "settings" && d.whiteBalanceMode == .locked) {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                locked.wb = false
                changed.append("wb_auto")
            }
            if !recording || !p.lockExposure, locked.exposure {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                locked.exposure = false
                changed.append("exposure_auto")
            }
        } catch {
            log?("camera", ["why": .string(reason), "error": .string(error.localizedDescription)])
            return
        }
        if !changed.isEmpty {
            if reason == "tick" && changed == ["max_exposure"] { reasserts += 1 }
            var ev = snapshotFields()
            ev["why"] = .string(reason)
            ev["changed"] = .string(changed.joined(separator: ","))
            log?("camera", ev)
        }
    }

    private func needsWork(_ d: AVCaptureDevice, _ p: CameraPlan) -> Bool {
        let settled = recordStart.map { Date().timeIntervalSince($0) >= CameraPolicy.settleS } ?? false
        if p.lockWhiteBalance && settled && !locked.wb { return true }
        if p.lockExposure && settled && !locked.exposure { return true }
        if locked.wb && (!recording || !p.lockWhiteBalance) { return true }
        if locked.exposure && (!recording || !p.lockExposure) { return true }
        if let s = p.maxExposureS, !locked.exposure {
            let f = d.activeFormat
            let v = CameraPolicy.clampExposure(s, minS: f.minExposureDuration.seconds, maxS: f.maxExposureDuration.seconds)
            if !(abs(d.activeMaxExposureDuration.seconds - v) <= 1e-5) { return true }
        }
        return false
    }

    func recordingStarted(objectScan: Bool) {
        recording = true
        self.objectScan = objectScan
        recordStart = Date()
        reasserts = 0
        apply(reason: "record_start")
    }

    /// capture.json `camera`: the mode, the policy and the device's state at stop (locked values = the whole walk's).
    func recordingStopped() -> [String: Any] {
        var out: [String: Any] = ["mode": Self.mode.rawValue, "object_scan": objectScan,
                                  "max_exposure_s": plan.maxExposureS ?? NSNull(), "wb_locked": locked.wb,
                                  "exposure_locked": locked.exposure, "cap_reasserts": reasserts]
        for (k, v) in snapshot() { out["device_" + k] = v }
        recording = false
        objectScan = false
        recordStart = nil
        apply(reason: "record_stop")
        return out
    }

    /// Current device values (main thread).
    func snapshot() -> [String: Any] {
        guard let d = device else { return [:] }
        let g = d.deviceWhiteBalanceGains
        let fin = { (v: Double) in v.isFinite ? v : 0 }        // JSONSerialization throws on NaN / inf
        return ["exposure_s": fin(d.exposureDuration.seconds), "iso": Double(d.iso),
                "max_exposure_s": fin(d.activeMaxExposureDuration.seconds),
                "format_exposure_s": [fin(d.activeFormat.minExposureDuration.seconds), fin(d.activeFormat.maxExposureDuration.seconds)],
                "format_iso": [Double(d.activeFormat.minISO), Double(d.activeFormat.maxISO)],
                "wb_gains": [Double(g.redGain), Double(g.greenGain), Double(g.blueGain)],
                "exposure_mode": d.exposureMode.rawValue, "wb_mode": d.whiteBalanceMode.rawValue]
    }

    private func snapshotFields() -> [String: LogValue] {
        guard let d = device else { return [:] }
        let g = d.deviceWhiteBalanceGains
        let ms = { (t: CMTime) in t.seconds.isFinite ? (t.seconds * 1000 * 100).rounded() / 100 : 0 }
        return ["mode": .string(Self.mode.rawValue), "recording": .bool(recording), "object": .bool(objectScan),
                "exposure_ms": .double(ms(d.exposureDuration)),
                "iso": .double(Double(d.iso).rounded()),
                "max_exposure_ms": .double(ms(d.activeMaxExposureDuration)),
                "fmt_max_exposure_ms": .double(ms(d.activeFormat.maxExposureDuration)),
                "fmt_max_iso": .double(Double(d.activeFormat.maxISO)),
                "wb": .doubles([Double(g.redGain), Double(g.greenGain), Double(g.blueGain)]),
                "wb_locked": .bool(locked.wb), "exposure_locked": .bool(locked.exposure)]
    }

    /// One ev "camera" line with the device's current values (record start + 1 s, every 30 s while recording).
    func logState(_ why: String) {
        guard device != nil else { return }
        var ev = snapshotFields()
        ev["why"] = .string(why)
        log?("camera", ev)
    }
}
