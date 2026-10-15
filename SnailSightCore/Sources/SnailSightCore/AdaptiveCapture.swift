import Foundation

// 9.1.61 adaptive recording (docs/SNAILSIGHT-API.md §4.4a). Evidence from the 2026-10-12 kill: thermal reached SERIOUS
// at t+354 s, the encoder backed up, footprint grew to ~3 GB (iOS diskwrites report: 7.5 MB → 2978 MB, max 3250 MB in
// 8 min) with ARKit scene reconstruction (Recon3D) the busiest thread, then iOS killed the app. The policy below is
// pure: the app feeds it the thermal state + os_proc_available_memory every HUD tick and applies the decision.

public enum ThermalLevel: Int, Comparable, CaseIterable {
    case nominal = 0, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    /// From the HUD strings the app already uses ("nominal", "fair", "SERIOUS", "CRITICAL").
    public init(label: String) {
        switch label.lowercased() {
        case "fair": self = .fair
        case "serious": self = .serious
        case "critical": self = .critical
        default: self = .nominal
        }
    }
}

/// What happens to the live LiDAR scene mesh while recording (9.6, owner feedback on 9.3.65: "I couldn't see the mesh").
/// - live: ARKit scene reconstruction on, wireframe rebuilt as usual (recording pace: ≤ 1 anchor/frame, ≥ 4 s apart)
/// - throttled: still on, but the wireframe rebuilds each anchor at most every 8 s (thermal fair, memory fine)
/// - frozen: ARKit scene reconstruction stops and releases its volume (the 2026-10-12 crash was this memory growing);
///   the wireframe already built STAYS on screen, dimmed, and no longer changes until Stop
public enum MeshMode: String, Equatable, Comparable {
    case live, throttled, frozen
    private var rank: Int { self == .live ? 0 : self == .throttled ? 1 : 2 }
    public static func < (a: MeshMode, b: MeshMode) -> Bool { a.rank < b.rank }
}

public struct CaptureDecision: Equatable {
    public var rateHz: Double
    public var jpegQuality: Double
    public var meshMode: MeshMode = .live
    public var stopReason: String?       // non-nil: stop the recording cleanly now
    public var warning: String?          // orange on-screen line while recording (hot / memory)
    public var level: String             // "normal" | "warm" | "reduced" | "minimal" | "stop" (logged when it changes)
    public var keyframeScale: Double = 1 // multiplies the keyframe spacing (0 = no keyframes)
    public var note: String? = nil       // neutral (grey) line, e.g. the mesh memory cap

    /// Pre-9.6 name: scene reconstruction stops for the rest of the recording.
    public var shedMesh: Bool { meshMode == .frozen }
}

public enum AdaptiveCapture {
    public static let baseRateHz = 10.0
    public static let baseQuality = 0.65
    /// os_proc_available_memory thresholds (MB left before the per-app limit).
    public static let shedMeshBelowMB = 1200.0
    public static let minimalBelowMB = 700.0
    public static let stopBelowMB = 350.0
    /// Mesh memory cap: total vertices of the live scene mesh (ARMeshAnchors). Above it the mesh freezes (kept on
    /// screen, no more growth) while the recording continues at full rate. ~3 M vertices ≈ a whole storey at LiDAR
    /// density; ARKit's own reconstruction volume grows with it (the 9.1.61 kill: Recon3D the busiest thread at ~3 GB).
    public static let meshVertexCap = 3_000_000
    /// Wireframe rebuild spacing per anchor (s) while recording.
    public static func meshRebuildInterval(_ m: MeshMode) -> Double { m == .throttled ? 8 : 4 }

    /// 9.6 table (owner feedback on 9.3.65: FAIR throttled to 5 fps and hid the mesh, which was confusing and
    /// unnecessary — fair is normal for a phone running LiDAR + camera for minutes):
    ///   critical / < 350 MB                      → stop + save
    ///   < 700 MB / ≥ 2 memory warnings           → 2 Hz, q0.5, mesh frozen, keyframes ×2 spacing
    ///   serious (memory fine, 9.8)               → 5 Hz, q0.6, mesh updates throttled, no banner (status chip)
    ///   serious + memory getting low             → 2 Hz, q0.5, mesh frozen
    ///   < 1200 MB / 1 memory warning             → 5 Hz, q0.6, mesh frozen
    ///   fair (memory fine)                       → 10 Hz, q0.65, mesh updates throttled (no warning)
    ///   nominal                                  → 10 Hz, q0.65, mesh live
    /// and, at any level, the mesh freezes once it holds more than `meshVertexCap` vertices.
    /// - Parameters:
    ///   - thermal: current ProcessInfo thermal state
    ///   - availableMB: os_proc_available_memory in MB (nil when unknown)
    ///   - memoryWarnings: UIApplication memory warnings seen during this recording
    ///   - meshVertices: vertices in the live scene mesh (nil = unknown)
    public static func decide(thermal: ThermalLevel, availableMB: Double?, memoryWarnings: Int = 0,
                              meshVertices: Int? = nil) -> CaptureDecision {
        let avail = availableMB ?? .infinity
        if thermal == .critical {
            return CaptureDecision(rateHz: 0, jpegQuality: 0.5, meshMode: .frozen, stopReason: "thermal_critical",
                                   warning: "Phone too hot: recording stopped and saved", level: "stop", keyframeScale: 0)
        }
        if avail < stopBelowMB {
            return CaptureDecision(rateHz: 0, jpegQuality: 0.5, meshMode: .frozen, stopReason: "memory_low",
                                   warning: "Memory almost full: recording stopped and saved", level: "stop", keyframeScale: 0)
        }
        var d: CaptureDecision
        if avail < minimalBelowMB || memoryWarnings >= 2 {
            d = CaptureDecision(rateHz: 2, jpegQuality: 0.5, meshMode: .frozen, stopReason: nil,
                                warning: "Memory is low: REC 2 fps, mesh frozen. Stop soon",
                                level: "minimal", keyframeScale: 2)
        } else if thermal == .serious && avail >= shedMeshBelowMB && memoryWarnings == 0 {
            // 9.8 (owner: "over-judging the heat, the phone did not feel that hot"): iOS's SERIOUS comes early; ease
            // off (5 Hz, slower mesh rebuilds) without the orange banner — the status chip explains it in one line.
            d = CaptureDecision(rateHz: 5, jpegQuality: 0.6, meshMode: .throttled, stopReason: nil,
                                warning: nil, level: "hot")
        } else if thermal == .serious {
            d = CaptureDecision(rateHz: 2, jpegQuality: 0.5, meshMode: .frozen, stopReason: nil,
                                warning: "Phone is hot and memory is low: REC 2 fps, mesh frozen. Stop soon",
                                level: "minimal", keyframeScale: 2)
        } else if avail < shedMeshBelowMB || memoryWarnings == 1 {
            d = CaptureDecision(rateHz: 5, jpegQuality: 0.6, meshMode: .frozen, stopReason: nil,
                                warning: "Memory is getting low: REC 5 fps, mesh frozen", level: "reduced")
        } else if thermal == .fair {
            d = CaptureDecision(rateHz: baseRateHz, jpegQuality: baseQuality, meshMode: .throttled, stopReason: nil,
                                warning: nil, level: "warm")
        } else {
            d = CaptureDecision(rateHz: baseRateHz, jpegQuality: baseQuality, meshMode: .live, stopReason: nil,
                                warning: nil, level: "normal")
        }
        if let v = meshVertices, v > meshVertexCap, d.meshMode != .frozen {
            d.meshMode = .frozen
            d.note = "Mesh frozen at its memory cap: recording continues at \(Int(d.rateHz)) fps"
        }
        return d
    }

    /// HUD headline rates: "AR 60 fps" or, while recording, "AR 60 fps · REC 10 fps" (the camera/AR frame rate and
    /// the capture rate are different things; 9.3.65 showed only the first next to a "recording at 5 fps" banner).
    public static func rateLine(arFPS: Double, recording: Bool, recRateHz: Double) -> String {
        let ar = String(format: "AR %.0f fps", arFPS)
        guard recording else { return ar }
        return ar + (recRateHz > 0 ? String(format: " · REC %.0f fps", recRateHz) : " · REC stopped")
    }

    /// HUD mesh word for the status line.
    public static func meshLabel(_ m: MeshMode, recording: Bool) -> String {
        switch m {
        case .live: return "live"
        case .throttled: return recording ? "slow updates" : "live"
        case .frozen: return "frozen"
        }
    }

    /// Keyframe gate on top of the rate limit: a frame is worth saving when the camera moved or turned enough since the
    /// last saved one (standing still produces nothing), with a keep-alive so a slow pan still saves ≥ 1 frame/s.
    public static func moved(translationM: Double, rotationDeg: Double, sinceLastS: Double,
                             minTranslation: Double = 0.02, minRotation: Double = 2, keepAlive: Double = 1.0) -> Bool {
        translationM >= minTranslation || rotationDeg >= minRotation || sinceLastS >= keepAlive
    }

    /// Full-resolution texture keyframes (9.1.61, owner: scan mesh looks low-res): one 1920×1440 JPEG every
    /// ~0.4 m or 15° of camera movement since the last keyframe, never closer than 1.5 s (bounds disk writes + heat:
    /// ≤ 0.67 keyframes/s ≈ ≤ 25 MB/min worst case at q0.75). `scale` widens the spacing (2 at "minimal").
    public static let keyframeMetres = 0.4
    public static let keyframeDegrees = 15.0
    public static let keyframeMinInterval = 1.5
    public static let keyframeQuality = 0.75

    public static func isKeyframe(translationM: Double?, rotationDeg: Double?, sinceLastS: Double?, scale: Double = 1) -> Bool {
        guard scale > 0 else { return false }
        guard let tr = translationM, let rot = rotationDeg, let dt = sinceLastS else { return true }   // first one
        guard dt >= keyframeMinInterval * scale else { return false }
        return tr >= keyframeMetres * scale || rot >= keyframeDegrees * scale
    }

    /// Angle between two unit quaternions (degrees).
    public static func rotationDegrees(_ a: CaptureFormat.Quat, _ b: CaptureFormat.Quat) -> Double {
        let dot = abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w)
        return 2 * acos(min(1, dot)) * 180 / .pi
    }
}
