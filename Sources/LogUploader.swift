// Owner requirement A (2026-10-12): session logs go straight to the map server. Every file in Documents/logs is uploaded
// with append-by-offset `PUT /v1/logs/{agent}/{name}?offset=N` (docs/SNAILSIGHT-API.md §3): automatically every ~30 s,
// when the app goes to the background, when the server comes online, and at once on "Send log".
import Foundation
import SnailSightCore

actor LogUploader {
    private let link: ServerLink
    private let flush: () -> Void
    private var state: LogUploadState
    private var paths: [String: String] = [:]       // name → path on the server (from the server's reply)
    private var running = false

    private static var stateURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("log_upload_state.json")
    }

    init(link: ServerLink, flush: @escaping () -> Void) {
        self.link = link
        self.flush = flush
        if let u = Self.stateURL, let d = try? Data(contentsOf: u),
           let s = try? JSONDecoder().decode(LogUploadState.self, from: d) {
            state = s
        } else {
            state = LogUploadState()
        }
    }

    private func save() {
        guard let u = Self.stateURL, let d = try? JSONEncoder().encode(state) else { return }
        try? d.write(to: u, options: .atomic)
    }

    struct Result { var files: Int; var bytes: Int; var path: String? }

    /// Upload every log's new bytes. `focus` = the file whose server path to return (the current session log).
    /// Throws only when the server is unreachable or rejects a request.
    @discardableResult
    func syncAll(focus: String? = nil) async throws -> Result {
        if running { return Result(files: 0, bytes: 0, path: focus.flatMap { paths[$0] }) }
        running = true
        defer { running = false }
        flush()
        guard let dir = DebugLog.logsDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return Result(files: 0, bytes: 0, path: nil)
        }
        let logs = names.filter { $0.hasSuffix(".jsonl") && AgentID.isValidName($0) }.sorted()
        state.prune(keeping: Set(logs))
        var files = 0, bytes = 0
        for name in logs {
            let sent = try await upload(name: name, url: dir.appendingPathComponent(name))
            if sent > 0 { files += 1; bytes += sent }
        }
        save()
        return Result(files: files, bytes: bytes, path: focus.flatMap { paths[$0] })
    }

    /// Send one file's missing bytes; returns bytes sent.
    private func upload(name: String, url: URL) async throws -> Int {
        var sent = 0
        var conflicts = 0
        while true {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard case .send(let off, let len) = state.action(name: name, localSize: size) else { return sent }
            guard let h = try? FileHandle(forReadingFrom: url) else { return sent }
            try? h.seek(toOffset: UInt64(off))
            let chunk = (try? h.read(upToCount: len)) ?? Data()
            try? h.close()
            guard !chunk.isEmpty else { return sent }
            let (data, status) = try await link.request(
                "PUT", "/v1/logs/\(Identity.agentID)/\(name)",
                query: [URLQueryItem(name: "offset", value: String(off))],
                body: chunk, contentType: "application/x-ndjson")
            let o = JSON.object(data)
            switch status {
            case 200, 201:
                state.accepted(name: name, size: JSON.int(o, "size") ?? off + chunk.count)
                if let p = JSON.string(o, "path") { paths[name] = p }
                sent += chunk.count
            case 409:
                conflicts += 1
                guard conflicts <= 3 else { throw NetError.http(409, "log offset keeps mismatching") }
                state.conflict(name: name, serverSize: JSON.int(o, "size") ?? 0, localSize: size)
            default:
                save()
                throw NetError.http(status, JSON.detail(data))
            }
            save()
        }
    }
}
