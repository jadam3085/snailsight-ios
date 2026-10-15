// SnailSight P2a saved places on the phone: Documents/places/<place_id>.sswm (PlaceCodec container = place.json +
// ARWorldMap archive) plus an index of the manifests, and the copy on the map server
// (`POST/GET /v1/agents/{id}/worldmaps/...`, docs/SNAILSIGHT-API.md §2.2) so a reinstall or another phone gets them back.
// Visible in Files (On My iPhone ▸ SnailSight ▸ places) like the logs.
import ARKit
import Foundation
import SnailSightCore

final class PlaceStore {
    private let link: ServerLink
    private let log: (String, [String: LogValue]) -> Void
    private let io = DispatchQueue(label: "snailsight.places", qos: .utility)
    /// Manifests by place id (main thread).
    private(set) var manifests: [String: PlaceManifest] = [:]

    static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("places")
    }

    init(link: ServerLink, log: @escaping (String, [String: LogValue]) -> Void) {
        self.link = link
        self.log = log
        loadIndex()
    }

    private static var indexURL: URL? { directory?.appendingPathComponent("index.json") }
    static func fileURL(_ id: String) -> URL? { directory?.appendingPathComponent("\(id).sswm") }

    private func loadIndex() {
        guard let dir = Self.directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let u = Self.indexURL, let d = try? Data(contentsOf: u),
           let list = try? JSONDecoder().decode([PlaceManifest].self, from: d) {
            for m in list where Self.fileURL(m.id).map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                manifests[m.id] = m
            }
        }
    }

    private func saveIndex() {
        guard let u = Self.indexURL, let d = try? JSONEncoder().encode(Array(manifests.values)) else { return }
        try? d.write(to: u, options: .atomic)
    }

    var all: [PlaceManifest] { manifests.values.sorted { $0.lastUsed > $1.lastUsed } }

    func update(_ m: PlaceManifest) {
        manifests[m.id] = m
        saveIndex()
    }

    // MARK: world map <-> file

    /// Archive the world map (mesh anchors stripped: the scene mesh rebuilds live and would only bloat the file) and
    /// write the container. Completion on main with the bytes written.
    func write(_ manifestIn: PlaceManifest, map: ARWorldMap, done: @escaping (Result<PlaceManifest, Error>) -> Void) {
        map.anchors = map.anchors.filter { !($0 is ARMeshAnchor) }
        var m = manifestIn
        m.featurePoints = map.rawFeaturePoints.points.count
        m.mapCenter = [Double(map.center.x), Double(map.center.y), Double(map.center.z)]
        m.mapExtent = [Double(map.extent.x), Double(map.extent.y), Double(map.extent.z)]
        io.async {
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                if data.count > PlaceManifest.maxMapBytes {
                    throw NSError(domain: "snailsight.places", code: 413, userInfo: [NSLocalizedDescriptionKey:
                        "map too big (\(data.count / 1_048_576) MB): start a new place for the next floor"])
                }
                m.mapBytes = data.count
                let blob = try PlaceCodec.encode(manifest: m, map: data)
                guard let url = Self.fileURL(m.id) else { throw CocoaError(.fileNoSuchFile) }
                try blob.write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self.update(m)
                    done(.success(m))
                }
            } catch {
                DispatchQueue.main.async { done(.failure(error)) }
            }
        }
    }

    /// Load a place's world map (background), completion on main.
    func loadMap(_ id: String, done: @escaping (Result<(PlaceManifest, ARWorldMap), Error>) -> Void) {
        io.async {
            do {
                guard let url = Self.fileURL(id) else { throw CocoaError(.fileNoSuchFile) }
                let (m, bytes) = try PlaceCodec.decode(try Data(contentsOf: url))
                guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                DispatchQueue.main.async { done(.success((m, map))) }
            } catch {
                DispatchQueue.main.async { done(.failure(error)) }
            }
        }
    }

    /// Remove the phone's copy only (an unreadable file); the map server keeps its versions.
    func forgetLocal(_ id: String) {
        manifests[id] = nil
        saveIndex()
        if let u = Self.fileURL(id) { try? FileManager.default.removeItem(at: u) }
    }

    /// User delete: the phone copy goes, the server hides its copy (recoverable there, API §2.2).
    func delete(_ id: String) {
        forgetLocal(id)
        let lk = link
        Task { _ = try? await lk.request("DELETE", "/v1/agents/\(Identity.agentID)/worldmaps/\(id)") }
    }

    // MARK: server copy

    /// Upload the place file (latest local version). Updates `uploaded` / `serverVersion` on success.
    func upload(_ id: String, reason: String) {
        guard let url = Self.fileURL(id), manifests[id] != nil else { return }
        let lk = link, lg = log
        let localVersion = manifests[id]?.version ?? 0
        Task {
            let t0 = Date()
            do {
                let blob = try Data(contentsOf: url)
                let (d, status) = try await lk.request("POST", "/v1/agents/\(Identity.agentID)/worldmaps/\(id)", body: blob,
                                                       contentType: PlaceCodec.contentType, timeout: 180)
                let o = JSON.object(d)
                guard status == 200 else { throw NetError.http(status, JSON.detail(d)) }
                let sv = JSON.int(o, "version")
                await MainActor.run {
                    if var m = self.manifests[id] {
                        m.serverVersion = sv
                        m.uploaded = localVersion
                        self.update(m)
                    }
                    lg("place_upload", ["place": .string(id), "ok": .bool(true), "version": .int(sv ?? -1),
                                        "bytes": .int(blob.count), "reason": .string(reason),
                                        "ms": .int(Int(Date().timeIntervalSince(t0) * 1000)),
                                        "dedup": .bool((o["dedup"] as? Bool) ?? false)])
                }
            } catch {
                lg("place_upload", ["place": .string(id), "ok": .bool(false), "reason": .string(reason),
                                    "error": .string(error.localizedDescription)])
            }
        }
    }

    /// Anything saved while offline goes up when the server is back.
    func uploadPending() {
        for m in manifests.values where m.needsUpload { upload(m.id, reason: "pending") }
    }

    /// Reinstall / new phone: nothing local → fetch every place the map server has (all agents: a reinstall gets a new
    /// agent id). Completion on main with the number restored.
    func restoreFromServer(done: @escaping (Int) -> Void) {
        let lk = link, lg = log
        Task {
            var n = 0
            do {
                let (d, st) = try await lk.request("GET", "/v1/worldmaps", timeout: 20)
                guard st == 200, let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else {
                    throw NetError.http(st, JSON.detail(d))
                }
                for row in list.prefix(12) {
                    guard let agent = row["agent_id"] as? String, let pid = row["place_id"] as? String,
                          PlaceManifest.isValidID(pid) else { continue }
                    let (blob, s2) = try await lk.request("GET", "/v1/agents/\(agent)/worldmaps/\(pid)/versions/latest",
                                                          timeout: 180)
                    guard s2 == 200, let decoded = try? PlaceCodec.decode(blob), decoded.0.id == pid,
                          let url = Self.fileURL(pid) else { continue }
                    var m = decoded.0
                    try blob.write(to: url, options: .atomic)
                    m.uploaded = m.version
                    let mm = m
                    await MainActor.run { if self.manifests[pid] == nil { self.update(mm) } }
                    n += 1
                }
                lg("places_restored", ["count": .int(n), "listed": .int(list.count)])
            } catch {
                lg("places_restored", ["count": .int(n), "error": .string(error.localizedDescription)])
            }
            let total = n
            await MainActor.run { done(total) }
        }
    }
}
