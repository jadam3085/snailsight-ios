// SnailSight P2a: persistent places (docs/SNAILSIGHT-REFACTOR-PLAN.md §7 P2a), demoted in 10.3 to an accelerator.
//
// One place = one ARWorldMap covering a floor / connected group of rooms; walking into a new room EXTENDS the current map
// and the next save grows the place.
//
// 10.3 master map first (owner on 10.0.105: "Why do I see localized and localizing at the same time? Usually when it's
// like this, I need to select the map again." — a bedroom place was loaded at launch while he stood in the bathroom, so
// ARKit sat in limited/relocalizing, the sim paused and no mesh was built, while the map server had already locked him):
//  - launch / Reset AR run a CLEAN session (tracking normal at once); MapLocalizer finds the phone in the master map;
//  - a saved map is tried only when the server has not locked within 5 s AND the last server fix lies inside that
//    place (PlaceEvidence), and is aborted after 8 s (20 s when picked) — a re-run without the world map;
//  - a server lock cancels a saved map still relocalizing (the lock is carried over the reset: FrameCarry);
//  - saved places' animals are migrated into the master map (PlaceMigration in MapLocalizer).
// Pure rules: SnailSightCore PlaceAssist. Every step is logged (reloc_* / place_*).
import ARKit
import Foundation
import SnailSightCore
import UIKit

/// What the HUD shows about the saved place (AppModel.place): secondary info, never the headline (that is the pill).
struct PlaceHUD: Equatable {
    enum Tone: Equatable { case neutral, working, good, bad }
    var title = "NO SAVED PLACE"
    var detail = ""
    var tone: Tone = .neutral
    var relocalizing = false            // a saved map is being tried (Save place waits)
    var short = "Places"                // the status pill's place word
}

final class PlaceController {
    private unowned let model: AppModel
    let store: PlaceStore
    private(set) var assist = PlaceAssist()
    /// The place this session's ARKit frame belongs to: the one matched, or the one this session was saved as.
    private(set) var activeID: String?
    private var lastSaveAt: TimeInterval = 0
    private var saving = false
    private var autoSaveWork: DispatchWorkItem?
    private var autoSaveTries = 0
    private var restoreWork: DispatchWorkItem?
    private var lastUploadAt: [String: TimeInterval] = [:]
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var launched = false
    private var loading = false            // a map file is being read: tracking changes belong to the old run

    static let restoreDelay = 0.8          // s after a match: let ARKit settle the anchors before re-spawning
    static let autoSaveDelay = 5.0         // s after the last spawn / move / order change
    static let uploadThrottle = 60.0       // s between automatic uploads of the same place

    init(model: AppModel) {
        self.model = model
        let lg = model.services.log
        store = PlaceStore(link: model.services.link) { ev, data in lg.event(ev, data) }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in self?.autoSave(reason: "background")
        })
    }

    private var ar: ARSessionController { model.controller }
    private var now: TimeInterval { Date().timeIntervalSince1970 }

    var activeName: String? { activeID.flatMap { store.manifests[$0]?.name } }
    /// A saved map is being tried (sim waits, Save place waits).
    var isTrying: Bool { assist.isTrying }

    // MARK: launch

    /// First AR run of the app: always a clean session (10.3). Calls `run` exactly once.
    func launch(run: @escaping (ARWorldMap?) -> Void) {
        guard !launched else { return }
        launched = true
        assist.reset(now: now)
        model.log.event("reloc_launch", ["places": .int(store.manifests.count), "mode": .string("master_first")])
        run(nil)
        publish()
        restoreFromServerIfEmpty()
    }

    /// Reinstall: Documents is empty but the map server has the places → fetch them (evidence / migration use them).
    private func restoreFromServerIfEmpty() {
        guard store.manifests.isEmpty else { return }
        store.restoreFromServer { [weak self] n in
            guard let self else { return }
            self.model.log.event("place_restored", ["count": .int(n)])
            self.publish()
        }
    }

    /// Reset AR (or back from Object Capture): a clean session, every place may be tried again.
    func sessionReset() {
        restoreWork?.cancel()
        assist.reset(now: now)
        activeID = nil                                   // the new ARKit frame is not the place's
        model.controller.sim.gated = false
        publish()
    }

    /// Load a map file and re-run the session with it (main thread). A broken file is skipped (logged).
    private func tryPlace(_ id: String, why: String) {
        loading = true
        model.controller.sim.gated = true
        model.controller.sim.removeAllBodies()           // they come back from the place (match) or the house map
        activeID = nil
        restoreWork?.cancel()
        store.loadMap(id) { [weak self] r in
            guard let self else { return }
            self.loading = false
            guard self.assist.isTrying, self.assist.current == id else {     // cancelled / locked while loading
                self.model.controller.sim.gated = false
                return
            }
            switch r {
            case .success(let (m, map)):
                self.assist.runStarted(now: self.now)
                self.model.log.event("reloc_start", ["place": .string(id), "name": .string(m.name), "why": .string(why),
                                                     "map_bytes": .int(m.mapBytes), "entities": .int(m.entities.count),
                                                     "features": .int(map.rawFeaturePoints.points.count),
                                                     "timeout_s": .double(self.assist.timeout(picked: self.assist.isPicked))])
                if !m.entities.isEmpty && !self.model.simOn { self.model.simOn = true }   // models load before restore
                self.ar.runWorldMap(map)
            case .failure(let e):
                self.model.log.event("reloc_load_error", ["place": .string(id), "error": .string(e.localizedDescription)])
                self.model.flash("Saved place \(self.store.manifests[id]?.name ?? id) could not be read: skipped", seconds: 3)
                self.store.forgetLocal(id)                       // the server copy stays (another build may read it)
                _ = self.assist.cancel(now: self.now)            // the session never left the clean run
                self.model.controller.sim.gated = false
            }
            self.publish()
        }
    }

    // MARK: ARKit / localizer callbacks (main)

    func trackingChanged(_ s: TrackingStatus) {
        guard !loading else { return }
        let code = s.code
        if assist.isTrying, code.hasPrefix("limited:") {
            model.log.event("reloc_reason", ["place": .string(assist.current ?? "?"), "reason": .string(code),
                                             "t": .double((assist.elapsed(now: now) * 10).rounded() / 10)])
        }
        handle(assist.tracking(code, now: now))
    }

    /// HUD tick (2 Hz).
    func tick() {
        guard !loading else { return }
        let locked = model.mapLocalizer.isLocked
        var evidence: String?
        if assist.wantsEvidence(now: now, serverLocked: locked), model.controller.sim.entityCount == 0 {
            evidence = PlaceEvidence.candidate(places: store.all, alignments: MapFrameCache.all(),
                                               fix: LastFixStore.get(), now: now)
        }
        handle(assist.tick(now: now, serverLocked: locked, evidence: evidence))
        if assist.isTrying { publish() }
    }

    /// The house map locked this session: a saved map still relocalizing is cancelled at once (10.3).
    func mapLocked() {
        handle(assist.serverLock(now: now))
    }

    private func handle(_ a: PlaceAssistAction) {
        switch a {
        case .none: return
        case .tryPlace(let id):
            let picked = assist.isPicked
            model.log.event("reloc_try", ["place": .string(id), "name": .string(store.manifests[id]?.name ?? "?"),
                                          "picked": .bool(picked),
                                          "why": .string(picked ? "pick" : "evidence")])
            tryPlace(id, why: picked ? "pick" : "evidence")
        case .abort(let id, let reason, let keepLock):
            if reason == "timeout", var m = store.manifests[id] { m.timedOut(); store.update(m) }
            model.log.event("reloc_abort", ["place": .string(id), "reason": .string(reason), "keep_lock": .bool(keepLock),
                                            "last_reason": .string(assist.lastReason),
                                            "saw_relocalizing": .bool(assist.sawRelocalizing)])
            let name = store.manifests[id]?.name ?? id
            if reason == "timeout" {
                model.flash("\(name) not matched: using the house map", seconds: 2.5)
            }
            model.controller.sim.gated = false
            if !loading { ar.runWorldMap(nil, carryLock: keepLock) }    // a load in flight sees the cancel and stops
        case .matched(let id, let secs):
            activeID = id
            var m = store.manifests[id]
            m?.localized(now: now, seconds: secs)
            if let m { store.update(m) }
            model.log.event("reloc_ok", ["place": .string(id), "name": .string(m?.name ?? "?"),
                                         "seconds": .double((secs * 100).rounded() / 100),
                                         "saw_relocalizing": .bool(assist.sawRelocalizing),
                                         "entities": .int(m?.entities.count ?? 0)])
            model.flash(String(format: "Saved place %@ matched (%.1f s)", m?.name ?? "?", secs), seconds: 2.5)
            model.mapLocalizer.worldFrameChanged("place_localized", placeID: id)   // ARKit's origin snapped to the place
            let w = DispatchWorkItem { [weak self] in self?.restoreEntities(id) }
            restoreWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: w)
        }
        publish()
    }

    /// Re-spawn the place's animals at their anchors (now in the right place) and let them move again.
    private func restoreEntities(_ id: String) {
        guard assist.isMatched, assist.current == id, let m = store.manifests[id] else { return }
        let anchors = ar.arView.session.currentFrame?.anchors ?? []
        let sim = model.controller.sim
        sim.gated = false
        if !m.entities.isEmpty && !model.simOn { model.simOn = true }
        let (ok, missing) = sim.restore(m.entities, anchors: anchors)
        model.log.event("place_restore", ["place": .string(id), "restored": .int(ok), "missing": .int(missing),
                                          "anchors": .int(anchors.filter { SimEntityRecord.id(fromAnchorName: $0.name) != nil }.count)])
        if missing > 0 { model.flash("\(missing) saved animal\(missing == 1 ? "" : "s") had no anchor in this map", seconds: 3) }
        publish()
    }

    // MARK: user actions

    /// "Save place": the current place (grown with whatever was mapped since), or a new "Area N".
    func saveNow() { save(reason: "user") }

    func pick(_ id: String) {
        guard let m = store.manifests[id] else { return }
        if assist.isMatched && assist.current == id { model.flash("Already in \(m.name)"); return }
        if model.mapLocalizer.isLocked {
            // the house-map lock is the better fix, and the place's animals are in the house map (migration)
            model.log.event("place_pick", ["place": .string(id), "skipped": .string("map_locked")])
            model.flash("Localized on the house map already: \(m.name)'s animals are in it", seconds: 3)
            return
        }
        saveFirst(reason: "switch") { [weak self] in          // keep what was done here first
            guard let self else { return }
            self.model.log.event("place_pick", ["place": .string(id)])
            self.handle(self.assist.pick(id, now: self.now, serverLocked: self.model.mapLocalizer.isLocked))
            self.model.flash("Loading \(m.name): look around where you saved it", seconds: 3)
        }
    }

    /// Stop trying a saved map (Start Over / Places ▸ Start new place) or leave the current place; the session keeps
    /// running (no reset unless a saved map was loaded) and the next save names a new "Area N".
    func startNew() {
        saveFirst(reason: "switch") { [weak self] in self?.resetToNew() }
    }

    private func resetToNew() {
        let a = assist.cancel(now: now)
        activeID = nil
        model.controller.sim.gated = false
        model.log.event("place_new", ["was_trying": .bool(a != .none)])
        handle(a)                                           // trying: re-run without the world map
        model.flash("New place: Save place keeps this area", seconds: 3)
        publish()
    }

    func rename(_ id: String, to name: String) {
        guard var m = store.manifests[id], let n = PlaceNaming.clean(name) else { return }
        m.name = n
        m.updated = now
        m.version += 1                              // the server copy needs the new name too
        store.update(m)
        model.log.event("place_rename", ["place": .string(id), "name": .string(n)])
        rewriteManifestOnly(id)
        publish()
    }

    func delete(_ id: String) {
        let name = store.manifests[id]?.name ?? id
        store.delete(id)
        if activeID == id { activeID = nil }
        if assist.current == id { handle(assist.cancel(now: now)) }   // trying it: back to a clean run
        MapFrameCache.remove(id)
        model.log.event("place_delete", ["place": .string(id), "name": .string(name)])
        publish()
    }

    /// Rename without a new world map: rewrite the container with the same map bytes.
    private func rewriteManifestOnly(_ id: String) {
        guard let m = store.manifests[id], let url = PlaceStore.fileURL(id),
              let blob = try? Data(contentsOf: url), let decoded = try? PlaceCodec.decode(blob),
              let out = try? PlaceCodec.encode(manifest: m, map: decoded.1) else { return }
        try? out.write(to: url, options: .atomic)
        store.upload(id, reason: "rename")
    }

    // MARK: saving

    /// Sim changed (spawn / move / delete / new behaviour): save a few seconds later, once ARKit has mapped enough.
    func entitiesChanged() {
        model.mapLocalizer.entitiesChanged()              // P2b: the map-frame copy (server) follows every change
        autoSaveWork?.cancel()
        autoSaveTries = 0
        scheduleAutoSave(after: Self.autoSaveDelay)
    }

    private func scheduleAutoSave(after s: Double) {
        let w = DispatchWorkItem { [weak self] in self?.autoSave(reason: "placed") }
        autoSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    /// Automatic save: only when there is something worth keeping, never while relocalizing (that would overwrite a
    /// good map with a half-built one), and only when ARKit says the map is extending / mapped.
    func autoSave(reason: String) {
        guard worthSaving else { return }
        if reason == "placed" && !(model.mapping == "mapped" || model.mapping == "extending") {
            autoSaveTries += 1
            if autoSaveTries <= 6 { scheduleAutoSave(after: 5) }
            return
        }
        if reason == "background" && now - lastSaveAt < 10 { return }
        save(reason: reason)
    }

    /// 10.3: bodies placed while the house map holds a lock live in the house map; only an active place (matched, or
    /// saved by the user) or bodies placed without a lock (offline) are worth a place save.
    private var worthSaving: Bool {
        !assist.isTrying && !model.recording
            && (activeID != nil || (model.controller.sim.entityCount > 0 && !model.mapLocalizer.isLocked))
    }

    /// Save (when there is something to keep) and only then continue: a session re-run right after
    /// getCurrentWorldMap could lose the map.
    private func saveFirst(reason: String, then next: @escaping () -> Void) {
        guard worthSaving, !saving else { next(); return }
        save(reason: reason, done: next)
    }

    private func save(reason: String, done: (() -> Void)? = nil) {
        if assist.isTrying {
            model.flash("Still trying a saved place: wait a few seconds, or Places ▸ Start new place", seconds: 3)
            done?()
            return
        }
        guard !saving else { done?(); return }
        saving = true
        let t0 = CACurrentMediaTime()
        let mapping = model.mapping
        if reason == "background" && bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "snailsight.place") { [weak self] in self?.endBg() }
        }
        let records = model.controller.sim.snapshot()
        ar.arView.session.getCurrentWorldMap { [weak self] map, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let map else {
                    self.saving = false
                    self.endBg()
                    let why = err?.localizedDescription ?? "no map"
                    self.model.log.event("place_save", ["ok": .bool(false), "reason": .string(reason), "error": .string(why),
                                                        "mapping": .string(mapping)])
                    if reason == "user" { self.model.flash("Not saved: look around the room a bit more (\(why))", seconds: 3) }
                    done?()
                    return
                }
                let isNew = self.activeID == nil || self.store.manifests[self.activeID!] == nil
                var m: PlaceManifest
                if !isNew, let cur = self.store.manifests[self.activeID!] {
                    m = cur
                } else {
                    m = PlaceManifest(id: PlaceManifest.newID(),
                                      name: PlaceNaming.nextAreaName(existing: self.store.all.map { $0.name }), now: self.now)
                }
                m.agentID = self.model.agentID
                m.appVersion = self.model.version
                m.saved(now: self.now, mapBytes: 0, entities: records)
                self.store.write(m, map: map) { r in
                    self.saving = false
                    switch r {
                    case .success(let saved):
                        self.activeID = saved.id
                        // the place's frame is now this session's: its cached map alignment must be this session's
                        if let al = self.model.mapLocalizer.alignment { MapFrameCache.put(saved.id, al) }
                        else { MapFrameCache.remove(saved.id) }
                        self.lastSaveAt = self.now
                        let ms = Int((CACurrentMediaTime() - t0) * 1000)
                        self.model.log.event("place_save", [
                            "ok": .bool(true), "place": .string(saved.id), "name": .string(saved.name),
                            "reason": .string(reason), "new": .bool(isNew), "bytes": .int(saved.mapBytes),
                            "entities": .int(records.count), "features": .int(saved.featurePoints ?? 0),
                            "extent": .doubles(saved.mapExtent ?? []), "mapping": .string(mapping), "ms": .int(ms),
                            "version": .int(saved.version)])
                        if reason == "user" || isNew {
                            let mb = Double(saved.mapBytes) / 1_048_576
                            self.model.flash(String(format: "Saved %@ · %ld animal%@ · %.1f MB%@", saved.name, records.count,
                                                    records.count == 1 ? "" : "s", mb,
                                                    saved.mapBytes > PlaceManifest.bigMapBytes ? " (big: new place for the next floor)" : ""),
                                             seconds: 3)
                        }
                        let last = self.lastUploadAt[saved.id] ?? 0
                        if reason == "user" || reason == "background" || reason == "switch" || isNew
                            || self.now - last > Self.uploadThrottle {
                            self.lastUploadAt[saved.id] = self.now
                            self.store.upload(saved.id, reason: reason)
                        }
                    case .failure(let e):
                        self.model.log.event("place_save", ["ok": .bool(false), "reason": .string(reason),
                                                            "error": .string(e.localizedDescription)])
                        if reason == "user" { self.model.flash("Not saved: \(e.localizedDescription)", seconds: 3) }
                    }
                    self.endBg()
                    self.publish()
                    done?()
                }
            }
        }
    }

    private func endBg() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// Server back online: send anything saved offline.
    func online() { store.uploadPending() }

    // MARK: HUD

    /// The saved-place detail for the localization pill / card (nil = none in play).
    var note: SavedPlaceNote? {
        switch assist.phase {
        case .trying(let id, _, let picked):
            return SavedPlaceNote(name: store.manifests[id]?.name ?? id,
                                  state: .trying(seconds: assist.elapsed(now: now), timeout: assist.timeout(picked: picked)))
        case .matched(let id, _):
            return SavedPlaceNote(name: store.manifests[id]?.name ?? id, state: .matched)
        case .clean:
            guard let id = activeID, let m = store.manifests[id] else { return nil }
            return SavedPlaceNote(name: m.name, state: .active)
        }
    }

    func publish() {
        let n = note
        let line = PlaceLine.make(note: n, masterLocked: model.mapLocalizer.isLocked, savedCount: store.manifests.count,
                                  bodies: model.controller.sim.entityCount,
                                  version: activeID.flatMap { store.manifests[$0]?.version })
        var h = PlaceHUD()
        h.title = line.title
        h.detail = line.detail
        h.tone = line.tone == .good ? .good : line.tone == .working ? .working : .neutral
        h.relocalizing = line.trying
        h.short = n?.name ?? (store.manifests.isEmpty ? "No place" : "Places")
        if model.place != h { model.place = h }
        let list = store.all
        if model.places != list { model.places = list }
    }
}
