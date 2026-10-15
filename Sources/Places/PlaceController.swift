// SnailSight P2a: persistent places + relocalization across launches (docs/SNAILSIGHT-REFACTOR-PLAN.md §7 P2a).
//
// One place = one ARWorldMap covering a floor / connected group of rooms (design choice (a), plan §7 P2a): walking
// into a new room EXTENDS the current map and the next save grows the place; animals in different rooms live in the
// same map. A separate floor or a far-away area is its own place, switched with "Places ▸ load" (a session re-run).
//
// Launch: rank the saved places (PlaceRanking), load the first as `initialWorldMap`; the sim stays hidden while
// RELOCALIZING; ARKit's "normal" after that = LOCALIZED → the place's animals re-spawn at their anchors and resume
// their behaviour. No lock within RelocTracker.timeout (20 s) → the next candidate (a session re-run), cycling;
// the user can pick a place or start a new one at any time. Every step is logged (reloc_* / place_*).
import ARKit
import Foundation
import SnailSightCore
import UIKit

/// What the HUD shows about the place (AppModel.place).
struct PlaceHUD: Equatable {
    enum Tone: Equatable { case neutral, working, good, bad }
    var title = "NEW PLACE"
    var detail = "Spawn animals, then Save place"
    var tone: Tone = .neutral
    var relocalizing = false
}

final class PlaceController {
    private unowned let model: AppModel
    let store: PlaceStore
    private(set) var tracker = RelocTracker()
    /// The place this session belongs to: the one localized into, or the one a fresh session was saved as.
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
    private var tries = 0
    private var loading = false            // a map file is being read: tracking changes belong to the old run

    static let restoreDelay = 0.8          // s after LOCALIZED: let ARKit settle the anchors before re-spawning
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

    // MARK: launch

    /// First AR run of the app: relocalize into the most likely saved place, else start fresh. Calls `run` exactly once.
    func launch(run: @escaping (ARWorldMap?) -> Void) {
        guard !launched else { return }
        launched = true
        let order = PlaceRanking.order(store.all)
        model.log.event("reloc_launch", ["places": .int(store.manifests.count), "order": .string(order.joined(separator: ","))])
        guard let first = tracker.begin(candidates: order, now: now) else {
            run(nil)
            publish()
            restoreFromServerIfEmpty()
            return
        }
        load(first, why: "launch") { map in run(map) }
    }

    /// Reinstall: Documents is empty but the map server has the places → fetch them and start relocalizing.
    private func restoreFromServerIfEmpty() {
        guard store.manifests.isEmpty else { return }
        store.restoreFromServer { [weak self] n in
            guard let self, n > 0, self.activeID == nil, self.model.controller.sim.entityCount == 0,
                  case .fresh = self.tracker.phase else { return }
            self.model.flash("Restored \(n) saved place\(n == 1 ? "" : "s") from the map server: relocalizing", seconds: 4)
            self.beginRelocalization(reason: "restored")
        }
    }

    /// Rank and try the saved places from the top (after Reset AR or a server restore).
    func beginRelocalization(reason: String) {
        let order = PlaceRanking.order(store.all)
        guard let first = tracker.begin(candidates: order, now: now) else { publish(); return }
        model.log.event("reloc_restart", ["reason": .string(reason), "order": .string(order.joined(separator: ","))])
        switchTo(first, why: reason)
    }

    /// Load a map file and hand it over (main thread). A broken file is skipped (logged) and the next one tried.
    private func load(_ id: String, why: String, then: @escaping (ARWorldMap?) -> Void) {
        tries += 1
        loading = true
        model.controller.sim.gated = true
        restoreWork?.cancel()
        store.loadMap(id) { [weak self] r in
            guard let self else { return }
            self.loading = false
            switch r {
            case .success(let (m, map)):
                self.tracker.runStarted(now: self.now)          // the 20 s and time-to-localize start with the run
                self.model.log.event("reloc_start", ["place": .string(id), "name": .string(m.name), "why": .string(why),
                                                     "candidates": .int(self.tracker.candidates.count),
                                                     "index": .int(self.tracker.index), "round": .int(self.tracker.rounds),
                                                     "map_bytes": .int(m.mapBytes), "entities": .int(m.entities.count),
                                                     "features": .int(map.rawFeaturePoints.points.count)])
                // P2b: switch the sim on (hidden: gated) while relocalizing, so the animal models are loaded BEFORE
                // the restore. 9.7 turned it on only at restore time; the bodies were spawned before their USDZ
                // templates arrived and, with the sim frozen (thermal serious), never drew - only their shadows did.
                if !m.entities.isEmpty && !self.model.simOn { self.model.simOn = true }
                then(map)
            case .failure(let e):
                self.model.log.event("reloc_load_error", ["place": .string(id), "error": .string(e.localizedDescription)])
                self.model.flash("Saved place \(self.store.manifests[id]?.name ?? id) could not be read: skipped", seconds: 3)
                self.store.forgetLocal(id)                       // the server copy stays (another build may read it)
                if let next = self.tracker.begin(candidates: PlaceRanking.order(self.store.all), now: self.now) {
                    self.load(next, why: "skip_broken", then: then)
                } else {
                    self.model.controller.sim.gated = false
                    then(nil)
                }
            }
            self.publish()
        }
    }

    /// Re-run the session with another place's map (tracking + anchors + mesh reset; sim bodies cleared until it
    /// localizes and restores them).
    private func switchTo(_ id: String, why: String) {
        model.controller.sim.removeAllBodies()
        activeID = nil
        load(id, why: why) { [weak self] map in
            self?.ar.runWorldMap(map)
        }
    }

    // MARK: ARKit callbacks (main)

    func trackingChanged(_ s: TrackingStatus) {
        guard !loading else { return }
        let code = s.code
        if tracker.isRelocalizing, code.hasPrefix("limited:") {
            model.log.event("reloc_reason", ["place": .string(tracker.current ?? "?"), "reason": .string(code),
                                             "t": .double((tracker.elapsed(now: now) * 10).rounded() / 10)])
        }
        handle(tracker.tracking(code, now: now))
    }

    /// HUD tick (2 Hz).
    func tick() {
        guard !loading else { return }
        handle(tracker.tick(now: now))
        if tracker.isRelocalizing { publish() }
    }

    private func handle(_ a: RelocAction) {
        switch a {
        case .none: return
        case .localized(let id, let secs):
            activeID = id
            var m = store.manifests[id]
            m?.localized(now: now, seconds: secs)
            if let m { store.update(m) }
            model.log.event("reloc_ok", ["place": .string(id), "name": .string(m?.name ?? "?"),
                                         "seconds": .double((secs * 100).rounded() / 100), "tries": .int(tries),
                                         "rounds": .int(tracker.rounds), "saw_relocalizing": .bool(tracker.sawRelocalizing),
                                         "entities": .int(m?.entities.count ?? 0)])
            tries = 0
            model.flash(String(format: "LOCALIZED in %@ (%.1f s)", m?.name ?? "saved place", secs), seconds: 3)
            model.mapLocalizer.worldFrameChanged("place_localized", placeID: id)   // ARKit's origin snapped to the place
            let w = DispatchWorkItem { [weak self] in self?.restoreEntities(id) }
            restoreWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: w)
        case .tryNext(let next, let failed):
            if var m = store.manifests[failed] { m.timedOut(); store.update(m) }
            model.log.event("reloc_timeout", ["place": .string(failed), "after_s": .double(RelocTracker.timeout),
                                              "last_reason": .string(tracker.lastReason), "next": .string(next),
                                              "round": .int(tracker.rounds)])
            model.flash("Not \(store.manifests[failed]?.name ?? failed)? Trying \(store.manifests[next]?.name ?? next)…",
                        seconds: 2.5)
            switchTo(next, why: "timeout")
        }
        publish()
    }

    /// Re-spawn the place's animals at their anchors (now in the right place) and let them move again.
    private func restoreEntities(_ id: String) {
        guard tracker.isLocalized, tracker.current == id, let m = store.manifests[id] else { return }
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

    /// P2b: the house map locked this session. A saved place still relocalizing must not be swapped out by the 20 s
    /// timeout any more (that re-runs the session and drops the lock): keep it running, so ARKit can still snap into it.
    func mapLocked() {
        guard tracker.isRelocalizing, !tracker.pinned else { return }
        tracker.pinned = true
        model.log.event("reloc_pinned", ["place": .string(tracker.current ?? "?"), "why": .string("map_locked")])
        publish()
    }

    // MARK: user actions

    /// "Save place": the current place (grown with whatever was mapped since), or a new "Area N".
    func saveNow() { save(reason: "user") }

    func pick(_ id: String) {
        guard store.manifests[id] != nil else { return }
        if tracker.isLocalized && tracker.current == id { model.flash("Already in \(store.manifests[id]!.name)"); return }
        saveFirst(reason: "switch") { [weak self] in          // keep what was done here first
            guard let self, let m = self.store.manifests[id] else { return }
            self.tracker.pick(id, now: self.now)
            self.model.log.event("place_pick", ["place": .string(id)])
            self.switchTo(id, why: "pick")
            self.model.flash("Loading \(m.name): look around where you saved it", seconds: 3)
        }
    }

    /// Stop relocalizing (or leave the current place) and start an empty one; the next save names it "Area N".
    func startNew() {
        saveFirst(reason: "switch") { [weak self] in self?.resetToNew() }
    }

    private func resetToNew() {
        tracker.startFresh()
        activeID = nil
        model.controller.sim.removeAllBodies()
        model.controller.sim.gated = false
        ar.runWorldMap(nil)
        model.log.event("place_new")
        model.flash("New place: spawn animals, then Save place", seconds: 3)
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
        if tracker.current == id {                     // keep the session; the next save makes a new place
            tracker.startFresh()
            model.controller.sim.gated = false
        }
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

    private var worthSaving: Bool {
        !tracker.isRelocalizing && !model.recording && (activeID != nil || model.controller.sim.entityCount > 0)
    }

    /// Save (when there is something to keep) and only then continue: a session re-run right after
    /// getCurrentWorldMap could lose the map.
    private func saveFirst(reason: String, then next: @escaping () -> Void) {
        guard worthSaving, !saving else { next(); return }
        save(reason: reason, done: next)
    }

    private func save(reason: String, done: (() -> Void)? = nil) {
        if tracker.isRelocalizing {
            model.flash("Still relocalizing: wait for LOCALIZED, or Places ▸ Start new place", seconds: 3)
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

    /// P2b: the house-map lock is the headline once it exists ("LOCALIZED · whole house v7 · 1.8 s"); the place line
    /// moves to the detail. While the map is still searching the place state stays the headline.
    static func merge(_ place: PlaceHUD, map: MapLocState, placeLocalized: Bool) -> PlaceHUD {
        var h = place
        switch map.phase {
        case .off:
            break
        case .locked:
            h.title = map.title
            let p = place.title.hasPrefix("NEW PLACE") ? "" : place.title.replacingOccurrences(of: "LOCALIZED · ", with: "place ")
            h.detail = [map.detail, p].filter { !$0.isEmpty }.joined(separator: " · ")
            h.tone = .good
            h.relocalizing = false
        case .searching:
            if !place.relocalizing && !placeLocalized && place.title.hasPrefix("NEW PLACE") {
                h.title = map.title
                h.detail = map.detail
                h.tone = .working
            } else {
                h.detail = place.detail + " · " + map.detail
            }
        }
        return h
    }

    func publish() {
        var h = PlaceHUD()
        switch tracker.phase {
        case .relocalizing(let id, _):
            let name = store.manifests[id]?.name ?? id
            let t = Int(tracker.elapsed(now: now))
            h.title = "RELOCALIZING · \(name) · \(t) s"
            var d = "Go to where you saved it and look around slowly"
            if tracker.candidates.count > 1 && !tracker.pinned {
                d += " · try \(tracker.index + 1)/\(tracker.candidates.count)"
            }
            if !tracker.lastReason.isEmpty && tracker.lastReason != "relocalizing" { d += " · \(tracker.lastReason)" }
            h.detail = d
            h.tone = .working
            h.relocalizing = true
        case .localized(let id, let secs):
            let m = store.manifests[id]
            h.title = String(format: "LOCALIZED · %@ · %.1f s", m?.name ?? id, secs)
            let n = model.controller.sim.entityCount
            h.detail = "\(n) sim bod\(n == 1 ? "y" : "ies") here · Save place keeps changes"
            h.tone = .good
        case .fresh:
            if let id = activeID, let m = store.manifests[id] {
                h.title = "PLACE · \(m.name)"
                h.detail = "Saved v\(m.version) · \(m.entities.count) animal\(m.entities.count == 1 ? "" : "s")"
                h.tone = .good
            } else {
                h.title = store.manifests.isEmpty ? "NEW PLACE" : "NEW PLACE (not saved)"
                h.detail = "Spawn animals, then Save place"
            }
        }
        h = Self.merge(h, map: model.mapLoc, placeLocalized: tracker.isLocalized)
        if model.place != h { model.place = h }
        let list = store.all
        if model.places != list { model.places = list }
    }
}
