// 9.6 Scans screen data: the server's phone catalogue (`GET /v1/phone/scans`, docs/SNAILSIGHT-API.md §8.9), thumbnails,
// downloads of mesh.usdz / the phone splat / walk points, and the offline cache (Application Support/scans/<id>/;
// the last viewed scan is never evicted, others LRU above 600 MB — SnailSightCore.ScanCachePolicy).
import Foundation
import SwiftUI
import UIKit
import SnailSightCore

/// What a downloaded scan has on the phone.
struct CachedScan: Codable {
    var item: ScanItem
    var meshFile: String?          // file names inside the scan folder
    var splatFile: String?
    var splatCount: Int?
    var viewsFile: String?
    var bytes: Int
    var lastUsed: Double
}

@MainActor
final class ScanStore: ObservableObject {
    @Published var items: [ScanItem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var offline = false                  // showing the cached catalogue
    @Published var thumbs: [String: UIImage] = [:]
    @Published private(set) var cached: [String: CachedScan] = [:]

    private let link: ServerLink
    private let log: DebugLog
    private let fm = FileManager.default
    private let session: URLSession
    private var thumbLoading = Set<String>()
    static let lastViewedKey = "snailsight.scans.last_viewed"

    init(link: ServerLink, log: DebugLog) {
        self.link = link
        self.log = log
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 30 * 60
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        loadIndex()
    }

    var sections: [ScanCatalog.Section] { ScanCatalog.sections(items) }
    var lastViewedID: String? { UserDefaults.standard.string(forKey: Self.lastViewedKey) }

    // MARK: folders

    var root: URL {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let r = base.appendingPathComponent("scans", isDirectory: true)
        try? fm.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }

    func folder(_ id: String) -> URL {
        let f = root.appendingPathComponent(ScanCachePolicy.folderName(id), isDirectory: true)
        try? fm.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var catalogURL: URL { root.appendingPathComponent("catalog.json") }

    private func loadIndex() {
        if let d = try? Data(contentsOf: indexURL), let c = try? JSONDecoder().decode([String: CachedScan].self, from: d) {
            cached = c
        }
    }

    private func saveIndex() {
        if let d = try? JSONEncoder().encode(cached) { try? d.write(to: indexURL, options: .atomic) }
    }

    // MARK: catalogue

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let (data, status) = try await link.request("GET", "/v1/phone/scans", timeout: 20)
            guard status == 200 else { throw NetError.http(status, JSON.detail(data)) }
            items = try ScanCatalog.decode(data)
            offline = false
            error = nil
            try? data.write(to: catalogURL, options: .atomic)
            log.event("scans_list", ["items": .int(items.count)])
        } catch {
            // offline: the last catalogue we saw (only cached scans can open)
            if let d = try? Data(contentsOf: catalogURL), let it = try? ScanCatalog.decode(d) { items = it }
            else { items = cached.values.map(\.item) }
            offline = true
            self.error = "Offline: \(error.localizedDescription). Showing saved scans."
            log.event("scans_list_failed", ["error": .string(error.localizedDescription)])
        }
    }

    func base() async -> String? { await link.probe() }

    /// One API call against the map server (9.8 labels: rooms / objects / HA areas). (body, HTTP status).
    func api(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 20) async throws -> (Data, Int) {
        try await link.request(method, path, body: body, timeout: timeout)
    }

    /// `GET /v1` `features` (e.g. `object_corrections` once the P4 corrections endpoint is live). Empty offline.
    func features() async -> Set<String> {
        guard let (d, s) = try? await link.request("GET", "/v1", timeout: 8), s == 200,
              let f = JSON.object(d)["features"] as? [String] else { return [] }
        return Set(f)
    }

    func url(_ rel: String) async -> URL? {
        if rel.hasPrefix("http") { return URL(string: rel) }
        guard let b = await base() else { return nil }
        return URL(string: b + rel)
    }

    /// Re-read one item (mesh build progress).
    func fetch(_ id: String) async throws -> ScanItem {
        let path = "/v1/phone/scans/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        let (data, status) = try await link.request("GET", path, timeout: 15)
        guard status == 200 else { throw NetError.http(status, JSON.detail(data)) }
        let it = try ScanCatalog.decodeItem(data)
        if let i = items.firstIndex(where: { $0.id == it.id }) { items[i] = it }
        return it
    }

    /// Ask the map server to build the phone mesh (idempotent).
    func prepare(_ id: String) async {
        let path = "/v1/phone/scans/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/prepare"
        let r = try? await link.request("POST", path, body: Data("{}".utf8), timeout: 15)
        log.event("scan_prepare", ["id": .string(id), "status": .int(r?.1 ?? 0)])
    }

    // MARK: thumbnails (memory + disk)

    func thumb(for it: ScanItem) {
        guard thumbs[it.id] == nil, !thumbLoading.contains(it.id) else { return }
        let f = folder(it.id).appendingPathComponent("thumb.jpg")
        if let img = UIImage(contentsOfFile: f.path) { thumbs[it.id] = img }
        guard let rel = it.thumbURL, !offline else { return }
        thumbLoading.insert(it.id)
        Task {
            defer { thumbLoading.remove(it.id) }
            guard let u = await url(rel), let res = try? await session.data(from: u),
                  (res.1 as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: res.0) else { return }
            let d = res.0
            try? d.write(to: f, options: .atomic)
            thumbs[it.id] = img
        }
    }

    // MARK: downloads

    enum Part: String { case mesh, splat, views }

    /// Local file for a part of a scan, downloading it when missing or stale. `progress` 0…1 on the main actor.
    /// Splat: only the first `maxSplats` records are fetched (HTTP Range; the server orders them by importance).
    func file(_ it: ScanItem, _ part: Part, maxSplats: Int = 0,
              progress: @escaping (Double) -> Void) async throws -> (URL, Int?) {
        let dir = folder(it.id)
        var entry = cached[it.id] ?? CachedScan(item: it, bytes: 0, lastUsed: Date().timeIntervalSince1970)
        let name: String, rel: String
        var rangeBytes: Int? = nil
        switch part {
        case .mesh:
            // the saved copy wins offline, while a rebuild is under way (no URL) and when the size is unchanged
            if let have = entry.meshFile, fm.fileExists(atPath: dir.appendingPathComponent(have).path),
               offline || it.mesh?.usdzURL == nil || entry.item.mesh?.bytes == it.mesh?.bytes {
                return (dir.appendingPathComponent(have), nil)
            }
            guard let u = it.mesh?.usdzURL else { throw NetError.http(404, "no phone mesh yet") }
            name = "mesh.usdz"; rel = u
        case .splat:
            guard let s = it.splat else { throw NetError.http(404, "no splat for this scan") }
            name = "splat.splat"; rel = s.url
            let total = s.bytes ?? (s.count ?? 0) * SplatBudget.bytesPerSplat
            rangeBytes = total > 0 ? SplatBudget.loadBytes(fileBytes: total, maxSplats: maxSplats) : nil
            if let have = entry.splatFile, fm.fileExists(atPath: dir.appendingPathComponent(have).path),
               let n = entry.splatCount, offline || (n * SplatBudget.bytesPerSplat == rangeBytes && entry.item.splat?.bytes == s.bytes) {
                return (dir.appendingPathComponent(have), n)
            }
        case .views:
            guard let v = it.viewsURL else { throw NetError.http(404, "no walk points") }
            name = "views.json"; rel = v
            if let have = entry.viewsFile, fm.fileExists(atPath: dir.appendingPathComponent(have).path) {
                return (dir.appendingPathComponent(have), nil)
            }
        }
        guard !offline, let src = await url(rel) else { throw NetError.offline }
        let dest = dir.appendingPathComponent(name)
        let t0 = Date()
        let tmp = try await download(src, rangeBytes: rangeBytes, progress: progress)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        var size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        var count: Int? = nil
        if part == .splat {
            // a server without Range support sends everything: cut to whole records within the budget
            let keep = SplatBudget.loadBytes(fileBytes: size, maxSplats: maxSplats > 0 ? maxSplats : Int.max / 64)
            if keep < size, let h = try? FileHandle(forWritingTo: dest) { try? h.truncate(atOffset: UInt64(keep)); try? h.close() }
            size = keep
            count = keep / SplatBudget.bytesPerSplat
            entry.splatFile = name; entry.splatCount = count
        } else if part == .mesh {
            entry.meshFile = name
        } else {
            entry.viewsFile = name
        }
        entry.item = it
        entry.lastUsed = Date().timeIntervalSince1970
        entry.bytes = folderBytes(dir)
        cached[it.id] = entry
        saveIndex()
        log.event("scan_download", ["id": .string(it.id), "part": .string(part.rawValue), "mb": .double(Double(size) / 1_048_576),
                                    "s": .double(Date().timeIntervalSince(t0))])
        evict(keep: it.id)
        return (dest, count)
    }

    private func download(_ url: URL, rangeBytes: Int?, progress: @escaping (Double) -> Void) async throws -> URL {
        var req = URLRequest(url: url)
        if let n = rangeBytes, n > 0 { req.setValue("bytes=0-\(n - 1)", forHTTPHeaderField: "Range") }
        let box = DownloadBox()
        let result: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: req) { tmp, resp, err in
                    if let err { cont.resume(throwing: err); return }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard let tmp, code == 200 || code == 206 else {
                        cont.resume(throwing: NetError.http(code, "download failed")); return
                    }
                    // the temp file is deleted when this handler returns: move it first
                    let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do { try FileManager.default.moveItem(at: tmp, to: keep); cont.resume(returning: keep) }
                    catch { cont.resume(throwing: error) }
                }
                box.task = task
                task.resume()
                Task { @MainActor in
                    while let t = box.task, t.state == .running {
                        progress(t.progress.fractionCompleted)
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    progress(1)
                }
            }
        } onCancel: { box.task?.cancel() }
        return result
    }

    private func folderBytes(_ dir: URL) -> Int {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func touch(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.lastViewedKey)
        if var e = cached[id] { e.lastUsed = Date().timeIntervalSince1970; cached[id] = e; saveIndex() }
    }

    func isCached(_ id: String) -> Bool { cached[id]?.meshFile != nil || cached[id]?.splatFile != nil }

    /// Keep the offline cache within budget; the scan on screen (= last viewed) is never evicted.
    func evict(keep: String?) {
        let entries = cached.map { ScanCachePolicy.Entry(key: $0.key, bytes: $0.value.bytes, lastUsed: $0.value.lastUsed) }
        for k in ScanCachePolicy().evictions(entries, keep: keep) {
            try? fm.removeItem(at: root.appendingPathComponent(ScanCachePolicy.folderName(k)))
            cached[k] = nil
            log.event("scan_evict", ["id": .string(k)])
        }
        saveIndex()
    }

    var cacheBytes: Int { cached.values.reduce(0) { $0 + $1.bytes } }

    func clearCache() {
        for k in cached.keys { try? fm.removeItem(at: root.appendingPathComponent(ScanCachePolicy.folderName(k))) }
        cached.removeAll()
        saveIndex()
    }
}

private final class DownloadBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
}
