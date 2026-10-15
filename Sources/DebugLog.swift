import Foundation
import UIKit
import SnailSightCore

/// On-device session log: Documents/logs/session-<UTC>.jsonl, one JSON object per line (schema
/// `snailsight.log/1`, see SnailSightCore/SessionLog.swift). Visible in the Files app
/// (On My iPhone ▸ SnailSight ▸ logs) via UIFileSharingEnabled, and shareable from the HUD "Log" button.
/// Since 9.1 every log is uploaded to the snailsight service (`PUT /v1/logs`, LogUploader): automatically in the
/// background and on "Send log".
final class DebugLog {
    let fileURL: URL?
    private let queue = DispatchQueue(label: "snailsight.log")
    private var handle: FileHandle?
    static let keep = 30

    static var logsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("logs")
    }

    static var deviceModel: String {
        var u = utsname()
        uname(&u)
        return withUnsafePointer(to: &u.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    init() {
        guard let dir = Self.logsDirectory else { fileURL = nil; return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for old in LogFormat.filesToPrune(names, keep: Self.keep - 1) {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
            }
        }
        let url = dir.appendingPathComponent(LogFormat.fileName(start: Date()))
        fm.createFile(atPath: url.path, contents: nil)
        fileURL = url
        handle = try? FileHandle(forWritingTo: url)
        event("log_open", ["schema": .string(LogFormat.schema)])
    }

    func event(_ ev: String, _ data: [String: LogValue] = [:]) {
        let line = LogFormat.line(LogEvent(t: Date().timeIntervalSince1970, ev: ev, data: data))
        queue.async { [weak self] in
            guard let h = self?.handle else { return }
            h.seekToEndOfFile()
            h.write(line)
        }
    }

    /// Blocks until every queued event is on disk (call before reading the file for upload). Thread-safe.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    deinit { try? handle?.close() }
}
