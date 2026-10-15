// 9.3 "Object scan (high-res)" → Photo-quality: Apple Object Capture (docs/SNAILSIGHT-API.md §9).
// Evidence for the choice (Apple RealityKit docs, checked 2026-10-12): ObjectCaptureSession + ObjectCaptureView are
// iOS/iPadOS 17+ on LiDAR devices (`ObjectCaptureSession.isSupported`), with Apple's guided capture UI including the
// adjustable AR bounding box (state .detecting) and scan passes (userCompletedScanPass → beginNewScanPass);
// PhotogrammetrySession runs ON the phone, where `.reduced` is the only detail level (diffuse + normal + AO maps, metric
// scale from the LiDAR depth in the HEIC shots); `maximumNumberOfInputImages` caps on-device reconstruction (the
// session stops taking shots there unless over-capture is on, which only helps a Mac). `.modelFile(url:)` writes a
// USDZ file, or OBJ + MTL + textures when the URL is a folder: both are requested in one process call.
// The shots (HEIC with depth + gravity) are uploaded too, so the map server keeps everything a later server-side
// rebuild needs. Folder: Documents/captures/obj-<UTC>/{images/, model/model.usdz, model/obj/, object.json}.
import RealityKit
import SwiftUI
import SnailSightCore

@MainActor
final class PhotoScanController: ObservableObject {
    enum Phase: Equatable { case capturing, reconstructing, finished, failed }

    @Published var phase: Phase = .capturing
    @Published private(set) var session: ObjectCaptureSession?
    @Published var captureState = "initializing"
    @Published var shots = 0
    @Published var maxImages = 0
    @Published var feedback: [String] = []
    @Published var passDone = false
    @Published var passes = 1
    @Published var progress: Double = 0
    @Published var error: String?

    let id: String
    let dir: URL
    let name: String
    let tags: [String]
    private let images: URL
    private let checkpoint: URL
    private let started = Date()
    private var reconStart: Date?
    private var tasks: [Task<Void, Never>] = []
    private var reconstructing = false
    private let meta: [String: Any]
    private let log: (String, [String: LogValue]) -> Void
    /// Called once when the flow ends: true = a capture folder is ready to upload.
    var onEnd: (@MainActor (Bool) -> Void)?

    static var isSupported: Bool { ObjectCaptureSession.isSupported }

    init(id: String, dir: URL, name: String, tags: [String], meta: [String: Any],
         log: @escaping (String, [String: LogValue]) -> Void) {
        self.id = id; self.dir = dir; self.name = name; self.tags = tags; self.meta = meta; self.log = log
        images = dir.appendingPathComponent("images", isDirectory: true)
        checkpoint = FileManager.default.temporaryDirectory.appendingPathComponent("oc-checkpoint-\(id)", isDirectory: true)
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("Could not create the scan folder: \(error.localizedDescription)")
            return
        }
        try? FileManager.default.removeItem(at: checkpoint)          // must be empty if it exists
        var cfg = ObjectCaptureSession.Configuration()
        cfg.checkpointDirectory = checkpoint
        let s = ObjectCaptureSession()
        s.start(imagesDirectory: images, configuration: cfg)
        session = s
        maxImages = s.maximumNumberOfInputImages
        log("object_photo_start", ["id": .string(id), "max_images": .int(maxImages), "name": .string(name)])
        tasks.append(Task { [weak self] in
            for await st in s.stateUpdates { self?.handle(st) }
        })
        tasks.append(Task { [weak self] in
            for await n in s.numberOfShotsTakenUpdates { self?.shots = n }
        })
        tasks.append(Task { [weak self] in
            for await fb in s.feedbackUpdates { self?.feedback = fb.map { Self.friendly(String(describing: $0)) }.sorted() }
        })
        tasks.append(Task { [weak self] in
            for await done in s.userCompletedScanPassUpdates where done {
                guard let self else { return }
                self.passDone = true
                self.log("object_photo_pass", ["id": .string(self.id), "pass": .int(self.passes), "shots": .int(self.shots)])
            }
        })
    }

    private func handle(_ st: ObjectCaptureSession.CaptureState) {
        switch st {
        case .ready: captureState = "ready"
        case .detecting: captureState = "detecting"
        case .capturing: captureState = "capturing"
        case .finishing: captureState = "finishing"
        case .completed:
            captureState = "completed"
            Task { await reconstruct() }
        case .failed(let e):
            captureState = "failed"
            fail("Object Capture failed: \(e.localizedDescription)")
        default:
            captureState = "initializing"
        }
        log("object_photo_state", ["id": .string(id), "state": .string(captureState), "shots": .int(shots)])
    }

    // MARK: user actions

    func continueToBox() {
        // false when no horizontal plane is found along the centre ray (Apple docs): ask to show more floor
        if session?.startDetecting() == false {
            feedback = ["Aim so the screen centre is on the object with floor visible around it, then tap Continue again"]
        }
    }
    func startCapturing() { session?.startCapturing() }
    func resetBox() { session?.resetDetection() }
    func nextPass() {
        session?.beginNewScanPass()
        passes += 1
        passDone = false
    }
    func finish() { session?.finish() }

    func cancel() {
        let s = session
        endTasks()
        session = nil
        s?.cancel()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: checkpoint)
        log("object_photo_cancel", ["id": .string(id), "shots": .int(shots), "phase": .string("\(phase)")])
        let h = onEnd
        onEnd = nil
        h?(false)
    }

    func close() {
        let h = onEnd
        onEnd = nil
        h?(phase == .finished)
    }

    // MARK: reconstruction (on the phone)

    private func reconstruct() async {
        guard !reconstructing else { return }
        reconstructing = true
        endTasks()
        session = nil                                               // free the capture session before reconstructing
        phase = .reconstructing
        reconStart = Date()
        let modelDir = dir.appendingPathComponent("model", isDirectory: true)
        let objDir = modelDir.appendingPathComponent("obj", isDirectory: true)
        try? FileManager.default.createDirectory(at: objDir, withIntermediateDirectories: true)
        let usdz = modelDir.appendingPathComponent("model.usdz")
        var errors: [String] = []
        log("object_photo_recon_start", ["id": .string(id), "shots": .int(shots), "passes": .int(passes)])
        do {
            var cfg = PhotogrammetrySession.Configuration()
            cfg.checkpointDirectory = checkpoint
            let ps = try PhotogrammetrySession(input: images, configuration: cfg)
            try ps.process(requests: [.modelFile(url: usdz), .modelFile(url: objDir)])
            outer: for try await out in ps.outputs {
                switch out {
                case .requestProgress(_, let f):
                    progress = f
                case .requestError(_, let e):
                    errors.append(e.localizedDescription)
                case .processingComplete:
                    break outer
                case .processingCancelled:
                    errors.append("reconstruction cancelled")
                    break outer
                default:
                    break
                }
            }
        } catch {
            errors.append(error.localizedDescription)
        }
        let secs = Date().timeIntervalSince(reconStart ?? Date())
        let haveModel = FileManager.default.fileExists(atPath: usdz.path)
            || ((try? FileManager.default.contentsOfDirectory(atPath: objDir.path))?.contains { $0.hasSuffix(".obj") } ?? false)
        writeObjectJSON(reconSeconds: secs, errors: errors, haveModel: haveModel)
        try? FileManager.default.removeItem(at: checkpoint)
        log("object_photo_recon_done", ["id": .string(id), "s": .double((secs * 10).rounded() / 10),
                                        "model": .bool(haveModel), "errors": .string(errors.joined(separator: " | ").prefix(300).description)])
        if haveModel {
            phase = .finished
        } else {
            // the shots still upload (object.json says why there is no model)
            error = "The phone could not build the model: \(errors.first ?? "unknown error"). The photos still upload."
            phase = .failed
        }
    }

    private func writeObjectJSON(reconSeconds: Double, errors: [String], haveModel: Bool) {
        let n = (try? FileManager.default.contentsOfDirectory(atPath: images.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
        var o = meta
        o["schema"] = "snailsight.object/1"
        o["mode"] = ObjectScanMode.photo.rawValue
        o["client_object_id"] = id
        o["object_name"] = name
        o["object_tags"] = tags
        o["started"] = started.timeIntervalSince1970
        o["ended"] = Date().timeIntervalSince1970
        o["images"] = n
        o["shots"] = shots
        o["passes"] = passes
        o["max_images"] = maxImages
        o["detail"] = "reduced"
        o["reconstruction_s"] = (reconSeconds * 10).rounded() / 10
        o["ios"] = UIDevice.current.systemVersion
        if !errors.isEmpty { o["reconstruction_error"] = errors.joined(separator: " | ") }
        o["model"] = haveModel
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
            try? d.write(to: dir.appendingPathComponent("object.json"), options: .atomic)
        }
    }

    private func fail(_ text: String) {
        error = text
        phase = .failed
        log("object_photo_failed", ["id": .string(id), "error": .string(text)])
    }

    private func endTasks() {
        for t in tasks { t.cancel() }
        tasks = []
    }

    /// "objectTooClose" → "Object too close".
    static func friendly(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

struct PhotoCaptureView: View {
    @ObservedObject var c: PhotoScanController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let s = c.session {
                ObjectCaptureView(session: s).ignoresSafeArea()
            }
            VStack(spacing: 10) {
                HStack {
                    if c.phase == .capturing {
                        Button("Cancel", role: .cancel) { c.cancel() }.buttonStyle(.bordered)
                    }
                    Spacer()
                    if c.phase == .capturing && c.captureState == "capturing" {
                        Text("\(c.shots)\(c.maxImages > 0 ? " / \(c.maxImages)" : "") photos · pass \(c.passes)")
                            .font(.headline).monospacedDigit()
                    }
                }
                Text(instruction).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                if c.phase == .capturing, !c.feedback.isEmpty {
                    Text(c.feedback.joined(separator: " · ")).font(.footnote).foregroundStyle(.orange)
                        .padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
                controls
            }
            .padding()
            .foregroundStyle(.white)
        }
        .alert("Pass \(c.passes) done", isPresented: $c.passDone) {
            Button("Another pass") { c.nextPass() }
            Button("Finish and build") { c.finish() }
        } message: {
            Text("Go round again lower (wheels, rear compartment) or higher (top deck) for a complete model, or finish now.")
        }
    }

    private var instruction: String {
        switch c.phase {
        case .reconstructing:
            return "Building the 3D model on the phone (a few minutes). Keep SnailSight open and the phone cool."
        case .finished:
            return "Model built ✓ It uploads to the map server now; the result shows in the Objects viewer."
        case .failed:
            return c.error ?? "Failed"
        case .capturing:
            switch c.captureState {
            case "ready": return "Point the centre of the screen at the object, then tap Continue."
            case "detecting": return "Drag the box handles so the box just fits the object (wheels to top deck), then Start capture."
            case "capturing": return "Walk slowly all the way round, keeping the object in view. Then a low pass and a high pass."
            case "finishing": return "Saving the photos…"
            case "completed": return "Photos saved"
            default: return "Starting the camera…"
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch c.phase {
        case .reconstructing:
            VStack {
                ProgressView(value: c.progress).tint(.green)
                Text(String(format: "%.0f %%", c.progress * 100)).monospacedDigit()
            }
            .padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        case .finished, .failed:
            Button { c.close() } label: { Text("Done").frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent)
        case .capturing:
            HStack(spacing: 10) {
                switch c.captureState {
                case "ready":
                    Button { c.continueToBox() } label: { wide("Continue") }.buttonStyle(.borderedProminent)
                case "detecting":
                    Button { c.resetBox() } label: { wide("Reset box") }.buttonStyle(.bordered)
                    Button { c.startCapturing() } label: { wide("Start capture") }.buttonStyle(.borderedProminent)
                case "capturing":
                    Button { c.finish() } label: { wide("Finish and build") }.buttonStyle(.borderedProminent)
                        .disabled(c.shots < 10)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func wide(_ t: String) -> some View { Text(t).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8) }
}
