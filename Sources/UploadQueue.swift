// Capture upload queue, 9.1.60 (docs/SNAILSIGHT-API.md §4.2b). Per capture:
//   plan    list the capture folder, split it into ~16 MB parts (SnailSightCore.PartPlanner, deterministic)
//   POST    /v1/sessions {upload:"parts", parts_total, bytes_total} (idempotent on client_session_id; returns the parts
//           the server already holds, which is how a restart or a 9.1.59 → 9.1.60 update resumes)
//   pack    each part = a store-only zip (straight copy + CRC, no deflate: JPEG/PNG do not compress) written to
//           Documents/uploads/<capture>/NNNNN.zip; the first part is on the wire about a second after Stop
//   send    each part = one PUT /v1/sessions/{id}/parts/{n} upload task on the BACKGROUND URLSession
//           (BackgroundTransfer): iOS keeps sending while the app is suspended or the phone is locked
//   poll    GET /v1/sessions/{id} until processed; the room report lands in `report`
// Every step is written to the session log (ev "upload_*" / "part_*"), so a failed run is diagnosable from
// the map server (data/snailsight/logs/<agent>/). State: Documents/upload_queue.json (tolerant decoding + migration of
// the 9.1.59 file, see SnailSightCore.UploadItem).
// 9.1.61: unfinished captures (folder with odometry.csv but no capture.json: the app was killed while recording; the
// 9.1.60 scan below skipped them, which is why cap-20261012-035412 never uploaded) are repaired by
// SnailSightCore.CaptureRecovery in start(), off the main thread, then queued like any capture (ev "recovered_capture").
// The session POST carries `recovered` / `partial` / `stop_reason` from capture.json so the server labels them.
import Foundation
import SnailSightCore

actor UploadQueue {
    private let link: ServerLink
    private let transfer: BackgroundTransfer
    private let meta: [String: Any]
    private let log: (String, [String: LogValue]) -> Void
    private let report: ([UploadItem], Double?) -> Void
    private var items: [UploadItem] = []
    private var running = false
    private var started = false
    private var rate = RateMeter()
    private var lastReport: Double = 0
    private var taskStart: [Int: Double] = [:]
    private var lastProgressLog: [String: Int] = [:]          // capture → last logged 10 % step

    private static var docs: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    private static var stateURL: URL? { docs?.appendingPathComponent("upload_queue.json") }
    static var uploadsDir: URL? { docs?.appendingPathComponent("uploads") }
    static func partsDir(_ id: String) -> URL? { uploadsDir?.appendingPathComponent(id) }
    static func partFile(_ id: String, _ n: Int) -> URL? { partsDir(id)?.appendingPathComponent(String(format: "%05d.zip", n)) }

    init(link: ServerLink, transfer: BackgroundTransfer, meta: [String: Any],
         log: @escaping (String, [String: LogValue]) -> Void, report: @escaping ([UploadItem], Double?) -> Void) {
        self.link = link
        self.transfer = transfer
        self.meta = meta
        self.log = log
        self.report = report
        let (loaded, notes) = Self.loadAndMigrate()
        items = loaded
        for (ev, data) in notes { log(ev, data) }
    }

    // MARK: load / migrate (static: runs inside init)

    private static func loadAndMigrate() -> ([UploadItem], [(String, [String: LogValue])]) {
        var notes: [(String, [String: LogValue])] = []
        var items: [UploadItem] = []
        let fm = FileManager.default
        if let u = stateURL, let d = try? Data(contentsOf: u) {
            do {
                items = try JSONDecoder().decode([UploadItem].self, from: d)
            } catch {
                // keep the unreadable file for diagnosis; the orphan scan below re-queues every capture folder
                let bad = u.deletingLastPathComponent().appendingPathComponent("upload_queue.bad-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.moveItem(at: u, to: bad)
                notes.append(("upload_queue_unreadable", ["error": .string(String(describing: error).prefix(300).description),
                                                          "kept": .string(bad.lastPathComponent)]))
            }
        }
        for i in items.indices where items[i].migrateToParts() {
            let id = items[i].clientSessionID
            if let z = uploadsDir?.appendingPathComponent("\(id).zip") { try? fm.removeItem(at: z) }   // 9.1.59 zip
            notes.append(("upload_migrated", ["id": .string(id), "from": .string("stream"), "to": .string("parts")]))
        }
        // capture folders the queue does not know (queue file lost/unreadable): queue them again; the server's
        // client_session_id idempotency makes this harmless for captures it already has
        if let root = CaptureRecorder.capturesDirectory, let names = try? fm.contentsOfDirectory(atPath: root.path) {
            let known = Set(items.map(\.id))
            for name in names.sorted() where (name.hasPrefix("cap-") || ObjectNaming.mode(of: name) != nil) && !known.contains(name) {
                let dir = root.appendingPathComponent(name)
                // object scans (9.3): a photo scan is complete once object.json exists (written after reconstruction)
                let doc = ObjectNaming.mode(of: name) == .photo ? "object.json" : "capture.json"
                guard let d = try? Data(contentsOf: dir.appendingPathComponent(doc)),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                var it = UploadItem(clientSessionID: name, frames: o["frames"] as? Int ?? 0, captureBytes: 0)
                it.dropped = o["dropped"] as? Int
                it.created = o["started"] as? Double ?? it.created
                items.append(it)
                notes.append(("upload_recovered", ["id": .string(name), "frames": .int(it.frames)]))
            }
            items.sort { $0.created < $1.created }
        }
        if !notes.isEmpty, let u = stateURL, let d = try? JSONEncoder().encode(items) { try? d.write(to: u, options: .atomic) }
        return (items, notes)
    }

    /// Repair + queue capture folders a killed recording left behind (never the one being recorded now).
    private func recoverUnfinished() async {
        guard let root = CaptureRecorder.capturesDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let known = Set(items.map(\.id))
        let fallback: [String: String] = ["agent_id": Identity.agentID, "agent_type": Identity.agentType,
                                       "app_version": meta["app_version"] as? String ?? "?",
                                       "recovered_by": meta["app_version"] as? String ?? "?"]
        for name in names.sorted() where name.hasPrefix("cap-") && !known.contains(name) {
            guard name != CaptureRecorder.activeCaptureID else { continue }
            let dir = root.appendingPathComponent(name)
            let files = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            guard CaptureRecovery.needsRecovery(fileNames: files) else { continue }
            let t0 = Date()
            do {
                let r = try await Task.detached(priority: .utility) {
                    try CaptureRecovery.recover(dir: dir, fallbackMeta: fallback)
                }.value
                var ev: [String: LogValue] = ["id": .string(name), "frames": .int(r.frames),
                                              "rows_dropped": .int(r.rowsDropped), "files_removed": .int(r.filesRemoved),
                                              "imu_lines_dropped": .int(r.imuLinesDropped),
                                              "mb": .double((Double(r.bytes) / 1_048_576 * 10).rounded() / 10),
                                              "checkpoint": .bool(r.checkpoint), "segments": .int(r.segments),
                                              "duration_s": .double((r.durationS * 10).rounded() / 10),
                                              "ms": .int(Int(Date().timeIntervalSince(t0) * 1000))]
                if r.discarded {
                    ev["action"] = .string("discarded (no usable frames)")
                    log("recovered_capture", ev)
                    continue
                }
                ev["action"] = .string("queued")
                log("recovered_capture", ev)
                var it = UploadItem(clientSessionID: name, frames: r.frames, captureBytes: r.bytes)
                it.created = CaptureRecovery.startFromName(name) ?? it.created
                items.append(it)
            } catch {
                log("recover_failed", ["id": .string(name), "error": .string(String(describing: error).prefix(300).description)])
            }
        }
        items.sort { $0.created < $1.created }
    }

    /// Once per process, before the first pass: forget part tasks iOS no longer holds (app killed, phone rebooted,
    /// app reinstalled) so they are sent again; adopt nothing unknown. Then recover unfinished captures.
    func start() async {
        guard !started else { return }
        started = true
        let before = items.count
        await recoverUnfinished()
        if items.count != before { save() }
        let live = await transfer.liveTasks()
        let liveIDs = Set(live.map(\.id))
        var changed = false
        for i in items.indices {
            let stale = items[i].dropStaleTasks(live: liveIDs)
            if !stale.isEmpty {
                changed = true
                log("upload_tasks_lost", ["id": .string(items[i].id), "parts": .doubles(stale.map { Double($0) })])
            }
        }
        log("upload_queue_start", ["items": .int(items.count), "pending": .int(items.filter { !$0.serverHasAll }.count),
                                   "live_tasks": .int(live.count)])
        if changed { save() } else { report(items, rate.bytesPerSecond) }
    }

    func current() -> [UploadItem] { items }

    private func save() {
        if let u = Self.stateURL, let d = try? JSONEncoder().encode(items) { try? d.write(to: u, options: .atomic) }
        lastReport = Date().timeIntervalSince1970
        report(items, rate.bytesPerSecond)
    }

    private func index(_ id: String) -> Int? { items.firstIndex { $0.id == id } }

    private func update(_ id: String, save doSave: Bool = true, _ f: (inout UploadItem) -> Void) {
        guard let i = index(id) else { return }
        f(&items[i])
        if doSave { save() }
    }

    func enqueue(_ s: CaptureSummary) {
        guard index(s.clientSessionID) == nil else { return }
        var it = UploadItem(clientSessionID: s.clientSessionID, frames: s.frames, captureBytes: s.bytes)
        it.dropped = s.dropped
        items.append(it)
        log("upload_enqueue", ["id": .string(s.clientSessionID), "frames": .int(s.frames),
                               "mb": .double(Double(s.bytes) / 1_048_576)])
        save()
    }

    func retryNow() {
        for i in items.indices where !items[i].finished {
            items[i].nextAttempt = 0; items[i].lastPoll = 0
            for j in items[i].parts.indices { items[i].parts[j].nextAttempt = 0 }
        }
        log("upload_retry_now", [:])
        save()
    }

    /// Delete the local capture folder (only once the server holds every byte).
    func deleteLocal(_ id: String) {
        guard let it = items.first(where: { $0.id == id }), it.serverHasAll,
              let dir = CaptureRecorder.capturesDirectory?.appendingPathComponent(id) else { return }
        try? FileManager.default.removeItem(at: dir)
        if let p = Self.partsDir(id) { try? FileManager.default.removeItem(at: p) }
        update(id) { $0.localDeleted = true }
        log("capture_deleted_local", ["id": .string(id)])
    }

    // MARK: pass

    /// One pass over the queue. Safe to call often (timer, network up, Stop, foreground, background).
    func kick(reason: String = "timer") async {
        if running { return }
        running = true
        defer { running = false }
        if !started { await start() }
        await link.setWakeClass(CopWake.wakeClass(pendingUploads: items.filter { !$0.serverHasAll }.count))   // 10.9
        let now = Date().timeIntervalSince1970
        for it in items where !it.serverHasAll && it.mode == "parts" && it.nextAttempt <= now {
            do {
                try await work(it.id, reason: reason)
            } catch {
                let offline = Self.isOffline(error)
                update(it.id) {
                    $0.attempts += 1
                    $0.error = error.localizedDescription
                    $0.nextAttempt = Date().timeIntervalSince1970 + Backoff.delay(attempt: $0.attempts - 1)
                }
                let a = items.first(where: { $0.id == it.id })?.attempts ?? 0
                log("upload_err", ["id": .string(it.id), "error": .string(error.localizedDescription),
                                   "attempt": .int(a), "retry_in_s": .double(Backoff.delay(attempt: a - 1)),
                                   "reason": .string(reason)])
                if offline { break }
            }
        }
        for it in items where it.serverHasAll && !it.finished && it.sessionID != nil && now - it.lastPoll >= 15 {
            await poll(it.id)
        }
        pruneLocal()
    }

    private static func isOffline(_ e: Error) -> Bool {
        if let ne = e as? NetError, case .offline = ne { return true }
        return false
    }

    private func work(_ id: String, reason: String) async throws {
        guard let dir = CaptureRecorder.capturesDirectory?.appendingPathComponent(id) else { return }
        guard FileManager.default.fileExists(atPath: dir.path) else {
            update(id) { $0.state = "failed"; $0.error = "capture folder missing on the phone" }
            log("upload_failed", ["id": .string(id), "error": .string("capture folder missing")])
            return
        }
        // 1. plan
        if items[index(id)!].parts.isEmpty {
            let t0 = Date()
            let plan = try await Task.detached(priority: .userInitiated) { () throws -> [PartPlan] in
                let files = try PartPlanner.listFiles(in: dir)
                return PartPlanner.plan(root: id, files: files)
            }.value
            guard !plan.isEmpty else { throw NetError.http(0, "capture folder is empty") }
            if let p = Self.partsDir(id) { try? FileManager.default.removeItem(at: p) }       // stale parts of an older plan
            update(id) {
                $0.parts = plan.map { PartState(index: $0.index, size: $0.size) }
                $0.bytesTotal = plan.reduce(0) { $0 + $1.size }
                $0.captureBytes = $0.bytesTotal
                $0.state = "planned"
                $0.error = nil
            }
            log("upload_plan", ["id": .string(id), "files": .int(plan.reduce(0) { $0 + $1.files.count }),
                                "parts": .int(plan.count), "mb": .double(Double(items[index(id)!].bytesTotal) / 1_048_576),
                                "ms": .int(Int(Date().timeIntervalSince(t0) * 1000)), "reason": .string(reason)])
        }
        // 2. session (if the server is reachable now; packing continues offline)
        var offlineError: Error?
        if items[index(id)!].sessionID == nil {
            do { try await createSession(id) } catch { offlineError = error }
        }
        // 3. pack + hand each part to the background session as soon as it exists
        let filesNow = try await Task.detached { () throws -> [CaptureFile] in try PartPlanner.listFiles(in: dir) }.value
        let plan = PartPlanner.plan(root: id, files: filesNow)
        let it = items[index(id)!]
        guard plan.count == it.parts.count, zip(plan, it.parts).allSatisfy({ $0.size == $1.size }) else {
            // the folder changed under us (should not happen): start over with a fresh plan + session reset
            update(id) { $0.parts = []; $0.sessionID = nil; $0.state = "recorded" }
            log("upload_replan", ["id": .string(id), "parts_now": .int(plan.count), "parts_was": .int(it.parts.count)])
            throw NetError.http(0, "capture changed on disk; re-planning")
        }
        let packStart = Date()
        var packed = 0, packedBytes = 0
        for p in plan {
            guard let cur = items[index(id)!].parts.first(where: { $0.index == p.index }), !cur.done else { continue }
            guard let file = Self.partFile(id, p.index) else { continue }
            let onDisk = FileManager.default.fileExists(atPath: file.path)
            if !cur.packaged || !onDisk {
                let t0 = Date()
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try StoreZip.build(part: p, root: id, dir: dir).write(to: file, options: .atomic)
                }.value
                packed += 1
                packedBytes += p.size
                update(id, save: false) { x in
                    if let j = x.parts.firstIndex(where: { $0.index == p.index }) { x.parts[j].packaged = true; x.parts[j].taskID = nil }
                }
                log("part_packed", ["id": .string(id), "n": .int(p.index), "mb": .double(Double(p.size) / 1_048_576),
                                    "ms": .int(Int(Date().timeIntervalSince(t0) * 1000))])
            }
            await schedule(id)
        }
        if packed > 0 {
            log("upload_packed", ["id": .string(id), "parts": .int(packed), "mb": .double(Double(packedBytes) / 1_048_576),
                                  "ms": .int(Int(Date().timeIntervalSince(packStart) * 1000))])
        }
        save()
        if let e = offlineError { throw e }
        await schedule(id)
    }

    private func createSession(_ id: String) async throws {
        guard let it = items.first(where: { $0.id == id }) else { return }
        if it.target == "object" { return try await createObject(id) }
        var body = meta
        body["agent_id"] = Identity.agentID
        body["agent_type"] = Identity.agentType
        body["kind"] = "stray"
        body["client_session_id"] = id
        body["name"] = id
        body["map_id"] = "site"
        body["bytes_total"] = it.bytesTotal
        body["frames"] = it.frames
        body["started"] = it.created
        body["upload"] = "parts"
        body["parts_total"] = it.parts.count
        if let dir = CaptureRecorder.capturesDirectory?.appendingPathComponent(id),
           let d = try? Data(contentsOf: dir.appendingPathComponent("capture.json")),
           let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if c["recovered"] as? Bool == true { body["recovered"] = true }
            if c["partial"] as? Bool == true { body["partial"] = true }
            if let r = c["stop_reason"] as? String { body["stop_reason"] = r }
        }
        try await registered(id, target: "session", body: body)
    }

    /// 9.3 object scan (API §9): POST /v1/objects, then the same parts upload. Name, tags and capture facts come from
    /// the folder's object.json (photo) / capture.json (lidar).
    private func createObject(_ id: String) async throws {
        guard let it = items.first(where: { $0.id == id }) else { return }
        var info: [String: Any] = [:]
        if let dir = CaptureRecorder.capturesDirectory?.appendingPathComponent(id) {
            for f in ["object.json", "capture.json"] {
                if let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { info = o; break }
            }
        }
        var body: [String: Any] = ["agent_id": Identity.agentID, "agent_type": Identity.agentType, "client_object_id": id,
                                   "mode": (ObjectNaming.mode(of: id) ?? .photo).rawValue, "bytes_total": it.bytesTotal,
                                   "parts_total": it.parts.count, "upload": "parts", "started": it.created,
                                   "app_version": meta["app_version"] as? String ?? "?",
                                   "name": info["object_name"] as? String ?? "Object",
                                   "tags": ObjectNaming.tags(info["object_tags"] as? [String] ?? [])]
        var m: [String: Any] = [:]
        for k in ["device", "ios", "images", "shots", "passes", "max_images", "reconstruction_s", "reconstruction_error",
                  "frames", "keyframes", "object_box", "stop_reason"] {
            if let v = info[k] { m[k] = v }
        }
        body["meta"] = m
        try await registered(id, target: "object", body: body)
    }

    /// POST the create call for `target` and adopt the server id + the parts it already holds.
    private func registered(_ id: String, target: String, body: [String: Any]) async throws {
        let key = UploadRoute.idKey(target: target)
        let (data, status) = try await link.request("POST", UploadRoute.createPath(target: target), body: JSON.body(body))
        let o = JSON.object(data)
        let server = await link.base ?? "-"
        log("upload_session", ["id": .string(id), "status": .int(status), "sid": .string(JSON.string(o, key) ?? "-"),
                               "target": .string(target),
                               "state": .string(JSON.string(o, "state") ?? "-"),
                               "held": .int((o["parts_received"] as? [Int])?.count ?? 0),
                               "server": .string(server)])
        guard status == 200 || status == 201 else { throw NetError.http(status, JSON.detail(data)) }
        guard let sid = JSON.string(o, key) else { throw NetError.http(status, "no \(key)") }
        guard JSON.string(o, "upload_mode") == "parts" else {
            throw NetError.http(status, "server does not support parts upload (update the snailsight service)")
        }
        let st = JSON.string(o, "state") ?? "created"
        update(id) {
            $0.sessionID = sid
            $0.markHeld(o["parts_received"] as? [Int] ?? [])
            if ["uploaded", "processing", "processed", "failed"].contains(st) {
                for j in $0.parts.indices { $0.parts[j].done = true; $0.parts[j].taskID = nil }
            }
            $0.state = st == "created" ? "uploading" : st
            $0.received = JSON.int(o, "received") ?? 0
            $0.error = nil
            $0.attempts = 0
        }
    }

    /// Hand every packaged, unsent part to the background session (needs a session id and a server base URL).
    private func schedule(_ id: String) async {
        guard let it = items.first(where: { $0.id == id }), let sid = it.sessionID else { return }
        let now = Date().timeIntervalSince1970
        let ready = it.schedulable(now: now)
        guard !ready.isEmpty else { return }
        var maybeBase = await link.base
        if maybeBase == nil { maybeBase = await link.probe() }
        guard let base = maybeBase else { return }
        for n in ready {
            guard let file = Self.partFile(id, n), FileManager.default.fileExists(atPath: file.path),
                  let url = URL(string: base + UploadRoute.partPath(target: it.target, serverID: sid, part: n)) else {
                update(id, save: false) { x in if let j = x.parts.firstIndex(where: { $0.index == n }) { x.parts[j].packaged = false } }
                continue
            }
            let task = transfer.upload(file: file, to: url, description: "\(id)|\(n)|\(sid)")
            taskStart[task] = now
            update(id, save: false) { x in
                if let j = x.parts.firstIndex(where: { $0.index == n }) { x.parts[j].taskID = task; x.parts[j].sent = 0 }
                if x.state == "planned" || x.state == "recorded" { x.state = "uploading" }
            }
            let size = it.parts.first(where: { $0.index == n })?.size ?? 0
            log("part_send", ["id": .string(id), "n": .int(n), "task": .int(task), "mb": .double(Double(size) / 1_048_576),
                              "base": .string(base)])
        }
        save()
        if let x = items.first(where: { $0.id == id }), x.backgroundSafe {
            log("upload_background_safe", ["id": .string(id), "in_flight": .int(x.parts.filter { $0.taskID != nil }.count),
                                           "done": .int(x.parts.filter(\.done).count), "of": .int(x.parts.count)])
        }
    }

    // MARK: background session events

    func handle(_ e: TransferEvent) async {
        switch e {
        case let .progress(desc, task, sent):
            guard let pr = Self.parse(desc), let i = index(pr.id),
                  let j = items[i].parts.firstIndex(where: { $0.index == pr.n }), items[i].parts[j].taskID == task else { return }
            let id = pr.id
            items[i].parts[j].sent = Int(sent)
            let now = Date().timeIntervalSince1970
            let total = items.reduce(0) { $0 + ($1.serverHasAll ? 0 : $1.sentBytes) }
            rate.add(t: now, bytes: total)
            let step = Int(items[i].progress * 10)
            if step > (lastProgressLog[id] ?? -1) {
                lastProgressLog[id] = step
                log("upload_progress", ["id": .string(id), "pct": .int(step * 10),
                                        "mb": .double(Double(items[i].sentBytes) / 1_048_576),
                                        "rate_mbps": .double((rate.bytesPerSecond ?? 0) * 8 / 1_000_000)])
            }
            if now - lastReport > 0.5 { lastReport = now; report(items, rate.bytesPerSecond) }

        case let .complete(desc, task, status, body, error):
            await complete(desc: desc, task: task, status: status, body: body, error: error)

        case .finishedEvents:
            log("bg_events_done", ["pending": .int(items.filter { !$0.serverHasAll }.count)])
            save()
        }
    }

    private static func parse(_ desc: String) -> (id: String, n: Int)? {
        let p = desc.split(separator: "|")
        guard p.count >= 2, let n = Int(p[1]) else { return nil }
        return (String(p[0]), n)
    }

    private func complete(desc: String, task: Int, status: Int, body: Data, error: String?) async {
        let secs = taskStart.removeValue(forKey: task).map { Date().timeIntervalSince1970 - $0 }
        guard let pr = Self.parse(desc), let i = index(pr.id),
              let j = items[i].parts.firstIndex(where: { $0.index == pr.n }) else {
            log("part_orphan", ["desc": .string(desc), "task": .int(task), "status": .int(status)])
            return
        }
        let id = pr.id, n = pr.n
        guard items[i].parts[j].taskID == task || items[i].parts[j].taskID == nil else {
            log("part_stale", ["id": .string(id), "n": .int(n), "task": .int(task), "status": .int(status)])
            return
        }
        let o = JSON.object(body)
        let size = items[i].parts[j].size
        var data: [String: LogValue] = ["id": .string(id), "n": .int(n), "task": .int(task), "status": .int(status),
                                        "mb": .double(Double(size) / 1_048_576)]
        if let secs { data["s"] = .double((secs * 10).rounded() / 10) }
        if error == nil && (status == 200 || status == 201) {
            let st = JSON.string(o, "state") ?? "uploading"
            update(id, save: false) { x in
                x.parts[j].done = true; x.parts[j].taskID = nil; x.parts[j].sent = 0; x.parts[j].lastError = nil
                x.parts[j].attempts = 0
                x.received = JSON.int(o, "received") ?? x.received
                if ["uploaded", "processing", "processed", "failed"].contains(st) {
                    for k in x.parts.indices { x.parts[k].done = true; x.parts[k].taskID = nil }
                }
                x.state = st
                x.error = nil
            }
            if let f = Self.partFile(id, n) { try? FileManager.default.removeItem(at: f) }
            data["held"] = .int(JSON.int(o, "parts_held") ?? -1)
            data["of"] = .int(items[i].parts.count)
            data["state"] = .string(st)
            log("part_ok", data)
            if items[i].serverHasAll {
                if let p = Self.partsDir(id) { try? FileManager.default.removeItem(at: p) }
                let it = items[i]
                log("upload_done", ["id": .string(id), "mb": .double(Double(it.bytesTotal) / 1_048_576),
                                    "parts": .int(it.parts.count), "state": .string(it.state),
                                    "sid": .string(it.sessionID ?? "-")])
            }
        } else {
            let attempt = items[i].parts[j].attempts + 1
            let wait = Backoff.delay(attempt: attempt - 1, base: 5, cap: 300)
            let detail = error ?? JSON.detail(body)
            update(id, save: false) { x in
                x.parts[j].taskID = nil; x.parts[j].sent = 0
                x.parts[j].attempts = attempt
                x.parts[j].nextAttempt = Date().timeIntervalSince1970 + wait
                x.parts[j].lastError = "\(status): \(detail)"
                x.error = "part \(n): \(status == 0 ? detail : "server said \(status): \(detail)")"
                switch status {
                case 404, 409: x.sessionID = nil                          // session gone / wrong mode: re-POST
                case 422: x.parts[j].packaged = false                    // corrupt part: pack again
                default: break
                }
            }
            if status == 422, let f = Self.partFile(id, n) { try? FileManager.default.removeItem(at: f) }
            data["error"] = .string(String(detail.prefix(200)))
            data["attempt"] = .int(attempt)
            data["retry_in_s"] = .double(wait)
            log("part_err", data)
        }
        save()
    }

    // MARK: poll / prune

    private func poll(_ id: String) async {
        guard let item = items.first(where: { $0.id == id }), let sid = item.sessionID else { return }
        guard let res = try? await link.request("GET", UploadRoute.statusPath(target: item.target, serverID: sid)), res.1 == 200 else {
            update(id) { $0.lastPoll = Date().timeIntervalSince1970 }
            return
        }
        let o = JSON.object(res.0)
        let before = items.first(where: { $0.id == id })?.state
        let st = JSON.string(o, "state")
        var line: String?
        if let rep = o["report"] as? [String: Any], let room = rep["room"] as? [String: Any], room["ok"] as? Bool == true,
           let l = room["length_m"] as? Double, let w = room["width_m"] as? Double {
            line = String(format: "Room %.2f × %.2f m", l, w)
            if let h = room["height_m"] as? Double { line! += String(format: ", height %.2f m", h) }
        }
        if item.target == "object", let r = o["result"] as? [String: Any] {
            line = UploadRoute.objectLine(dims: r["dims_m"] as? [Double])
        }
        update(id) {
            $0.lastPoll = Date().timeIntervalSince1970
            if let st { $0.state = st }
            $0.error = JSON.string(o, "error")
            if let line { $0.report = line }
        }
        if st != before {
            log("upload_server_state", ["id": .string(id), "sid": .string(sid), "state": .string(st ?? "-"),
                                        "report": .string(line ?? ""), "error": .string(JSON.string(o, "error") ?? "")])
        }
    }

    /// Keep at most the newest 3 captures locally among those the server fully holds.
    private func pruneLocal() {
        let has = Set(items.filter { $0.serverHasAll }.map(\.id))
        let local = items.filter { !$0.localDeleted }.map(\.id)
        for id in CaptureNaming.toPrune(local, serverHas: has, keep: 3) { deleteLocal(id) }
    }
}
