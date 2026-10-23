import Combine
import Foundation
import SnailSightCore

// SnailSight 12.8: runtime sim content (owner: lab characters must reach the app with no extra steps). The map server's
// GET /v1/sim/content lists spawnable items (Helix lab characters) with content-addressed blobs; this store keeps the
// last document + every blob in Application Support/SimContent (works offline), refreshes in the background, verifies
// each blob's sha256 before it is used, exposes an item only once ALL its files are on disk, and publishes the bundled
// catalog merged with the runtime items (SimContent.merge). Bundled models stay the fallback.

final class SimContentStore: ObservableObject {
    static let shared = SimContentStore()

    /// The bundled catalog (Resources/SimModels/catalog.json), or the three 9.7 animals.
    static let bundled: SimCatalog = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let c = try? SimCatalog.decode(data), !c.items.isEmpty
        else { return .builtIn }
        return c
    }()

    /// Bundled + ready runtime items. Main thread.
    @Published private(set) var catalog: SimCatalog = SimContentStore.bundled
    @Published private(set) var rejected: [SimContentRejected] = []
    private(set) var runtimeItems: [SimCatalogItem] = []
    private(set) var rev: String?

    private var link: ServerLink?
    private var log: ((String, [String: LogValue]) -> Void)?
    private var running = false
    private var lastRefresh: TimeInterval = -1e9
    private var lastUnknown: TimeInterval = -1e9
    private let fm = FileManager.default
    private let dir: URL
    private var blobDir: URL { dir.appendingPathComponent("blobs", isDirectory: true) }
    private var docURL: URL { dir.appendingPathComponent("catalog.json") }
    private var prevURL: URL { dir.appendingPathComponent("catalog.prev.json") }

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                                  create: true)) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("SimContent", isDirectory: true)
        try? fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        var skip = URLResourceValues()
        skip.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(skip)
        if let data = try? Data(contentsOf: docURL), let doc = try? SimContentDoc.decode(data) { apply(doc) }   // offline
    }

    /// Wire the server link + log once (AppModel.startNetworking); refreshes on every reconnect.
    func attach(link: ServerLink, log: @escaping (String, [String: LogValue]) -> Void) {
        guard self.link == nil else { return }
        self.link = link
        self.log = log
        Task { await link.whenOnline { [weak self] in DispatchQueue.main.async { self?.refresh(reason: "online") } } }
        refresh(reason: "launch")
    }

    /// Local file of a catalog file name (a runtime blob on disk), nil = use the bundle.
    func localURL(for file: String) -> URL? {
        guard let b = SimContent.blob(for: file, in: runtimeItems) else { return nil }
        let u = blobDir.appendingPathComponent(b)
        return fm.fileExists(atPath: u.path) ? u : nil
    }

    /// A server body of a kind the merged catalog lacks: a new lab character may have just been published.
    func unknownKind(_ kind: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard catalog.item(kind) == nil, now - lastUnknown >= 30 else { return }
        lastUnknown = now
        refresh(reason: "unknown_kind")
    }

    /// Background refresh (main thread call). `force` skips the 5 s debounce (spawn picker opening is not forced).
    func refresh(reason: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let link, !running, force || now - lastRefresh >= 5 else { return }
        running = true
        lastRefresh = now
        let known = rev
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let t0 = Date()
            var ev: [String: LogValue] = ["reason": .string(reason)]
            var newDoc: SimContentDoc?
            do {
                let hdr = known.map { ["If-None-Match": "\"\($0)\""] } ?? [:]
                let (data, st) = try await link.request("GET", "/v1/sim/content", timeout: 15, headers: hdr)
                if st == 304 {
                    ev["unchanged"] = .bool(true)
                } else if st == 200 {
                    let doc = try SimContentDoc.decode(data)
                    if doc.rev != known { newDoc = doc; try? data.write(to: self.dir.appendingPathComponent("catalog.new.json")) }
                    else { ev["unchanged"] = .bool(true) }
                } else {
                    ev["error"] = .string("http \(st)")
                }
            } catch {
                ev["error"] = .string("\(error)")
            }
            // blobs: for the new doc, or for the current one if a previous fetch left some missing
            var fetched = 0, bytes = 0
            let target: SimContentDoc? = newDoc ?? self.currentDoc()
            if let doc = target {
                let have = self.onDisk()
                for m in SimContent.missing(doc.items, have: have) {
                    let path = SimContent.blobPath(m.blob, base: doc.blobPath)
                    do {
                        let (data, st) = try await link.request("GET", path, timeout: 120)
                        guard st == 200 else { throw NSError(domain: "SimContent", code: st, userInfo: [NSLocalizedDescriptionKey: "http \(st)"]) }
                        guard SimContent.verify(data, ref: m.ref) else {
                            self.emit("sim_content_blob_fail", ["sha": .string(m.ref.sha256), "reason": .string("sha256 mismatch (\(data.count) B)")])
                            continue
                        }
                        let tmp = self.blobDir.appendingPathComponent(m.blob + ".part")
                        try data.write(to: tmp, options: .atomic)
                        let dst = self.blobDir.appendingPathComponent(m.blob)
                        try? self.fm.removeItem(at: dst)
                        try self.fm.moveItem(at: tmp, to: dst)
                        fetched += 1
                        bytes += data.count
                    } catch {
                        self.emit("sim_content_blob_fail", ["sha": .string(m.ref.sha256), "reason": .string("\(error)")])
                    }
                }
            }
            if let doc = newDoc {
                // keep the previous doc (its blobs stay for one more rev), then the new one becomes current
                if self.fm.fileExists(atPath: self.docURL.path) {
                    try? self.fm.removeItem(at: self.prevURL)
                    try? self.fm.moveItem(at: self.docURL, to: self.prevURL)
                }
                try? self.fm.moveItem(at: self.dir.appendingPathComponent("catalog.new.json"), to: self.docURL)
                self.prune(keep: [doc] + (self.prevDoc().map { [$0] } ?? []))
            }
            let have = self.onDisk()
            await MainActor.run {
                if let d = target { self.apply(d, have: have) }
                self.running = false
                ev["rev"] = .string(self.rev ?? "")
                ev["items"] = .int(self.runtimeItems.count)
                ev["rejected"] = .int(self.rejected.count)
                ev["fetched"] = .int(fetched)
                ev["bytes"] = .int(bytes)
                ev["ms"] = .int(Int(Date().timeIntervalSince(t0) * 1000))
                self.log?("sim_content_sync", ev)
            }
        }
    }

    // MARK: internals

    private func emit(_ e: String, _ d: [String: LogValue]) {
        DispatchQueue.main.async { [weak self] in self?.log?(e, d) }
    }

    private func currentDoc() -> SimContentDoc? {
        (try? Data(contentsOf: docURL)).flatMap { try? SimContentDoc.decode($0) }
    }

    private func prevDoc() -> SimContentDoc? {
        (try? Data(contentsOf: prevURL)).flatMap { try? SimContentDoc.decode($0) }
    }

    private func onDisk() -> Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath: blobDir.path)) ?? []).filter { !$0.hasSuffix(".part") })
    }

    /// Drop blobs neither the current nor the previous doc references.
    private func prune(keep docs: [SimContentDoc]) {
        let keep = SimContent.referenced(docs)
        for n in (try? fm.contentsOfDirectory(atPath: blobDir.path)) ?? [] where !keep.contains(n) {
            try? fm.removeItem(at: blobDir.appendingPathComponent(n))
        }
    }

    private func apply(_ doc: SimContentDoc, have: Set<String>? = nil) {
        let ready = SimContent.ready(doc.items, have: have ?? onDisk())
        rev = doc.rev
        rejected = doc.rejected ?? []
        guard ready != runtimeItems else { return }
        runtimeItems = ready
        catalog = SimContent.merge(bundled: SimContentStore.bundled, runtime: ready)
    }
}
