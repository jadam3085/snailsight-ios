// SnailSight P2b: localize against the map server's MASTER combined map (`site`, every room merged) and keep the sim
// bodies in the MAP frame (docs/SNAILSIGHT-REFACTOR-PLAN.md §7 P2b, API §5.6 / §5.7).
//
// On launch ("Find me", automatic) this sends one keyframe about every second (RGB 1024×768 JPEG + LiDAR depth +
// confidence + intrinsics + ARKit pose) to POST /v1/localize; the server gates (two agreeing fixes, inliers, gravity)
// and answers T_map_arkit. In parallel the P2a ARWorldMap fast path keeps running; when it relocalizes, the ARKit world
// origin jumps to the saved place, so this starts a new stream (and uses the place's cached map alignment at once).
// Once locked: the map's entities (GET /v1/maps/site/entities) are spawned at their map poses; if the place restore
// already put the same bodies within 15 cm they are left alone (cross-check, logged); if the map has none yet, the
// place's bodies are written into the map (migration). Every spawn / move / delete afterwards updates the map copy.
// A few refinements follow (every 8 s); a correction never moves bodies unless it is > 10 cm (then "re-aligned").
// 10.2 (owner: "I may open the app in any place, but don't necessarily want to record"): localization runs whenever the
// app is open and online — also while recording (slower) and with the sim off — with a battery-friendly cadence
// (LocCadence: 1 s until locked, 12 refinements every 8 s, then one refresh a minute; LiDAR depth is switched off
// between refreshes unless mapping / recording / Live map want it). The top pill (LocPill) shows the result.
// 10.3 master map first: the session starts clean (PlaceController); a saved map being tried is cancelled by the first
// server lock and the lock is CARRIED over that session reset (FrameCarry: the camera pose just before and just after
// the reset is the same physical pose), then confirmed by an immediate re-check. Every accepted fix is remembered
// (LastFixStore: where the phone was in the map) as the evidence for trying a saved place next launch. On a lock, saved
// places' animals the map does not have yet are written into it (PlaceMigration), so no world map is needed for them.
// 11.1 faster first lock: the first 20 s of a search send every 0.5 s (still one request in flight); the server locks
// on ONE visual fix its mesh ICP confirms (lock_rule "strong", API §5.6d); maploc_try logs the server's stage times.
import ARKit
import CoreImage
import Foundation
import SnailSightCore
import UIKit

/// What the HUD shows about the map localization (folded into PlaceHUD by PlaceController.publish).
struct MapLocState: Equatable {
    enum Phase: Equatable { case off, searching, locked }
    var phase: Phase = .off
    var title = ""
    var detail = ""
}

final class MapLocalizer {
    private unowned let model: AppModel
    let mapID = "site"
    private(set) var alignment: MapAlignment?          // this ARKit session's map ← ARKit (nil until locked)
    private(set) var lockSeconds: Double?
    /// 11.0: when this run's server lock arrived (the tile streamer's `since_lock_s` clock); nil while unlocked.
    private(set) var lockedAt: Double?
    private var placedWith: MapAlignment?               // the alignment the bodies on screen were placed with
    private(set) var streamID = MapLocalizer.newStream()
    private var streamStart = Date().timeIntervalSince1970
    private var lastAttempt = 0.0
    private var inFlight = false
    private var inFlightSince = 0.0
    private var retryState = LocRetry()                 // 10.6.x: backoff after errors; never stops while unplaced
    private var lastFrameAt = 0.0                       // AR frames arriving? (no frames = AR paused)
    private var wasOnline = false
    private var seenVersion: Int?
    private(set) var inBackground = false
    private var attempts = 0
    private var matches = 0
    private var hint: String?               // 10.4: the server's search hint (geometry search, API §5.6c)
    private var refinements = 0
    private var restoredFromMap = false
    private var syncWork: DispatchWorkItem?
    private var syncing = false
    private var source = ""                             // "server" | "place_cache"
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let enc = DispatchQueue(label: "snailsight.maploc", qos: .userInitiated)
    private var depthWanted = true
    private var lastFixAt: Double?                      // 10.2: the last accepted fix (lock / refinement / refresh)
    private var lastRmseCm: Double?
    private var notFound = false                        // server answered 404 (no such map)
    private var pendingApply: String?                   // a lock that arrived while recording: applied at Stop
    private var forceAttempt = false
    private var lastCam: simd_float4x4?                 // 10.3: the camera in the current ARKit frame (last AR frame)
    private var pendingCarry: (al: MapAlignment, oldCam: simd_float4x4, lockSeconds: Double?)?   // over a reset
    private var carryAfter: TimeInterval = 0            // frames captured before the reset belong to the old run
    private var migrateTried = Set<String>()            // one migration attempt per entity per app run

    static let syncDelay = 3.0
    static let realignCm = 10.0

    init(model: AppModel) { self.model = model }

    private var now: TimeInterval { Date().timeIntervalSince1970 }
    private static func newStream() -> String { "ar-" + UUID().uuidString.prefix(8).lowercased() }
    var isLocked: Bool { alignment != nil || pendingCarry != nil }
    /// 10.1 AR 1:1 status: "server" | "place_cache" | "" (no lock), seconds searching, attempts that matched.
    var lockSource: String { source }
    var searchSeconds: Double { now - streamStart }
    var matchCount: Int { matches }

    /// LiDAR depth frames are needed while searching / refining (ARSessionController adds `.sceneDepth`).
    var wantsDepth: Bool { depthWanted }

    // MARK: AR session events

    /// The ARKit world frame changed (session reset / a saved place relocalized / another place loaded): every fix
    /// and the lock belong to the old frame.
    /// `sessionRunFollows`: the caller re-runs the session right after (it picks up `.sceneDepth` from wantsDepth).
    /// `carryLock` (10.3): a saved map was aborted because the server locked: keep the lock across the reset.
    func worldFrameChanged(_ reason: String, placeID: String? = nil, sessionRunFollows: Bool = false,
                           carryLock: Bool = false) {
        model.liveStreamer.worldFrameChanged(reason)     // 10.0 Live map: a new odometry frame = a new stream_id
        model.meshMapper.worldFrameChanged(reason)       // 10.2 Map mesh: same rule
        model.controller.mapLayer.worldFrameChanged()    // 10.1 AR 1:1: the shown alignment belongs to the old frame
        model.log.event("maploc_reset", ["reason": .string(reason), "was_locked": .bool(alignment != nil),
                                         "attempts": .int(attempts), "carry": .bool(carryLock && alignment != nil)])
        if carryLock, let al = alignment, let cam = lastCam {
            pendingCarry = (al, cam, lockSeconds)
            carryAfter = ProcessInfo.processInfo.systemUptime
        } else {
            pendingCarry = nil
        }
        lastCam = nil
        streamID = Self.newStream()
        streamStart = now
        alignment = nil
        if !(carryLock && pendingCarry != nil) { lockedAt = nil }
        placedWith = nil
        lockSeconds = nil
        attempts = 0
        matches = 0
        hint = nil
        refinements = 0
        restoredFromMap = false
        source = ""
        lastFixAt = nil
        lastRmseCm = nil
        pendingApply = nil
        if sessionRunFollows { depthWanted = true } else { setDepthWanted(true) }
        if let pid = placeID, let cached = MapFrameCache.get(pid) {      // fast path: the place knows its map alignment
            alignment = cached
            source = "place_cache"
            lockSeconds = model.placeCtl.store.manifests[pid]?.lastLocalizeSeconds
            model.log.event("maploc_cached", ["place": .string(pid), "version": .int(cached.version)])
            DispatchQueue.main.asyncAfter(deadline: .now() + PlaceController.restoreDelay + 0.6) { [weak self] in
                self?.applyLock(reason: "place_cache")
            }
        }
        publish()
    }

    /// Every AR frame (main). Cheap unless an attempt is due.
    func frame(_ f: ARFrame) {
        if let pc = pendingCarry {
            // the first frame of the new run (the old one was relocalizing; the new one initializes / tracks)
            if f.timestamp > carryAfter, !Self.isRelocalizing(f.camera.trackingState) {
                applyCarry(pc, newCam: f.camera.transform)
            }
        }
        lastCam = f.camera.transform
        lastFrameAt = now
        if inFlight, now - inFlightSince > retryState.requestTimeout + 10 {   // a request that never came back
            inFlight = false
            model.log.event("maploc_stuck_cleared", ["s": .double(now - inFlightSince)])
        }
        guard model.serverBase != nil, !inFlight, !model.showScans else { return }
        let t = now
        guard forceAttempt || retryState.due(now: t) else { return }      // backoff after an error / timeout
        let hot = model.thermal == "SERIOUS" || model.thermal == "CRITICAL"
        let serverLocked = alignment != nil && source == "server"
        let since = t - lastAttempt
        // 10.2: depth only while it is useful (searching, refining, shortly before a refresh)
        let needDepth = forceAttempt || model.placeCtl.isTrying ||
            LocCadence.depthNeeded(locked: serverLocked, refinements: refinements, sinceLastAttempt: since,
                                   thermalSerious: hot, recording: model.recording)
        setDepthWanted(needDepth)
        let every = LocCadence.interval(locked: serverLocked, refinements: refinements, thermalSerious: hot,
                                        recording: model.recording, notInMap: isNotInMap, searchSeconds: t - streamStart)
        guard forceAttempt || since >= every else { return }
        switch f.camera.trackingState {
        case .normal: break
        case .limited(.relocalizing): break                // VIO still tracks in this session's frame
        default: return
        }
        guard let depth = f.sceneDepth else { setDepthWanted(true); return }
        lastAttempt = t
        forceAttempt = false
        inFlight = true
        inFlightSince = t
        attempts += 1
        let timeout = retryState.requestTimeout
        retryState.sent()
        let K = f.camera.intrinsics
        let res = f.camera.imageResolution
        let T = f.camera.transform
        let (d, dw, dh) = CaptureRecorder.copyDepth(depth.depthMap)
        let conf = depth.confidenceMap.map { CaptureRecorder.copyBytes($0) }
        let img = CIImage(cvPixelBuffer: f.capturedImage)
        let stream = streamID, frameNo = attempts, stamp = f.timestamp
        let locHint = LocHintStore.get()
        let link = model.link!
        enc.async { [weak self] in
            guard let self else { return }
            let rgb = self.jpeg(img)
            let dp = CaptureRecorder.png(d, width: dw, height: dh, bits: 16)
            let cp = conf.flatMap { CaptureRecorder.png($0.0, width: $0.1, height: $0.2, bits: 8) }
            guard let rgb, let dp else { DispatchQueue.main.async { self.inFlight = false }; return }
            var cm = [Double](repeating: 0, count: 16)       // row-major camera -> world
            for c in 0..<4 { for r in 0..<4 { cm[r * 4 + c] = Double(T[c][r]) } }
            var fr: [String: Any] = ["t": stamp, "frame": frameNo, "rgb_jpg": rgb.base64EncodedString(),
                                     "depth_png": dp.base64EncodedString(),
                                     "K": [Double(K[0][0]), Double(K[1][1]), Double(K[2][0]), Double(K[2][1])],
                                     "image_size": [Int(res.width), Int(res.height)], "T_arkit_cam": cm]
            if let cp { fr["conf_png"] = cp.base64EncodedString() }
            var body: [String: Any] = ["agent_id": self.model.agentID, "stream_id": stream, "map_id": self.mapID,
                                       "frames": [fr]]
            // 11.0: the last lock's tile as a geometry-search prior (never a placement)
            if let h = locHint?.body(mapID: self.mapID, now: Date().timeIntervalSince1970) { body["hints"] = h }
            self.send(body, link: link, stream: stream, timeout: timeout,
                      cameraPos: [Double(T.columns.3.x), Double(T.columns.3.y), Double(T.columns.3.z)])
        }
    }

    private func jpeg(_ img: CIImage) -> Data? {
        let w = CGFloat(CaptureFormat.rgbSize.width), h = CGFloat(CaptureFormat.rgbSize.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: w / img.extent.width, y: h / img.extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ci.jpegRepresentation(of: scaled, colorSpace: space, options: [key: 0.8])
    }

    private func send(_ body: [String: Any], link: ServerLink, stream: String, timeout: Double, cameraPos: [Double]) {
        let t0 = CACurrentMediaTime()
        Task { [weak self] in
            var answer: LocalizeAnswer?
            var status = 0
            var err: String?
            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                let (d, s) = try await link.request("POST", "/v1/localize", body: data, timeout: timeout)
                status = s
                if s == 200 { answer = try JSONDecoder().decode(LocalizeAnswer.self, from: d) }
                else { err = JSON.string(JSON.object(d), "detail") ?? "HTTP \(s)" }
            } catch {
                err = error.localizedDescription
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            await MainActor.run {
                guard let self else { return }
                self.inFlight = false
                guard stream == self.streamID else { return }            // the world frame changed meanwhile
                if let a = answer {
                    self.notFound = false
                    self.retryState.succeeded()
                    self.handle(a, roundTripMs: ms, cameraPos: cameraPos)
                } else {
                    if status == 404 { self.notFound = true; self.lastAttempt = self.now + 20 }   // no such map: slow down
                    self.model.log.event("maploc_error", ["status": .int(status), "error": .string(err ?? "?"),
                                                          "ms": .int(Int(ms)), "timeout_s": .double(timeout)])
                    // 10.6.x: never stop — retry after 2, 4, 8, 10 s (a timeout / 503 / 504 = the server warming up)
                    let (d, why) = self.retryState.failed(status: status, error: err, now: self.now)
                    self.model.log.event("maploc_retry", ["n": .int(self.retryState.failures), "delay_s": .double(d),
                                                          "why": .string(why), "locked": .bool(self.alignment != nil)])
                }
                self.publish()
            }
        }
    }

    // MARK: answers

    private func handle(_ a: LocalizeAnswer, roundTripMs: Double, cameraPos: [Double]) {
        // 10.4: a geometry candidate (LiDAR vs the house mesh, waiting for a second agreeing one) is progress too:
        // the room IS in the map, so never "NOT IN MAP" / the slow cadence while geometry is finding you
        if a.anyMatch || a.geometryCandidate { matches += 1 }
        hint = a.locked ? nil : a.hint?.text
        let f = a.frames.first
        model.log.event("maploc_try", ["n": .int(attempts), "locked": .bool(a.locked), "node": .int(f?.node ?? 0),
                                       "inliers": .int(f?.inliers ?? 0), "reason": .string(f?.reason ?? ""),
                                       "event": .string(f?.event ?? ""), "server_ms": .double(a.latencyMs ?? 0),
                                       "rtt_ms": .int(Int(roundTripMs)), "version": .int(a.mapVersion),
                                       "method": .string(a.method ?? ""), "lock_source": .string(a.lockSource ?? ""),
                                       "geo": .string(a.geometry?.last?.reason ?? a.geometry?.state ?? ""),
                                       "hint": .string(a.hint?.code ?? ""), "tile": .string(a.tile ?? ""),
                                       "level": .int(a.level ?? -99), "sigma_cm": .double(a.confidence?.sigmaCm ?? -1),
                                       "sigma_deg": .double(a.confidence?.sigmaDeg ?? -1),
                                       "conf_source": .string(a.confidence?.source ?? ""),
                                       "conf_fixes": .int(a.confidence?.fixes ?? -1),
                                       "srv_visual_ms": .double(a.timingMs?.visual ?? -1),
                                       "srv_icp_ms": .double(a.timingMs?.icp ?? -1),
                                       "lock_rule": .string(a.lockRule ?? "")])
        guard a.locked, let T = a.T_map_arkit else { return }
        if a.anyAccepted || source != "server" { lastFixAt = now }
        if let r = a.bestRmseCm { lastRmseCm = r }
        let next = MapAlignment(mapID: a.mapID, version: a.mapVersion, T: T, at: now,
                                inliers: a.gate?.inliers?.max(), spreadCm: a.gate?.spreadCm, method: a.shownMethod)
        let firstServerLock = source != "server"
        if !firstServerLock { refinements += 1 }
        var cross: (cm: Double, deg: Double)?
        if let cur = alignment, cur.version == next.version || source == "place_cache" {
            cross = cur.delta(next, at: cameraPos)
        }
        let wasCarried = source == "carried"
        alignment = next
        source = "server"
        LastFixStore.put(LastMapFix(mapID: a.mapID, position: next.toMap(arkit: cameraPos), at: now))
        LocHintStore.put(LocHint.from(answer: a.tile, level: a.level, cameraMap: a.cameraMap,
                                      fallbackMap: next.toMap(arkit: cameraPos), mapID: a.mapID, now: now))
        if lockedAt == nil { lockedAt = now }
        if firstServerLock && wasCarried {
            // 10.3: the carried lock confirmed by the server in the new frame (bodies move only if it is > 10 cm off)
            model.log.event("maploc_confirmed", ["cm": .double(cross?.cm ?? -1), "deg": .double(cross?.deg ?? -1),
                                                 "version": .int(a.mapVersion)])
            if let pid = model.placeCtl.activeID { MapFrameCache.put(pid, next) }
            if let pw = placedWith, pw.delta(next, at: cameraPos).cm > Self.realignCm { applyLock(reason: "realign") }
            else if placedWith == nil { applyLock(reason: "server") }
            model.meshMapper.alignmentChanged(next, spreadCm: a.gate?.spreadCm, errCm: errorEstimate)
        } else if firstServerLock {
            lockSeconds = a.timeToLockS ?? (now - streamStart)
            var ev: [String: LogValue] = ["version": .int(a.mapVersion), "seconds": .double(lockSeconds ?? 0),
                                          "attempts": .int(attempts), "session": .string(a.matchedSession ?? ""),
                                          "spread_cm": .double(a.gate?.spreadCm ?? 0),
                                          "yaw_deg": .double(next.yaw * 180 / .pi), "tilt_deg": .double(next.tiltDeg),
                                          "method": .string(next.method ?? ""), "tile": .string(a.tile ?? ""),
                                          "level": .int(a.level ?? -99), "sigma_cm": .double(a.confidence?.sigmaCm ?? -1),
                                          "sigma_deg": .double(a.confidence?.sigmaDeg ?? -1),
                                          "rule": .string(a.lockRule ?? "")]
            if let c = cross { ev["cross_cm"] = .double(c.cm); ev["cross_deg"] = .double(c.deg) }
            model.log.event("maploc_locked", ev)
            model.flash(MapLocText.locked(mapID: a.mapID, version: a.mapVersion, seconds: lockSeconds,
                                          method: next.method), seconds: 3)
            // only a place whose ARKit frame IS this session's (matched / saved here) may cache this alignment
            if let pid = model.placeCtl.activeID { MapFrameCache.put(pid, next) }
            applyLock(reason: "server")
            model.meshMapper.alignmentChanged(next, spreadCm: a.gate?.spreadCm, errCm: errorEstimate)
            model.placeCtl.mapLocked()          // 10.3: cancels a saved map still relocalizing (carries this lock)
        } else {
            if let c = cross { model.log.event("maploc_refine", ["cm": .double(c.cm), "deg": .double(c.deg), "n": .int(refinements)]) }
            if let pw = placedWith, pw.delta(next, at: cameraPos).cm > Self.realignCm {
                model.flash("Re-aligned to the house map", seconds: 2)
                applyLock(reason: "realign")
            }
            if let pid = model.placeCtl.activeID { MapFrameCache.put(pid, next) }
            if cross.map({ $0.cm > 0.5 || $0.deg > 0.1 }) ?? true {
                model.meshMapper.alignmentChanged(next, spreadCm: a.gate?.spreadCm, errCm: errorEstimate)
            }
        }
    }

    /// 10.3: the new session's first frame: carry the old lock into it, place the bodies, confirm with the server.
    private func applyCarry(_ pc: (al: MapAlignment, oldCam: simd_float4x4, lockSeconds: Double?), newCam: simd_float4x4) {
        pendingCarry = nil
        let carried = FrameCarry.carry(pc.al, oldCam: Mat4(columnsMajor: Self.floats(pc.oldCam)),
                                       newCam: Mat4(columnsMajor: Self.floats(newCam)), now: now)
        alignment = carried
        source = "carried"
        lockSeconds = pc.lockSeconds
        lastFixAt = now
        model.log.event("maploc_carried", ["version": .int(carried.version),
                                           "yaw_deg": .double(carried.yaw * 180 / .pi)])
        forceAttempt = true                    // confirm in the new frame right away
        setDepthWanted(true)
        applyLock(reason: "carried")
        publish()
    }

    private static func isRelocalizing(_ t: ARCamera.TrackingState) -> Bool {
        if case .limited(.relocalizing) = t { return true }
        return false
    }

    private static func floats(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    // MARK: bodies in the map frame

    /// Lock (server or cached): fetch the map's entities and decide keep / restore / migrate.
    private func applyLock(reason: String) {
        guard let al = alignment else { return }
        if model.recording {                    // 10.2: the capture owns the budget; bodies follow at Stop
            pendingApply = reason == "realign" ? "realign" : (pendingApply ?? reason)
            return
        }
        let link = model.link!
        let q = [URLQueryItem(name: "version", value: String(al.version))]
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/maps/\(al.mapID)/entities", query: q, timeout: 15)
            await MainActor.run {
                guard let self, self.alignment == al || reason == "realign" else { return }
                guard let r, r.1 == 200, let doc = try? JSONDecoder().decode(MapEntitiesDoc.self, from: r.0) else {
                    self.model.log.event("map_entities_error", ["status": .int(r?.1 ?? 0)])
                    return
                }
                self.dropDeleted(doc.deleted ?? [])
                if reason != "realign", self.migrateOrphans(doc, alignment: al, reason: reason) { return }
                self.reconcile(doc, alignment: al, reason: reason)
            }
        }
    }

    /// 10.3 (P2b migration): animals of saved places — and bodies placed here without a lock — that the map has never
    /// had go into the map one by one (each in its own map version), then the lock is applied again. true = migrating.
    private func migrateOrphans(_ doc: MapEntitiesDoc, alignment al: MapAlignment, reason: String) -> Bool {
        let present = Set(doc.entities.map { $0.id })
        let known = MapKnownIDs.get()
        MapKnownIDs.add(present)
        var list = PlaceMigration.orphans(places: model.placeCtl.store.all, alignments: MapFrameCache.all(),
                                          mapID: al.mapID, present: present, known: known, agentID: model.agentID)
        let dead = MapDeletedIDs.get()
        list.removeAll { migrateTried.contains($0.id) || dead.contains($0.id) }
        var seen = present.union(known).union(migrateTried).union(dead).union(list.map { $0.id })
        let records = model.controller.sim.snapshot()
        for (id, b) in currentBodies() where !seen.contains(id) {
            guard let rec = records.first(where: { $0.id == id }) else { continue }
            seen.insert(id)
            list.append(MapEntity.from(rec, pose: al.mapPose(arkit: b.position, groundYaw: b.yaw), mapVersion: al.version,
                                       agentID: model.agentID, placeID: model.placeCtl.activeID))
        }
        guard !list.isEmpty, !syncing else { return false }
        migrateTried.formUnion(list.map { $0.id })
        syncing = true
        let link = model.link!
        let mapID = al.mapID
        Task { [weak self] in
            var ok: [String] = []
            for e in list {
                guard let body = try? PlaceMigration.putBody(e) else { continue }
                let r = try? await link.request("PUT", "/v1/maps/\(mapID)/entities/\(e.id)", body: body, timeout: 15)
                if r?.1 == 200 { ok.append(e.id) }
            }
            await MainActor.run {
                guard let self else { return }
                self.syncing = false
                MapKnownIDs.add(Set(ok))
                self.model.log.event("map_migrate", ["entities": .int(list.count), "ok": .int(ok.count),
                                                     "places": .string(Set(list.compactMap { $0.placeID }).sorted()
                                                        .joined(separator: ","))])
                if !ok.isEmpty {
                    self.model.flash("Moved \(ok.count) animal\(ok.count == 1 ? "" : "s") into the house map", seconds: 3)
                }
                // apply again: the map now has them (MapKnownIDs stops a second round)
                if self.alignment != nil { self.applyLock(reason: reason == "carried" ? "server" : reason) }
            }
        }
        return true
    }

    private func reconcile(_ doc: MapEntitiesDoc, alignment al: MapAlignment, reason: String) {
        let sim = model.controller.sim
        let current = currentBodies()
        var target: [String: [Double]] = [:]
        for e in doc.entities { target[e.id] = al.arkit(e.pose).position }
        let plan: MapRestorePlan = reason == "realign" ? .restore(reason: "realign")
            : MapRestorePlan.decide(current: current.mapValues { $0.position }, map: target)
        var ev: [String: LogValue] = ["reason": .string(reason), "map": .int(doc.entities.count),
                                      "bodies": .int(current.count), "revision": .int(doc.revision)]
        switch plan {
        case .keep(let cm):
            ev["plan"] = .string("keep")
            ev["max_cm"] = .double(cm)
            sim.gated = false
        case .restore(let why):
            ev["plan"] = .string("restore")
            ev["why"] = .string(why)
            restore(doc.entities, alignment: al)
        case .migrate:
            ev["plan"] = .string("migrate")
            sim.gated = false
            push(reason: "migrate \(model.placeCtl.activeID ?? "session")")
        }
        model.log.event("map_entities_sync", ev)
        placedWith = al
        restoredFromMap = true
        publish()
    }

    /// 10.5 (API §5.9.9): ids the map server deleted (tombstoned) — by this phone in server mode or by any other
    /// client — leave the local sim / saved place too, and are never uploaded again.
    func dropDeleted(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        MapDeletedIDs.add(Set(ids))
        var n = 0
        for id in ids where model.controller.sim.removeBody(uid: id) { n += 1 }
        if n > 0 { model.log.event("map_entities_dropped", ["bodies": .int(n)]) }
    }

    /// Spawn every map entity at its pose in this ARKit session: one named anchor each ("sim.<id>", yaw = the body's
    /// home heading frame), then SimController.restore (records keep their anchor-relative home / pace loop).
    private func restore(_ list: [MapEntity], alignment al: MapAlignment) {
        let session = model.controller.arView.session
        for a in session.currentFrame?.anchors ?? [] where SimEntityRecord.id(fromAnchorName: a.name) != nil {
            session.remove(anchor: a)
        }
        var anchors: [ARAnchor] = []
        var records: [SimEntityRecord] = []
        for e in list {
            let (p, yaw) = al.arkit(e.pose)
            var m = simd_float4x4(simd_quatf(angle: Float(yaw), axis: SIMD3(0, 1, 0)))
            m.columns.3 = SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), 1)
            let a = ARAnchor(name: SimEntityRecord.anchorPrefix + e.id, transform: m)
            session.add(anchor: a)
            anchors.append(a)
            records.append(e.restoreRecord(arkitAnchor: p))
        }
        if !list.isEmpty && !model.simOn { model.simOn = true }
        let sim = model.controller.sim
        sim.gated = false
        let (ok, missing) = sim.restore(records, anchors: anchors)
        model.log.event("map_restore", ["restored": .int(ok), "missing": .int(missing), "version": .int(al.version)])
        if ok > 0 { model.flash("\(ok) sim bod\(ok == 1 ? "y" : "ies") from the house map", seconds: 2.5) }
    }

    /// Current sim bodies: id → (ARKit floor position, anchor ground yaw), from their named anchors.
    private func currentBodies() -> [String: (position: [Double], yaw: Double)] {
        let records = model.controller.sim.snapshot()
        let anchors = model.controller.arView.session.currentFrame?.anchors ?? []
        var out: [String: (position: [Double], yaw: Double)] = [:]
        for r in records {
            var yaw = 0.0
            var p = r.anchor
            if let a = anchors.first(where: { $0.name == r.anchorName }) {
                let m = a.transform
                yaw = atan2(Double(-m.columns.0.z), Double(m.columns.0.x))
                p = [Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z)]
            }
            out[r.id] = (p, yaw)
        }
        return out
    }

    /// 10.5: the local bodies with these ids as map entities (this session's map frame), for the shared sim's import
    /// before it takes over. nil = not locked (no map frame).
    func localEntities(ids: Set<String>) -> (mapID: String, list: [MapEntity])? {
        guard let al = alignment else { return nil }
        let bodies = currentBodies()
        let dead = MapDeletedIDs.get()
        let list = model.controller.sim.snapshot().filter { ids.contains($0.id) && !dead.contains($0.id) }.map { r -> MapEntity in
            let b = bodies[r.id] ?? (position: r.anchor, yaw: 0.0)
            return MapEntity.from(r, pose: al.mapPose(arkit: b.position, groundYaw: b.yaw), mapVersion: al.version,
                                  agentID: model.agentID, placeID: model.placeCtl.activeID)
        }
        return (al.mapID, list)
    }

    /// Sim changed (spawn / move / delete / new order): write the map copy a few seconds later.
    func entitiesChanged() {
        // 10.5: while the shared server sim is in charge it owns the map entities; this phone's local copy is hidden
        // and frozen, and a bulk save of it would undo server-side deletes / moves (owner 10.4.212: the deleted
        // robot came back 6 s later via this PUT).
        guard alignment != nil, restoredFromMap, !model.controller.sim.remoteAuthority else { return }
        syncWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.push(reason: "changed") }
        syncWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.syncDelay, execute: w)
    }

    private func push(reason: String) {
        guard let al = alignment, !syncing, !model.controller.sim.remoteAuthority else { return }
        let dead = MapDeletedIDs.get()
        let records = model.controller.sim.snapshot().filter { !dead.contains($0.id) }
        let bodies = currentBodies()
        let place = model.placeCtl.activeID
        let list = records.map { r -> MapEntity in
            let b = bodies[r.id] ?? (position: r.anchor, yaw: 0.0)
            return MapEntity.from(r, pose: al.mapPose(arkit: b.position, groundYaw: b.yaw), mapVersion: al.version,
                                  agentID: model.agentID, placeID: place)
        }
        guard let body = try? JSONEncoder().encode(MapEntitiesPut(list, agentID: model.agentID, reason: reason)) else { return }
        // 11.2 (plan M4): through the offline edit queue - kept on disk until the server answers, sent with an
        // Idempotency-Key (applied once however often it is resent); a newer whole-set save replaces a queued one
        editQueue.enqueue(EditOp(key: "ss-\(UUID().uuidString)", method: "PUT", path: "/v1/maps/\(al.mapID)/entities",
                                 body: body, created: Date().timeIntervalSince1970, coalesce: "bulk:\(al.mapID)"))
        saveEditQueue()
        pendingPutLog[reason] = (list.count, al.version)
        flushEdits(why: reason)
    }

    // MARK: 11.2 offline edit queue (EditQueue, API §5.13)

    static let editQueueKey = "editqueue.v1"
    private lazy var editQueue = EditQueue.decode(UserDefaults.standard.data(forKey: Self.editQueueKey))
    private var flushing = false
    private var onlineHooked = false
    private var pendingPutLog: [String: (Int, Int)] = [:]

    private func saveEditQueue() {
        UserDefaults.standard.set(editQueue.encoded(), forKey: Self.editQueueKey)
    }

    /// Send queued edits in order until one cannot be delivered (offline / 5xx: kept for the next try).
    func flushEdits(why: String) {
        guard !flushing, !editQueue.isEmpty, let link = model.link else { return }
        if !onlineHooked {
            onlineHooked = true
            Task { await link.whenOnline { [weak self] in DispatchQueue.main.async { self?.flushEdits(why: "online") } } }
        }
        flushing = true
        syncing = true
        Task { [weak self] in
            var sent = 0, conflicts = 0, dropped = 0
            var lastStatus = 0
            var lastRev: Int?
            while let s = self, let op = await MainActor.run(body: { s.editQueue.next }) {
                await MainActor.run { s.editQueue.bumpAttempt(op.key) }
                let r = try? await link.request(op.method, op.path, body: op.body, timeout: 15,
                                                headers: ["Idempotency-Key": op.key])
                lastStatus = r?.1 ?? 0
                switch EditQueue.outcome(status: r?.1) {
                case .done:
                    lastRev = r.flatMap { JSON.int(JSON.object($0.0), "revision") }
                    await MainActor.run { s.editQueue.complete(op.key); s.saveEditQueue() }
                    sent += 1
                    continue
                case .retryLater:
                    break
                case .drop(let why):
                    await MainActor.run {
                        s.editQueue.complete(op.key); s.saveEditQueue()
                        s.model.log.event("edit_dropped", ["path": .string(op.path), "why": .string(why)])
                    }
                    dropped += 1
                    continue
                case .stale:
                    // 409: re-read, re-apply this one change on the current revision (same key)
                    let g = try? await link.request("GET", op.path.components(separatedBy: "/entities").first.map { $0 + "/entities" } ?? op.path,
                                                    query: [URLQueryItem(name: "include", value: "all")], timeout: 15)
                    let obj = g.flatMap { JSON.object($0.0) }
                    let rev = obj.flatMap { JSON.int($0, "revision") }
                    var serverUpdated: Double?
                    if let id = op.entityID, let ents = obj?["entities"] as? [[String: Any]],
                       let e = ents.first(where: { ($0["id"] as? String) == id }) { serverUpdated = e["updated"] as? Double }
                    let conflict = EditQueue.isConflict(op, serverUpdated: serverUpdated)
                    if conflict { conflicts += 1 }
                    guard let rv = rev else { break }
                    await MainActor.run {
                        let cur = s.editQueue.ops.first(where: { $0.key == op.key }) ?? op
                        s.editQueue.replace(EditQueue.rebased(cur, revision: rv)); s.saveEditQueue()
                        s.model.log.event("edit_conflict", ["path": .string(op.path), "revision": .int(rv),
                                                            "theirs_changed": .bool(conflict), "kept": .string("mine")])
                        if conflict { s.model.flash("Map edit conflict: someone changed it too - kept yours", seconds: 4) }
                    }
                    if op.attempts < 3 { continue }
                }
                break
            }
            await MainActor.run {
                guard let self else { return }
                self.flushing = false
                self.syncing = false
                for (reason, (n, ver)) in self.pendingPutLog where sent > 0 {
                    self.model.log.event("map_entities_put", ["reason": .string(reason), "entities": .int(n),
                                                              "status": .int(lastStatus), "revision": .int(lastRev ?? -1),
                                                              "version": .int(ver)])
                    if reason.hasPrefix("migrate") {
                        self.model.flash("Moved \(n) animal\(n == 1 ? "" : "s") into the house map", seconds: 3)
                    }
                }
                if sent > 0 { self.pendingPutLog.removeAll() }
                self.model.log.event("edit_queue_flush", ["why": .string(why), "sent": .int(sent), "left": .int(self.editQueue.count),
                                                          "conflicts": .int(conflicts), "dropped": .int(dropped),
                                                          "status": .int(lastStatus)])
            }
        }
    }

    // MARK: depth + HUD

    private func setDepthWanted(_ on: Bool) {
        guard on != depthWanted else { return }
        depthWanted = on
        // recording / mapping / Live map keep `.sceneDepth` on anyway: re-running the session would change nothing
        let others = model.recording || model.meshMapper.wantsDepth || model.liveStreamer.wantsDepth
        if !others && !model.showScans { model.controller.rerunConfiguration() }
        model.log.event("maploc_depth", ["on": .bool(on)])
    }

    // MARK: 10.2 pill, retry, recording

    /// "NOT IN MAP": no match for a long time, or the server has no such map.
    var isNotInMap: Bool {
        alignment == nil && (notFound || LocPill.notInMap(searchSeconds: searchSeconds, attempts: attempts, matches: matches))
    }

    /// ± cm of the current lock (LocPill.errorEstimate).
    var errorEstimate: Double? {
        guard let al = alignment else { return nil }
        return LocPill.errorEstimate(spreadCm: al.spreadCm, rmseCm: lastRmseCm, method: al.method, source: source)
    }

    /// The pill's "Retry": not locked → a fresh search (new stream, the server's gate starts over); locked → one
    /// refinement attempt now.
    func retry() {
        model.log.event("maploc_retry", ["locked": .bool(alignment != nil), "attempts": .int(attempts)])
        if alignment == nil {
            streamID = Self.newStream()
            streamStart = now
            attempts = 0
            matches = 0
            hint = nil
            notFound = false
        }
        forceAttempt = true
        lastAttempt = 0
        setDepthWanted(true)
        publish()
    }

    /// Recording stopped: a lock that arrived meanwhile places the bodies now.
    func recordingStopped() {
        guard let r = pendingApply else { return }
        pendingApply = nil
        applyLock(reason: r)
    }

    /// 10.6.x: start again NOW (foreground, network back, new map version, AR resumed, Scans closed). The search never
    /// stops while unplaced; this only cuts a backoff wait short.
    func resume(why: String) {
        if why == "foreground" { inBackground = false }
        let waiting = retryState.resume(now: now)
        if alignment == nil { forceAttempt = true }
        if inFlight, now - inFlightSince > 5 { inFlight = false }     // a request cut by the background never answers
        model.log.event("maploc_resume", ["why": .string(why), "locked": .bool(alignment != nil),
                                          "was_waiting": .bool(waiting), "attempts": .int(attempts)])
        publish()
    }

    func enteredBackground() { inBackground = true; publishPill() }

    /// Why no attempt can run right now (the pill says so instead of a stale "finding").
    private var pausedReason: String? {
        if inBackground { return "app in background" }
        if model.showScans { return "Scans open: close it to be placed" }
        if lastFrameAt > 0, now - lastFrameAt > 3 { return "AR paused" }
        return nil
    }

    /// Twice a second (HUD tick): keeps the pill's elapsed seconds / fix age current; network / map-version resumes.
    func tick() {
        let online = model.serverBase != nil
        if online && !wasOnline && attempts > 0 { resume(why: "network") }
        wasOnline = online
        if let v = model.liveBaseVersion, seenVersion != nil, v != seenVersion { resume(why: "map_version") }
        if let v = model.liveBaseVersion { seenVersion = v }
        publishPill()
    }

    private func publishPill() {
        let input = LocPillInput(
            online: model.serverBase != nil,
            phase: isLocked ? .locked : (model.serverBase != nil ? .searching : .off),
            mapID: alignment?.mapID ?? mapID, version: alignment?.version, method: alignment?.method, source: source,
            errCm: errorEstimate, searchSeconds: searchSeconds, attempts: attempts, matches: matches,
            lastFixAge: lastFixAt.map { now - $0 }, trackingCode: model.tracking.code,
            notInMap: isNotInMap, savedPlace: model.placeCtl.note, hint: hint,
            retry: alignment == nil ? retryState.note : nil, paused: alignment == nil ? pausedReason : nil)
        let p = LocPill.make(input)
        if model.locPill != p { model.locPill = p }
    }

    func publish() {
        var s = MapLocState()
        if let al = alignment {
            s.phase = .locked
            s.title = MapLocText.locked(mapID: al.mapID, version: al.version, seconds: lockSeconds,
                                        method: source == "place_cache" || source == "carried" ? nil : al.method)
            s.detail = source == "place_cache" ? "from the saved place · confirming with the map server" :
                source == "carried" ? "re-anchored over an AR reset · confirming with the map server" :
                (al.spreadCm.map { String(format: "fixes agree within %.1f cm", $0) } ?? "")
        } else if model.serverBase != nil {
            s.phase = .searching
            s.title = "FINDING YOU"
            s.detail = MapLocText.searching(mapID: mapID, seconds: now - streamStart, attempts: attempts, matches: matches,
                                            hint: hint)
        }
        if model.mapLoc != s { model.mapLoc = s }
        model.placeCtl.publish()
        publishPill()
    }
}

/// The map alignment each saved place was last seen with (ARKit relocalization puts a session back in the place's
/// frame, so the same T_map_arkit applies at once). Documents/places/mapframes.json; a cache only.
enum MapFrameCache {
    private static var url: URL? { PlaceStore.directory?.appendingPathComponent("mapframes.json") }
    private static var memo: [String: MapAlignment]?

    private static func load() -> [String: MapAlignment] {
        if let m = memo { return m }
        let m = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: MapAlignment].self, from: $0) } ?? [:]
        memo = m
        return m
    }

    static func get(_ place: String) -> MapAlignment? { load()[place] }
    static func all() -> [String: MapAlignment] { load() }

    static func remove(_ place: String) {
        var m = load()
        guard m.removeValue(forKey: place) != nil else { return }
        memo = m
        if let u = url, let d = try? JSONEncoder().encode(m) { try? d.write(to: u, options: .atomic) }
    }

    static func put(_ place: String, _ a: MapAlignment) {
        var m = load()
        m[place] = a
        memo = m
        if let u = url, let d = try? JSONEncoder().encode(m) { try? d.write(to: u, options: .atomic) }
    }
}

/// 11.0: the last lock's tile / level / position, sent as `hints` with every localize request (persisted across launches).
enum LocHintStore {
    private static let key = "snailsight.locHint"
    static func get() -> LocHint? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LocHint.self, from: $0) }
    }
    static func put(_ h: LocHint) {
        if let d = try? JSONEncoder().encode(h) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// 10.3: the last accepted server fix (map frame): the evidence for trying a saved place on the next launch.
enum LastFixStore {
    private static let key = "snailsight.lastMapFix"
    static func get() -> LastMapFix? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastMapFix.self, from: $0) }
    }
    static func put(_ f: LastMapFix) {
        if let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// 10.3: entity ids this phone has seen in the house map (or migrated into it): a body deleted from the map is never
/// resurrected from an old place file. Documents/places/map_known.json.
/// 10.5: ids the map server tombstoned (API §5.9.9), persisted: never re-uploaded by a migration, bulk save or
/// hand-off import, whatever a saved place still holds.
enum MapDeletedIDs {
    private static var url: URL? { PlaceStore.directory?.appendingPathComponent("map_deleted.json") }
    private static var memo: Set<String>?

    static func get() -> Set<String> {
        if let m = memo { return m }
        let m = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        memo = m
        return m
    }

    static func add(_ ids: Set<String>) {
        let cur = get()
        guard !ids.isSubset(of: cur) else { return }
        let m = cur.union(ids)
        memo = m
        if let u = url, let d = try? JSONEncoder().encode(m) { try? d.write(to: u, options: .atomic) }
    }
}

enum MapKnownIDs {
    private static var url: URL? { PlaceStore.directory?.appendingPathComponent("map_known.json") }
    private static var memo: Set<String>?

    static func get() -> Set<String> {
        if let m = memo { return m }
        let m = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        memo = m
        return m
    }

    static func add(_ ids: Set<String>) {
        let cur = get()
        guard !ids.isSubset(of: cur) else { return }
        let m = cur.union(ids)
        memo = m
        if let u = url, let d = try? JSONEncoder().encode(m) { try? d.write(to: u, options: .atomic) }
    }
}
