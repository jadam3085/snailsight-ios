// SnailSight 11.0 tile streaming (live shared-map plan §3.2 / M2, API §5.12): after the lock, the house map is drawn
// from per-tile USDZ blobs near the camera instead of one whole-house mesh.
//
//  - NOTHING before a real server lock (MapLocalizer.alignment from the server): no tileset, no tile bytes.
//  - The tileset (3D Tiles 1.1, map frame, z up) of the current variant ("structure" by default, "raw" when Settings ▸
//    Raw scan is on) is fetched from head.tiles (MapFollower). A new head.tiles.rev refetches it; tiles whose content
//    hash is unchanged cost nothing (blobs are immutable and cached on disk by hash, Caches/tiles/<sha256>.usdz, 2 GB LRU).
//  - Every 0.5 s (MapARLayer.slowTick): camera in the map frame, heading (camera forward projected on the map plane),
//    speed (recent positions) → SnailSightCore.TileSelect.select (the exact port of the server's tileselect.py: distance
//    bands, heading prefetch, 600 MB budget). Wanted tiles download nearest first, ≤ 3 at a time, load off the main
//    thread (Entity(contentsOf:)) and hang under `node` (a child of the map frame) turned Y-up → Z-up (+90° about X:
//    usdz (x, y, z) = map (x, z, −y)). REPLACE refinement with no holes: a parent stays drawn until its wanted children
//    are loaded (TileSelect.drawn); tiles neither wanted nor drawn are released.
//  - House overlay Model = the textured tiles (unlit: the texture is the photographed light); Wire / Ghost put their
//    materials on the same tiles.
// Logs: tiles_start, tile_fetch, tile_drawn_first_near, tiles_status (every 10 s), tile_evict, tile_error.
import CryptoKit
import Foundation
import QuartzCore
import RealityKit
import UIKit
import SnailSightCore

final class TileStreamer {
    private unowned let model: AppModel
    private unowned let layer: MapARLayer
    /// Child of the map frame (map coordinates, Z up); every tile entity hangs under it.
    let node = Entity()

    // the tileset on screen
    private(set) var variant: String?
    private(set) var tilesetRev: Int?
    private var tilesetPath: String?
    private var roots: [TileNode] = []
    /// Storey slabs of the tileset (11.0.1: other storeys are penalised in the selection).
    private var levels: [TileLevel] = []
    private var parents: [String: String] = [:]
    private var nodes: [String: TileNode] = [:]
    private var hashes: [String: String] = [:]                 // key → usdz content hash of the current tileset
    /// 12.0: held tiles a sync replaced, waiting for their new content to attach (then highlighted as fresh).
    private var syncSwapped = Set<String>()
    /// 11.2 (M4): tiles changed by a `sync` event before the tileset is refetched: key → (hash, blob URI).
    private var syncOverride: [String: (hash: String, uri: String)] = [:]
    /// Bumped whenever the set of loaded tiles changes (MapFollower re-sends `held`).
    private(set) var heldGen = 0
    private var fetchingTileset = false
    private var tilesetRetryAt: TimeInterval = 0

    // the scene
    private var entities: [String: Entity] = [:]
    private var originals: [String: [(Entity, [RealityKit.Material])]] = [:]
    private var ledger = TileMemLedger()
    private var inFlight: [String: String] = [:]               // key → hash being downloaded / loaded
    private var failedUntil: [String: TimeInterval] = [:]
    private var want: [String: TileSelect.Want] = [:]
    private var drawnKeys: Set<String> = []
    private var styleApplied: HouseStyle?

    // disk cache
    private var disk = TileDiskLRU()
    private var diskSeeded = false

    // motion + stats
    private var motion = TileMotion()
    private var started = false
    private var hiddenSince: TimeInterval?
    private var firstNearLogged = false
    private var dlBytes = 0
    private var fetchedCount = 0
    private var cachedCount = 0
    private var evictions = 0
    private var lastStatus: TimeInterval = 0
    private var noTilesLogged = false

    static let maxConcurrent = 3
    static let statusEveryS = 10.0
    static let retryS = 15.0

    init(model: AppModel, layer: MapARLayer) {
        self.model = model
        self.layer = layer
        node.name = "map.tiles"
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    static var cacheDir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tiles", isDirectory: true)
    }

    private var sinceLock: Double {
        guard let t = model.mapLocalizer.lockedAt else { return -1 }
        return ((now - t) * 100).rounded() / 100
    }

    /// The overlay draws tiles (Model / Wire / Ghost).
    private var drawing: Bool {
        let st = model.drawHouse                                  // 12.4: masked by the 3D world switch
        return st == .model || st == .wire || st == .ghost
    }

    /// A real server lock (a lock the server gave in this ARKit session, or one carried over a reset from it).
    private var serverLocked: Bool {
        model.mapLocalizer.alignment != nil && ["server", "carried"].contains(model.mapLocalizer.lockSource)
    }

    var memMB: Double { Double(ledger.totalMem) / 1_048_576 }
    var drawnCount: Int { drawnKeys.count }
    /// 12.12: keys of the textured house tiles on screen (Model style only; Wire / Ghost let the live mesh show).
    var drawnModelKeys: Set<String> { model.drawHouse == .model && node.isEnabled ? drawnKeys : [] }

    // MARK: tick (main, every 0.5 s while the map is aligned)

    /// `cam` = the camera in the map frame, `forward` = the camera's forward direction in the map frame.
    func tick(cam: [Double], forward: [Double]?) {
        let t = now
        node.isEnabled = drawing
        guard drawing else {                                        // Off / Labels / 3D world off: nothing streams
            // 12.4: hidden for 30 s -> free the tiles (memory + battery); the disk cache makes coming back cheap.
            if hiddenSince == nil { hiddenSince = t }
            if let h = hiddenSince, t - h > 30, !ledger.items.isEmpty { clear(reason: "hidden") }
            return
        }
        hiddenSince = nil
        guard model.mapLocalizer.alignment != nil else { return }
        if !started {
            guard serverLocked else { return }                     // never before a real server lock
            started = true
        }
        applyStyle()
        ensureTileset(t)
        guard !roots.isEmpty else { return }
        motion.add(t: t, x: cam[0], y: cam[1])
        let heading = forward.flatMap { TileMotion.heading(forward: $0) }
        want = TileSelect.select(roots, cam: cam, heading: heading, speed: motion.speed,
                                 camLevel: TileSelect.cameraLevel(z: cam[2], levels: levels))
        refresh()
        if !model.recording && !model.arSuspended { schedule(t) }
        if t - lastStatus >= Self.statusEveryS {
            lastStatus = t
            logStatus()
        }
    }

    /// Recompute what is drawn from `want` + what is loaded; release what is neither wanted nor drawn.
    private func refresh() {
        let current = ledger.current(hashes: hashes)
        var d = TileSelect.drawn(want: want, loaded: current, parents: parents, prevDrawn: drawnKeys)
        // a tile whose content changed in a new rev keeps its old entity on screen until the new one is loaded
        for k in ledger.items.keys where want[k] != nil && !current.contains(k) { d.insert(k) }
        for k in TileSelect.evictable(loaded: Set(ledger.items.keys), want: want, drawn: d) {
            release(k, reason: "unwanted")
        }
        for (k, e) in entities {
            let on = d.contains(k)
            if e.isEnabled != on { e.isEnabled = on }
        }
        drawnKeys = d
        if !firstNearLogged, d.contains(where: { nodes[$0]?.size == TileSelect.LEAF_M && current.contains($0) }) {
            firstNearLogged = true
            model.log.event("tile_drawn_first_near", ["since_lock_s": .double(sinceLock), "drawn": .int(d.count),
                                                      "variant": .string(variant ?? ""), "rev": .int(tilesetRev ?? -1)])
        }
    }

    // MARK: 11.2 sync (plan M4, API §5.13)

    /// The loaded tiles as `held` for the rev socket ({"structure:1/0/-1": usdz hash}); empty before tiles start.
    var held: [String: String] {
        guard let v = variant else { return [:] }
        return TileSync.held(variant: v, hashes: ledger.items.mapValues { $0.hash })
    }

    /// A `sync` block from the rev socket: held tiles whose content changed are re-fetched NOW (the old entity stays
    /// drawn until the new one is loaded), removed ones are released. The tileset refetch that follows the new
    /// tiles.rev agrees with this (same hashes), so nothing is fetched twice.
    func applySync(_ ev: TileSyncEvent) {
        guard let v = variant else { return }
        let ch = ev.changes(variant: v)
        var applied = 0
        for (k, c) in ch where nodes[k] != nil {
            guard hashes[k] != c.hash else { continue }
            let old = syncOverride[k]?.uri ?? nodes[k]?.uri ?? ""
            let prefix = old.split(separator: "/").dropLast().joined(separator: "/")
            let uri = prefix.isEmpty ? "\(c.hash).usdz" : "\(prefix)/\(c.hash).usdz"
            syncOverride[k] = (c.hash, uri)
            hashes[k] = c.hash
            syncSwapped.insert(k)                                   // 12.0: highlight it when the new one lands
            failedUntil[k] = nil
            applied += 1
        }
        var gone = 0
        for k in ev.removedKeys(variant: v) where ledger.items[k] != nil {
            hashes[k] = nil
            release(k, reason: "removed")
            gone += 1
        }
        model.log.event("tile_sync", ["kind": .string(ev.kind), "rev": .int(ev.rev ?? -1), "changed": .int(ch.count),
                                      "applied": .int(applied), "removed": .int(gone),
                                      "changed_total": .int(ev.changedTotal ?? -1)])
        if applied > 0 || gone > 0 {
            refresh()
            if !model.recording && !model.arSuspended { schedule(now) }
        }
    }

    // MARK: tileset

    private func ensureTileset(_ t: TimeInterval) {
        guard let tb = model.mapFollower.tiles else {
            if !noTilesLogged {
                noTilesLogged = true
                model.log.event("tiles_unavailable", ["since_lock_s": .double(sinceLock),
                                                      "features": .string(model.serverFeatures.list.contains("tiles") ? "tiles" : "")])
            }
            return
        }
        guard let v = tb.variant(raw: model.rawScan, clean: model.cleanLook), let path = tb.tilesetPath(v) else { return }
        if v == variant && tb.rev == tilesetRev { return }
        guard !fetchingTileset, t >= tilesetRetryAt, let link = model.link else { return }
        fetchingTileset = true
        let why = variant == nil ? "first" : (v != variant ? "variant" : "rev")
        let t0 = CACurrentMediaTime()
        Task { [weak self] in
            var data: Data?
            var status = 0
            var err: String?
            do {
                let (d, s) = try await link.request("GET", path, timeout: 30)
                status = s
                if s == 200 { data = d } else { err = "HTTP \(s)" }
            } catch {
                err = error.localizedDescription
            }
            let dataF = data, statusF = status, errF = err
            let parsedL: ([TileNode], [TileLevel])? = await Task.detached(priority: .userInitiated) { () -> ([TileNode], [TileLevel])? in
                guard let d = dataF, let r = try? TileSet.parse(d) else { return nil }
                return (r, TileSet.levels(d))
            }.value
            let parsed = parsedL?.0
            let levelsF = parsedL?.1 ?? []
            let ms = (CACurrentMediaTime() - t0) * 1000
            let bytes = dataF?.count ?? 0
            await MainActor.run {
                guard let self else { return }
                self.fetchingTileset = false
                guard let r = parsed, !r.isEmpty else {
                    self.tilesetRetryAt = self.now + Self.retryS
                    self.model.log.event("tile_error", ["what": .string("tileset"), "variant": .string(v),
                                                        "status": .int(statusF), "error": .string(errF ?? "parse failed"),
                                                        "bytes": .int(bytes)])
                    return
                }
                self.dlBytes += bytes
                self.levels = levelsF
                self.install(r, variant: v, rev: tb.rev, path: path, why: why, bytes: bytes, ms: ms)
            }
        }
    }

    private func install(_ r: [TileNode], variant v: String, rev: Int, path: String, why: String, bytes: Int, ms: Double) {
        if v != variant { clear(reason: "variant") }
        roots = r
        parents = TileSelect.ancestorsMap(r)
        let all = TileSet.flatten(r)
        nodes = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        hashes = Dictionary(all.compactMap { n in n.hash.map { (n.key, $0) } }, uniquingKeysWith: { a, _ in a })
        syncOverride.removeAll()
        variant = v
        tilesetRev = rev
        tilesetPath = path
        failedUntil.removeAll()
        let unchanged = ledger.current(hashes: hashes).count
        model.log.event("tiles_start", ["variant": .string(v), "rev": .int(rev), "since_lock_s": .double(sinceLock),
                                        "why": .string(why), "tiles": .int(hashes.count), "bytes": .int(bytes),
                                        "ms": .int(Int(ms)), "kept": .int(unchanged)])
        lastStatus = 0                                              // a status line soon after
    }

    /// Drop every tile (variant switch).
    private func clear(reason: String) {
        for k in Array(ledger.items.keys) { release(k, reason: reason) }
        inFlight.removeAll()
        drawnKeys.removeAll()
        firstNearLogged = false
    }

    // MARK: downloads + loading

    private func schedule(_ t: TimeInterval) {
        guard inFlight.count < Self.maxConcurrent, let base = tilesetPath else { return }
        let current = ledger.current(hashes: hashes)
        for w in TileSelect.fetchOrder(want, loaded: current) {
            if inFlight.count >= Self.maxConcurrent { break }
            let k = w.node.key
            let ov = syncOverride[k]
            guard inFlight[k] == nil, (failedUntil[k] ?? 0) <= t, let hash = ov?.hash ?? w.node.hash,
                  let uri = ov?.uri ?? w.node.uri else { continue }
            start(w.node, key: k, hash: hash, path: TileURL.resolve(uri, against: base))
        }
    }

    private func start(_ n: TileNode, key: String, hash: String, path: String) {
        guard let dir = Self.cacheDir, let link = model.link else { return }
        seedDisk(dir)
        inFlight[key] = hash
        let file = dir.appendingPathComponent("\(hash).usdz")
        let onDisk = disk.contains(hash) && FileManager.default.fileExists(atPath: file.path)
        let t0 = CACurrentMediaTime()
        Task { [weak self] in
            var ok = onDisk
            var bytes = 0
            var err: String?
            if !onDisk {
                do {
                    let (d, s) = try await link.request("GET", path, timeout: 60)
                    if s != 200 {
                        err = "HTTP \(s)"
                    } else if Self.sha256(d) != hash {
                        err = "hash mismatch (\(d.count) bytes)"
                    } else {
                        try d.write(to: file, options: .atomic)
                        bytes = d.count
                        ok = true
                    }
                } catch {
                    err = error.localizedDescription
                }
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            let okF = ok, bytesF = bytes, errF = err
            await MainActor.run {
                self?.fetched(n, key: key, hash: hash, file: file, ok: okF, cached: onDisk, bytes: bytesF, ms: ms, err: errF)
            }
        }
    }

    static func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private func fetched(_ n: TileNode, key: String, hash: String, file: URL, ok: Bool, cached: Bool, bytes: Int,
                         ms: Double, err: String?) {
        let t = now
        guard ok else {
            if inFlight[key] == hash { inFlight[key] = nil }
            failedUntil[key] = t + Self.retryS
            model.log.event("tile_error", ["what": .string("fetch"), "key": .string(key), "error": .string(err ?? "?")])
            return
        }
        if cached {
            cachedCount += 1
            disk.touch(hash, now: t)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            fetchedCount += 1
            dlBytes += bytes
            let pinned = ledger.hashes.union(inFlight.values)
            for h in disk.insert(hash, bytes: bytes, now: t, pinned: pinned) {
                if let dir = Self.cacheDir { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(h).usdz")) }
            }
        }
        model.log.event("tile_fetch", ["key": .string(key), "bytes": .int(cached ? n.bytes : bytes), "ms": .int(Int(ms)),
                                       "cached": .bool(cached), "level": .int(n.level), "size_m": .int(n.size),
                                       "mem_mb": .double(Self.mb(n.mem))])
        // no longer wanted (walked on, new rev, other variant): keep it on disk only
        guard want[key] != nil, hashes[key] == hash, inFlight[key] == hash else {
            if inFlight[key] == hash { inFlight[key] = nil }
            return
        }
        let t0 = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            do {
                let e = try await Entity(contentsOf: file)          // RealityKit loads off the main thread
                self?.attach(e, node: n, key: key, hash: hash, loadMs: (CACurrentMediaTime() - t0) * 1000)
            } catch {
                guard let self else { return }
                if self.inFlight[key] == hash { self.inFlight[key] = nil }
                self.failedUntil[key] = self.now + Self.retryS
                // a corrupt cache entry: delete it so the next try downloads it again
                try? FileManager.default.removeItem(at: file)
                self.disk.remove(hash)
                self.model.log.event("tile_error", ["what": .string("load"), "key": .string(key),
                                                    "error": .string(error.localizedDescription)])
            }
        }
    }

    private func attach(_ e: Entity, node n: TileNode, key: String, hash: String, loadMs: Double) {
        guard inFlight[key] == hash else { return }                 // cleared meanwhile (variant switch)
        inFlight[key] = nil
        guard want[key] != nil, hashes[key] == hash else { return } // walked on while it loaded
        let swapped = entities[key] != nil && syncSwapped.remove(key) != nil
        if entities[key] != nil { release(key, reason: "replaced") }
        if swapped {                                                // 12.0 Mesh (live): a base tile changed in place
            let b = n.box
            let sq: [Double]? = b.count >= 8 ? [b[0] - b[3], b[1] - b[7], b[0] + b[3], b[1] + b[7]] : nil
            model.meshStore.noteBase(key: key, square: sq, level: n.level, box: b)
            model.liveMap.baseSwapped(key: key, box: b)
        }
        let holder = Entity()
        holder.name = "tile.\(key)"
        holder.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))   // usdz Y-up → map Z-up
        holder.addChild(e)
        var mats: [(Entity, [RealityKit.Material])] = []
        if variant == "clean" { Self.record(e, into: &mats) } else { Self.unlit(e, into: &mats) }   // 12.16: clean = lit
        originals[key] = mats
        holder.isEnabled = false
        node.addChild(holder)
        entities[key] = holder
        ledger.add(key, .init(hash: hash, mem: n.mem, near: n.size == TileSelect.LEAF_M))
        heldGen += 1
        disk.touch(hash, now: now)
        style(key, model.drawHouse)
        refresh()
        if loadMs > 1500 { model.log.event("tile_slow_load", ["key": .string(key), "ms": .int(Int(loadMs))]) }
    }

    private func release(_ key: String, reason: String) {
        guard let it = ledger.remove(key) else { return }
        heldGen += 1
        entities.removeValue(forKey: key)?.removeFromParent()
        originals[key] = nil
        drawnKeys.remove(key)
        evictions += 1
        model.log.event("tile_evict", ["key": .string(key), "mem_mb": .double(Self.mb(it.mem)), "reason": .string(reason),
                                       "total_mb": .double(Self.mb(ledger.totalMem))])
    }

    // MARK: materials (Model = unlit textures, Wire / Ghost = the overlay materials)

    /// The texture IS the photographed light: unlit, as the Scans viewer shows mesh.usdz. Records the materials per model.
    private static func unlit(_ e: Entity, into out: inout [(Entity, [RealityKit.Material])]) {
        if var mc = e.components[ModelComponent.self] {
            mc.materials = mc.materials.map { m -> RealityKit.Material in
                if let p = m as? PhysicallyBasedMaterial {
                    var u = UnlitMaterial()
                    u.color = .init(tint: p.baseColor.tint, texture: p.baseColor.texture)
                    return u
                }
                if let s = m as? SimpleMaterial {
                    var u = UnlitMaterial()
                    u.color = .init(tint: s.color.tint, texture: s.color.texture)
                    return u
                }
                return m
            }
            e.components.set(mc)
            out.append((e, mc.materials))
        }
        for c in e.children { unlit(c, into: &out) }
    }

    /// 12.16 clean tiles: their own (lit, physically based) materials as loaded, recorded for Wire / Ghost restore.
    private static func record(_ e: Entity, into out: inout [(Entity, [RealityKit.Material])]) {
        if let mc = e.components[ModelComponent.self] { out.append((e, mc.materials)) }
        for c in e.children { record(c, into: &out) }
    }

    private func applyStyle() {
        let st = model.drawHouse
        guard styleApplied != st else { return }
        styleApplied = st
        for k in entities.keys { style(k, st) }
    }

    private func style(_ key: String, _ st: HouseStyle) {
        guard let list = originals[key] else { return }
        var over: RealityKit.Material?
        if st == .wire { over = layer.wireMaterial } else if st == .ghost { over = layer.ghostMaterial }
        for (e, mats) in list {
            guard var mc = e.components[ModelComponent.self] else { continue }
            mc.materials = over.map { m in mats.map { _ in m } } ?? mats
            e.components.set(mc)
        }
    }

    // MARK: 12.3 Map ▸ 3D shares the blob cache and the tiles loaded here

    /// The cached file of a tile blob (nil = not on disk).
    func blobFile(_ hash: String) -> URL? {
        guard let dir = Self.cacheDir else { return nil }
        seedDisk(dir)
        let f = dir.appendingPathComponent("\(hash).usdz")
        guard disk.contains(hash), FileManager.default.fileExists(atPath: f.path) else { return nil }
        disk.touch(hash, now: now)
        return f
    }

    /// Store a downloaded (hash-checked) blob in the shared cache (2 GB LRU); returns its file.
    func storeBlob(_ hash: String, data: Data) -> URL? {
        guard let dir = Self.cacheDir else { return nil }
        seedDisk(dir)
        let f = dir.appendingPathComponent("\(hash).usdz")
        do { try data.write(to: f, options: .atomic) } catch { return nil }
        let pinned = ledger.hashes.union(inFlight.values).union([hash])
        for h in disk.insert(hash, bytes: data.count, now: now, pinned: pinned) where h != hash {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(h).usdz"))
        }
        return f
    }

    /// The AR's loaded content of a tile at exactly this hash, drawn with its own (unlit texture) materials — the 3D
    /// viewer clones it (a clone shares the mesh + texture resources: no second copy in memory).
    func sharedContent(key: String, hash: String) -> Entity? {
        guard ledger.items[key]?.hash == hash, model.drawHouse == .model, styleApplied == .model,
              let holder = entities[key] else { return nil }
        return holder.children.first
    }

    // MARK: disk + status

    /// The blobs already in Caches/tiles (once per run).
    private func seedDisk(_ dir: URL) {
        guard !diskSeeded else { return }
        diskSeeded = true
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
            guard u.pathExtension == "usdz", let h = TileURL.blobHash(u.lastPathComponent) else {
                try? fm.removeItem(at: u)                          // temp / partial files
                continue
            }
            let rv = try? u.resourceValues(forKeys: Set(keys))
            disk.seed(h, bytes: rv?.fileSize ?? 0, lastUse: rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        for h in disk.evict() { try? fm.removeItem(at: dir.appendingPathComponent("\(h).usdz")) }
    }

    private func logStatus() {
        var ev: [String: LogValue] = [
            "drawn": .int(drawnKeys.count), "loaded": .int(ledger.items.count), "inflight": .int(inFlight.count),
            "wanted": .int(want.count), "mem_mb": .double(Self.mb(ledger.totalMem)),
            "near_mb": .double(Self.mb(ledger.nearMem)), "mid_mb": .double(Self.mb(ledger.midMem)),
            "disk_mb": .double(Self.mb(disk.totalBytes)), "dl_mb_total": .double(Self.mb(dlBytes)),
            "fetched": .int(fetchedCount), "cached": .int(cachedCount), "evictions": .int(evictions),
            "speed": .double((motion.speed * 100).rounded() / 100), "variant": .string(variant ?? ""),
            "rev": .int(tilesetRev ?? -1),
        ]
        let m = MemoryProbe.fields()
        for k in ["footprint_mb", "avail_mb"] { if let v = m[k] { ev[k] = v } }
        model.log.event("tiles_status", ev)
    }

    private static func mb(_ b: Int) -> Double { (Double(b) / 1_048_576 * 10).rounded() / 10 }
}
