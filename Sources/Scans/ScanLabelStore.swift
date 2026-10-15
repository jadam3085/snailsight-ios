// 9.8 Scans labels: the rooms and objects of one scene, synced with the map server (docs/SNAILSIGHT-API.md §8.4 rooms —
// the same versioned doc the web viewer edits, §8.6 objects, §8.6a phone labels + corrections), cached on the phone
// (scans/<id>/rooms.json, objects.json) for offline viewing, and published as map-frame labels
// (scans/<id>/labels.json, SnailSightCore.MapLabelSet + Notification .snailsightMapLabels) for the AR / localization side.
// Every write is an operation replayed on the server's newest revision when a PUT answers 409 (someone else saved in
// between), so a phone edit never overwrites the web viewer's work wholesale.
import Foundation
import UIKit
import SnailSightCore

extension Notification.Name {
    /// userInfo `["scene": String, "url": URL]`: scans/<id>/labels.json (MapLabelSet, map frame Z-up) was rewritten.
    static let snailsightMapLabels = Notification.Name("snailsight.mapLabels")
}

@MainActor
final class ScanLabelStore: ObservableObject {
    @Published private(set) var rooms = RoomsDoc()
    @Published private(set) var objects = ObjectsDoc()
    @Published private(set) var areas: [HAArea] = []
    @Published private(set) var loaded = false
    @Published private(set) var saving = false
    /// The P4 objects API is live on this server (`GET .../objects/corrections` answers): corrections and deletes go
    /// through its PATCH / DELETE / merge endpoints (they persist across detection re-runs), never a whole-list PUT.
    @Published private(set) var correctionsAPI = false
    @Published private(set) var mapLabels: [MapLabel] = []
    @Published var error: String?
    @Published var notice: String?

    let item: ScanItem
    private let store: ScanStore
    private let log: DebugLog

    init(item: ScanItem, store: ScanStore, log: DebugLog) {
        self.item = item
        self.store = store
        self.log = log
    }

    /// Labels belong to scenes (a map version or a walk); object scans have none.
    var enabled: Bool { item.type != .object }
    var scene: String { item.id }
    var author: String { "snailsight-" + Identity.agentID }
    private var dir: URL { store.folder(item.id) }
    private var base: String { "/v1/scenes/" + (scene.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scene) }

    // MARK: load

    func load() async {
        guard enabled else { return }
        readCache()
        do {
            async let r = fetchRooms()
            async let o = fetchObjects()
            let (rr, oo) = try await (r, o)
            rooms = rr
            objects = oo
            error = nil
            writeCache()
            log.event("labels_loaded", ["id": .string(scene), "rooms": .int(rr.rooms.count), "objects": .int(oo.objects.count),
                                        "rooms_rev": .int(rr.revision), "objects_rev": .int(oo.revision)])
        } catch {
            self.error = "Labels: \(error.localizedDescription)" + (loaded ? "" : " (showing the copy saved on the phone)")
            log.event("labels_load_failed", ["id": .string(scene), "error": .string(error.localizedDescription)])
        }
        loaded = true
        publish()
        if areas.isEmpty, let (d, s) = try? await store.api("GET", "/v1/ha/areas", timeout: 15), s == 200 {
            areas = HAArea.decodeList(d)
        }
        await probeP4()
    }

    private func probeP4() async {
        let f = await store.features()
        if f.contains("object_corrections") || f.contains("semantic_objects") { correctionsAPI = true; return }
        if let (_, s) = try? await store.api("GET", base + "/objects/corrections", timeout: 10) { correctionsAPI = s == 200 }
    }

    private func fetchRooms() async throws -> RoomsDoc {
        let (d, s) = try await store.api("GET", base + "/rooms")
        guard s == 200 else { throw NetError.http(s, JSON.detail(d)) }
        return try RoomsDoc.decode(d)
    }

    private func fetchObjects() async throws -> ObjectsDoc {
        let (d, s) = try await store.api("GET", base + "/objects")
        guard s == 200 else { throw NetError.http(s, JSON.detail(d)) }
        return try ObjectsDoc.decode(d)
    }

    // MARK: rooms

    /// Apply `op` to the rooms list and save (replayed on the newest revision on 409). true = saved.
    @discardableResult
    func saveRooms(_ what: String, _ op: @escaping (inout [RoomRecord]) -> Void) async -> Bool {
        saving = true
        defer { saving = false }
        for _ in 0..<3 {
            var doc = rooms
            op(&doc.rooms)
            do {
                let (d, s) = try await store.api("PUT", base + "/rooms", body: try doc.putBody())
                if s == 200 {
                    rooms = try RoomsDoc.decode(d)
                    error = nil
                    notice = "Saved: \(what)"
                    writeCache()
                    publish()
                    log.event("rooms_saved", ["id": .string(scene), "what": .string(what), "rev": .int(rooms.revision)])
                    return true
                }
                if s == 409 {
                    rooms = try await fetchRooms()          // someone saved meanwhile: replay this change on theirs
                    log.event("rooms_conflict", ["id": .string(scene), "what": .string(what), "rev": .int(rooms.revision)])
                    continue
                }
                error = "Rooms not saved (\(s)): \(JSON.detail(d))"
                log.event("rooms_save_failed", ["id": .string(scene), "status": .int(s), "error": .string(JSON.detail(d))])
                return false
            } catch {
                self.error = "Rooms not saved: \(error.localizedDescription)"
                log.event("rooms_save_failed", ["id": .string(scene), "error": .string(error.localizedDescription)])
                return false
            }
        }
        error = "Rooms not saved: the server kept changing — try again"
        return false
    }

    @discardableResult
    func upsertRoom(_ r: RoomRecord) async -> Bool {
        await saveRooms("room \(r.name)") { list in
            if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r } else { list.append(r) }
        }
    }

    @discardableResult
    func deleteRoom(_ id: String) async -> Bool {
        let name = rooms.rooms.first { $0.id == id }?.name ?? id
        return await saveRooms("deleted room \(name)") { list in list.removeAll { $0.id == id } }
    }

    // MARK: objects

    /// Apply `op` to the objects list and save (replayed on the newest revision on 409). true = saved.
    @discardableResult
    func saveObjects(_ what: String, _ op: @escaping ([SceneObject]) -> [SceneObject]) async -> Bool {
        saving = true
        defer { saving = false }
        for _ in 0..<3 {
            var doc = objects
            doc.objects = op(doc.objects)
            do {
                let (d, s) = try await store.api("PUT", base + "/objects", body: try doc.putBody())
                if s == 200 {
                    objects = try ObjectsDoc.decode(d)
                    error = nil
                    notice = "Saved: \(what)"
                    writeCache()
                    publish()
                    log.event("objects_saved", ["id": .string(scene), "what": .string(what), "rev": .int(objects.revision)])
                    return true
                }
                if s == 409 {
                    objects = try await fetchObjects()
                    log.event("objects_conflict", ["id": .string(scene), "what": .string(what), "rev": .int(objects.revision)])
                    continue
                }
                error = "Labels not saved (\(s)): \(JSON.detail(d))"
                log.event("objects_save_failed", ["id": .string(scene), "status": .int(s), "error": .string(JSON.detail(d))])
                return false
            } catch {
                self.error = "Labels not saved: \(error.localizedDescription)"
                log.event("objects_save_failed", ["id": .string(scene), "error": .string(error.localizedDescription)])
                return false
            }
        }
        error = "Labels not saved: the server kept changing — try again"
        return false
    }

    // MARK: P4 objects API (§8.6 P4 endpoints) with list-edit fallbacks

    private func q(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))) ?? v }
    private func objPath(_ id: String) -> String { base + "/objects/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id) }

    /// One P4 call with base_revision; 409 → reload and retry once; success → reload the doc. nil = endpoint missing.
    private func p4(_ what: String, _ call: @escaping (Int) async throws -> (Data, Int)) async -> Bool? {
        saving = true
        defer { saving = false }
        for _ in 0..<2 {
            do {
                let (d, s) = try await call(objects.revision)
                if s == 200 || s == 201 {
                    objects = try await fetchObjects()
                    error = nil
                    notice = "Saved: \(what)"
                    writeCache()
                    publish()
                    log.event("objects_corrected", ["id": .string(scene), "what": .string(what), "via": .string("p4"),
                                                    "rev": .int(objects.revision)])
                    return true
                }
                if s == 409 { objects = try await fetchObjects(); continue }
                if s == 404 || s == 405 {
                    log.event("objects_p4_missing", ["id": .string(scene), "what": .string(what), "status": .int(s)])
                    return nil
                }
                error = "Not saved (\(s)): \(JSON.detail(d))"
                log.event("objects_save_failed", ["id": .string(scene), "status": .int(s), "error": .string(JSON.detail(d))])
                return false
            } catch {
                self.error = "Not saved: \(error.localizedDescription)"
                return false
            }
        }
        error = "Not saved: the server kept changing — try again"
        return false
    }

    private func json(_ o: [String: Any?]) -> Data { JSON.body(o.compactMapValues { $0 }) }

    /// A new phone label. P4 server: `POST .../objects` (create, kept across detection runs) when it exists; otherwise the
    /// revisioned list PUT (every field round-trips).
    @discardableResult
    func addLabel(_ o: SceneObject) async -> Bool {
        if correctionsAPI, let enc = try? JSONEncoder().encode(o), let obj = try? JSONSerialization.jsonObject(with: enc) {
            let author = self.author
            let r = await p4("label \(o.displayName)") { rev in
                try await self.store.api("POST", self.base + "/objects",
                                         body: self.json(["object": obj, "author": author, "base_revision": rev]))
            }
            if let r { return r }
        }
        return await saveObjects("label \(o.displayName)") { list in list.filter { $0.id != o.id } + [o] }
    }

    /// Rename (owner name / class), re-class, note. P4: `PATCH .../objects/{id}` (persisted corrections); else a list edit.
    @discardableResult
    func editObject(_ o: SceneObject, name: String?, label: String?, category: ObjectCategory?, note: String?) async -> Bool {
        let now = Date().timeIntervalSince1970, by = author, id = o.id
        if correctionsAPI {
            var body: [String: Any?] = ["author": by]
            if let name, name != (o.name ?? (o.isManual ? o.label : "")) { body["name"] = name }
            if let label, !label.isEmpty, label != o.label { body["label"] = label }
            if let category, category.rawValue != o.category { body["category"] = category.rawValue }
            if let note, note != o.notes { body["note"] = note }
            if body.count == 1 { return true }                         // nothing changed
            let fixed = body
            let r = await p4("edit \(o.displayName)") { rev in
                var b = fixed
                b["base_revision"] = rev
                return try await self.store.api("PATCH", self.objPath(id), body: self.json(b))
            }
            if let r { return r }
        }
        return await saveObjects("edit \(name ?? label ?? o.displayName)") {
            ObjectEdits.edit($0, id: id, name: name, label: label, category: category, notes: note, by: by, now: now)
        }
    }

    /// Delete (a false positive or an old label). P4: `DELETE .../objects/{id}` per object (hidden on re-runs too).
    @discardableResult
    func deleteObjects(_ ids: [String]) async -> Bool {
        let by = author
        if correctionsAPI {
            var all = true
            for id in ids {
                let r = await p4("deleted \(id)") { rev in
                    try await self.store.api("DELETE", self.objPath(id) + "?author=\(self.q(by))&base_revision=\(rev)")
                }
                if r == nil { all = false; break }
                if r == false { return false }
            }
            if all { return true }
        }
        let set = Set(ids)
        let c = ObjectCorrection(op: "delete", ids: ids, by: by, at: Date().timeIntervalSince1970)
        log.event("objects_delete_list", ["id": .string(scene), "ids": .string(c.ids.joined(separator: ","))])
        return await saveObjects("deleted \(ids.count)") { ObjectEdits.delete($0, ids: set) }
    }

    /// Merge duplicates into `into`. P4: `POST .../objects/merge` (`ids[0]` is kept); else the list merge.
    @discardableResult
    func mergeObjects(_ ids: [String], into: String) async -> Bool {
        let by = author, now = Date().timeIntervalSince1970
        let ordered = [into] + ids.filter { $0 != into }
        if correctionsAPI {
            let r = await p4("merged \(ordered.count)") { rev in
                try await self.store.api("POST", self.base + "/objects/merge",
                                         body: self.json(["ids": ordered, "author": by, "base_revision": rev]))
            }
            if let r { return r }
        }
        return await saveObjects("merged \(ordered.count)") { ObjectEdits.merge($0, ids: ordered, into: into, by: by, now: now) }
    }

    // MARK: photos (full size on the phone, a small thumbnail in the label's attributes)

    func savePhoto(_ img: UIImage, for id: String) -> String? {
        let pdir = dir.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        if let full = img.resized(maxSide: 1600).jpegData(compressionQuality: 0.8) {
            try? full.write(to: pdir.appendingPathComponent("\(id).jpg"), options: .atomic)
        }
        return img.resized(maxSide: 160).jpegData(compressionQuality: 0.6)?.base64EncodedString()
    }

    func photo(for o: SceneObject) -> UIImage? {
        let f = dir.appendingPathComponent("photos/\(o.id).jpg")
        if let img = UIImage(contentsOfFile: f.path) { return img }
        if let b = o.photoThumbBase64, let d = Data(base64Encoded: b) { return UIImage(data: d) }
        return nil
    }

    // MARK: cache + map labels

    private func readCache() {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("rooms.json")), let r = try? RoomsDoc.decode(d) { rooms = r }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("objects.json")), let o = try? ObjectsDoc.decode(d) { objects = o }
        publish(write: false)
    }

    private func writeCache() {
        let e = JSONEncoder()
        if let d = try? e.encode(rooms) { try? d.write(to: dir.appendingPathComponent("rooms.json"), options: .atomic) }
        if let d = try? e.encode(objects) { try? d.write(to: dir.appendingPathComponent("objects.json"), options: .atomic) }
    }

    private func publish(write: Bool = true) {
        let set = MapLabels.build(scene: scene, rooms: rooms, objects: objects, defaultFloorZ: item.floorZ)
        mapLabels = set.labels
        guard write else { return }
        let url = dir.appendingPathComponent("labels.json")
        if let d = try? JSONEncoder().encode(set) { try? d.write(to: url, options: .atomic) }
        NotificationCenter.default.post(name: .snailsightMapLabels, object: nil, userInfo: ["scene": scene, "url": url])
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let s = max(size.width, size.height)
        guard s > maxSide, s > 0 else { return self }
        let k = maxSide / s
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
