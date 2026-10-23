import Combine
import Foundation
import SnailSightCore

// SnailSight 12.9: EVERY sim model is live content. The map server's GET /v1/sim/content is the ONE catalog (animals,
// objects, thumbnails, the RC car's toy car, plus the low-poly RobosnailBob / drone parts); this store keeps the last
// document + every blob in Application Support/SimContent (works offline), refreshes at launch, on reconnect and when the
// sim socket pushes a `catalog` event, downloads changed blobs in the background (spawned bodies' kinds first, then
// changed, recents, the rest; byte budget with LRU eviction), verifies each blob's sha256, exposes an item only once ALL
// its files are on disk (the old version stays until then) and publishes what changed so open bodies swap in place.
// The app bundles only a minimal fallback (one animal); RobosnailBob and the drone are code-drawn boxes.

struct SimContentChange: Equatable {
    var serial: Int
    var diff: SimContentDiff
}

final class SimContentStore: ObservableObject {
    static let shared = SimContentStore()

    /// The minimal bundled catalog (Resources/SimModels/catalog.json), cut down to the items whose files are bundled.
    static let bundled: SimCatalog = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let c = try? SimCatalog.decode(data) else { return SimCatalog(items: []) }
        var files = Set<String>()
        for it in c.items { for f in (it.files ?? [:]).values where Bundle.main.url(forResource: (f as NSString).deletingPathExtension, withExtension: "usdz") != nil { files.insert(f) } }
        return SimContent.fallbackCatalog(bundled: c, bundledFiles: files)
    }()
    static let bundledFiles: Set<String> = Set(bundled.items.flatMap { ($0.files ?? [:]).values })

    /// Bundled fallback + ready runtime items. Main thread.
    @Published private(set) var catalog: SimCatalog = SimContentStore.bundled
    @Published private(set) var rejected: [SimContentRejected] = []
    /// "Models updating…": blobs done / total of the running download; nil = idle.
    @Published private(set) var updating: (done: Int, total: Int)?
    /// What the last catalog / agents update changed (bodies of those kinds swap to the new model in place).
    @Published private(set) var lastChange: SimContentChange?
    /// Served low-poly models (agents.robot / agents.drone); nil = the compiled-in drawings.
    private(set) var agents: [String: SimAgentModel]?
    private(set) var runtimeItems: [SimCatalogItem] = []
    private(set) var rev: String?

    var robotParts: [BodyPart]? { SimAgents.robotParts(agents) }
    var droneParts: [SimPartSpec]? { SimAgents.droneParts(agents) }

    /// Kinds of the bodies in the world right now + the picker's recents (set by AppModel; read on the main thread).
    var inUse: (() -> (spawned: Set<String>, recents: [String]))?

    private var link: ServerLink?
    private var log: ((String, [String: LogValue]) -> Void)?
    private var running = false
    private var rerun: String?
    private var lastRefresh: TimeInterval = -1e9
    private var lastUnknown: TimeInterval = -1e9
    private var serial = 0
    private var have = Set<String>()                           // blob names on disk (main thread)
    private let fm = FileManager.default
    private let dir: URL
    private let useLock = NSLock()
    private var uses: [String: Double] = [:]                   // blob name → last use (epoch s), persisted
    private var blobDir: URL { dir.appendingPathComponent("blobs", isDirectory: true) }
    private var docURL: URL { dir.appendingPathComponent("catalog.json") }
    private var usesURL: URL { dir.appendingPathComponent("use.json") }

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                                  create: true)) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("SimContent", isDirectory: true)
        try? fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        var skip = URLResourceValues()
        skip.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(skip)
        if let data = try? Data(contentsOf: usesURL), let u = try? JSONDecoder().decode([String: Double].self, from: data) { uses = u }
        have = onDisk()
        try? fm.removeItem(at: dir.appendingPathComponent("catalog.prev.json"))      // 12.8 leftovers
        if let data = try? Data(contentsOf: docURL), let doc = try? SimContentDoc.decode(data) { apply(doc, have: have) }   // offline
    }

    /// Wire the server link + log once (AppModel.startNetworking); refreshes on every reconnect.
    func attach(link: ServerLink, log: @escaping (String, [String: LogValue]) -> Void) {
        guard self.link == nil else { return }
        self.link = link
        self.log = log
        Task { await link.whenOnline { [weak self] in DispatchQueue.main.async { self?.refresh(reason: "online") } } }
        refresh(reason: "launch")
    }

    // MARK: file resolution (runtime blob → bundled minimal file → nothing)

    /// Where a catalog file name is read from now. `key` identifies the bytes (blob name / bundled file name), so a model
    /// whose bytes changed under the same file name loads fresh.
    func resolve(_ file: String) -> (key: String, url: URL)? {
        switch SimContent.source(for: file, runtimeItems: runtimeItems, have: have, bundledFiles: Self.bundledFiles) {
        case .runtime(let b):
            touch(b)
            return (b, blobDir.appendingPathComponent(b))
        case .bundled(let f):
            guard let u = Bundle.main.url(forResource: (f as NSString).deletingPathExtension, withExtension: (f as NSString).pathExtension)
            else { return nil }
            return (f, u)
        case .none:
            return nil
        }
    }

    /// Local file of a runtime blob (thumbnails); nil = not cached (the caller tries the bundle).
    func localURL(for file: String) -> URL? {
        guard let b = SimContent.blob(for: file, in: runtimeItems), have.contains(b) else { return nil }
        touch(b)
        return blobDir.appendingPathComponent(b)
    }

    /// Template keys the model library may keep (everything else is evicted from memory).
    var libraryKeys: Set<String> { SimContent.referenced(items: runtimeItems).union(Self.bundledFiles) }

    /// A server body of a kind the merged catalog lacks: a new model may have just been published.
    func unknownKind(_ kind: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard catalog.item(kind) == nil, now - lastUnknown >= 30 else { return }
        lastUnknown = now
        refresh(reason: "unknown_kind")
    }

    /// The sim socket's `catalog` event / hello `catalog_rev`: fetch at once when the server's rev is not ours.
    func catalogEvent(_ e: SimCatalogEvent) {
        guard e.isNews(known: rev) else { return }
        refresh(reason: e.fromHello ? "hello" : "catalog_event", force: true, changed: Set(e.changed))
    }

    private func touch(_ blob: String) {
        useLock.lock(); uses[blob] = Date().timeIntervalSince1970; useLock.unlock()
    }

    // MARK: refresh

    /// Background refresh (main thread call). `force` skips the 5 s debounce (and queues one more run if busy).
    func refresh(reason: String, force: Bool = false, changed hint: Set<String> = []) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let link else { return }
        if running { if force { rerun = reason }; return }
        guard force || now - lastRefresh >= 5 else { return }
        running = true
        lastRefresh = now
        let known = rev
        let (spawned, recents) = inUse?() ?? ([], [])
        let prior = catalog.items
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
            var fetched = 0, bytes = 0, evicted = 0
            let target: SimContentDoc? = newDoc ?? self.currentDoc()
            if let doc = target {
                // new / changed first: diff against what is exposed now
                let d = SimContentDiff.diff(old: prior.filter { $0.blobs != nil }, new: doc.items)
                let changedKeys = hint.union(d.added).union(d.changed)
                let have = self.onDisk()
                let haveBytes = self.diskBytes(have)
                let plan = SimBlobCache.fetchPlan(items: doc.items, have: have, haveBytes: haveBytes, spawned: spawned,
                                                  changed: changedKeys, recents: recents, budget: SimBlobCache.defaultBudget)
                if !plan.isEmpty { await MainActor.run { self.updating = (0, plan.count) } }
                var done = 0
                for m in plan {
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
                        self.touch(m.blob)
                        fetched += 1
                        bytes += data.count
                    } catch {
                        self.emit("sim_content_blob_fail", ["sha": .string(m.ref.sha256), "reason": .string("\(error)")])
                    }
                    done += 1
                    let progress = done
                    let haveNow = self.onDisk()
                    // an item whose last file just arrived goes live at once (swap in place), not at the end
                    await MainActor.run {
                        self.updating = (progress, plan.count)
                        self.apply(doc, have: haveNow, newRev: false)
                    }
                }
                if newDoc != nil {
                    try? self.fm.removeItem(at: self.docURL)
                    try? self.fm.moveItem(at: self.dir.appendingPathComponent("catalog.new.json"), to: self.docURL)
                }
                evicted = await self.evictNow(doc, spawned: spawned, recents: recents)
            }
            let haveFinal = self.onDisk()
            await MainActor.run {
                if let d = target { self.apply(d, have: haveFinal) }
                self.updating = nil
                self.running = false
                ev["rev"] = .string(self.rev ?? "")
                ev["items"] = .int(self.runtimeItems.count)
                ev["rejected"] = .int(self.rejected.count)
                ev["fetched"] = .int(fetched)
                ev["bytes"] = .int(bytes)
                ev["evicted"] = .int(evicted)
                ev["cache_bytes"] = .int(self.diskBytes(haveFinal))
                if let c = self.lastChange, c.serial > 0 {
                    ev["changed"] = .int(c.diff.changed.count + c.diff.added.count)
                    ev["removed"] = .int(c.diff.removed.count)
                }
                ev["ms"] = .int(Int(Date().timeIntervalSince(t0) * 1000))
                self.log?("sim_content_sync", ev)
                self.saveUses()
                if let r = self.rerun { self.rerun = nil; self.refresh(reason: r, force: true) }
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

    private func onDisk() -> Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath: blobDir.path)) ?? []).filter { !$0.hasSuffix(".part") })
    }

    private func diskBytes(_ names: Set<String>) -> Int {
        names.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: blobDir.appendingPathComponent($1).path)[.size] as? Int) ?? 0) }
    }

    private func saveUses() {
        useLock.lock(); let u = uses; useLock.unlock()
        try? JSONEncoder().encode(u).write(to: usesURL, options: .atomic)
    }

    /// Delete what nothing references any more (previous rev) and, over the byte budget, the least recently used
    /// blobs that no spawned body / recent needs. Returns how many blobs went.
    private func evictNow(_ doc: SimContentDoc, spawned: Set<String>, recents: [String]) async -> Int {
        let exposed = await MainActor.run { self.runtimeItems }
        let names = onDisk()
        useLock.lock(); let u = uses; useLock.unlock()
        let entries = names.map { n in
            SimBlobEntry(name: n, bytes: (try? fm.attributesOfItem(atPath: blobDir.appendingPathComponent(n).path)[.size] as? Int) ?? 0,
                         lastUse: u[n] ?? 0)
        }
        let keep = Set(recents).union(spawned)
        let protectedItems = (doc.items + exposed).filter { keep.contains($0.key) }
        let drop = SimBlobCache.evict(entries: entries, inUse: SimContent.referenced(items: doc.items + exposed),
                                      protected: SimContent.referenced(items: protectedItems), budget: SimBlobCache.defaultBudget)
        for n in drop { try? fm.removeItem(at: blobDir.appendingPathComponent(n)) }
        if !drop.isEmpty {
            useLock.lock(); for n in drop { uses[n] = nil }; useLock.unlock()
        }
        return drop.count
    }

    private func apply(_ doc: SimContentDoc, have: Set<String>, newRev: Bool = true) {
        self.have = have
        if newRev { rev = doc.rev }
        rejected = doc.rejected ?? []
        let old = catalog.items, oldAgents = agents
        let ready = SimContent.reconcile(previous: runtimeItems, doc: doc.items, have: have)
        runtimeItems = ready
        agents = doc.agents
        let merged = SimContent.merge(bundled: Self.bundled, runtime: ready)
        let d = SimContentDiff.diff(old: old, new: merged.items, oldAgents: oldAgents, newAgents: doc.agents)
        if merged != catalog { catalog = merged }
        if !d.isEmpty {
            serial += 1
            lastChange = SimContentChange(serial: serial, diff: d)
        }
    }
}
