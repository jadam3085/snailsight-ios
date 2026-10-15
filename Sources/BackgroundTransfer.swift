// Background capture upload (9.1.60, owner run 2026-10-12): every capture part is a file-based upload task on a
// background URLSession, so iOS (nsurlsessiond) keeps sending while SnailSight is suspended or the phone is locked,
// and relaunches the app in the background (handleEventsForBackgroundURLSession) to report the results.
// AppServices owns the long-lived objects so a background relaunch without any UI still has the log, the server link
// and the upload queue to record those results.
import SwiftUI
import UIKit
import SnailSightCore

/// What the background session tells the upload queue. Delivered IN ORDER through one AsyncStream.
enum TransferEvent {
    case progress(desc: String, task: Int, sent: Int64)
    case complete(desc: String, task: Int, status: Int, body: Data, error: String?)
    case finishedEvents                              // iOS delivered everything queued while we were suspended
}

final class BackgroundTransfer: NSObject, URLSessionDataDelegate {
    static let identifier = "snailsight.capture-upload"

    private(set) var session: URLSession!
    let events: AsyncStream<TransferEvent>
    private let cont: AsyncStream<TransferEvent>.Continuation
    private var bodies: [Int: Data] = [:]            // delegate queue only (serial)

    override init() {
        var c: AsyncStream<TransferEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        cfg.isDiscretionary = false                  // start now, not when iOS finds it convenient
        cfg.sessionSendsLaunchEvents = true          // relaunch us in the background when tasks finish
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.timeoutIntervalForRequest = 120          // idle timeout per request
        cfg.timeoutIntervalForResource = 48 * 3600   // keep trying for two days (no network, server down)
        cfg.httpMaximumConnectionsPerHost = 3
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "snailsight.transfer"
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    /// Start one PUT of `file` (must stay on disk until the task completes). Returns the task identifier.
    func upload(file: URL, to url: URL, description: String) -> Int {
        var r = URLRequest(url: url)
        r.httpMethod = "PUT"
        r.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        let t = session.uploadTask(with: r, fromFile: file)
        t.taskDescription = description
        t.resume()
        return t.taskIdentifier
    }

    /// Tasks iOS still holds for us (survives app termination by the system, not a force-quit).
    func liveTasks() async -> [(id: Int, desc: String?)] {
        await session.allTasks.map { ($0.taskIdentifier, $0.taskDescription) }
    }

    func cancel(task id: Int) async {
        for t in await session.allTasks where t.taskIdentifier == id { t.cancel() }
    }

    // MARK: URLSession delegate (serial delegate queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        cont.yield(.progress(desc: task.taskDescription ?? "", task: task.taskIdentifier, sent: totalBytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        var err: String?
        if let e = error as NSError? { err = "\(e.domain) \(e.code): \(e.localizedDescription)" }
        cont.yield(.complete(desc: task.taskDescription ?? "", task: task.taskIdentifier, status: status, body: body, error: err))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        cont.yield(.finishedEvents)
    }
}

/// Process-wide services. Created at launch by the app delegate (also on a background relaunch with no UI).
final class AppServices {
    static let shared = AppServices()

    let log = DebugLog()
    let transfer = BackgroundTransfer()
    let link: ServerLink
    let logs: LogUploader
    let queue: UploadQueue
    let version: String

    // UI hooks, set by AppModel on the main thread; always invoked on the main thread.
    var onLink: ((String?, String) -> Void)?
    var onUploads: (([UploadItem], Double?) -> Void)?
    /// From application(_:handleEventsForBackgroundURLSession:completionHandler:); main thread only.
    var backgroundCompletion: (() -> Void)?

    private init() {
        let i = Bundle.main.infoDictionary
        version = "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
        let info = AgentInfo(name: UIDevice.current.name, device: DebugLog.deviceModel, appVersion: version)
        link = ServerLink(info: info) { base, label in
            DispatchQueue.main.async { AppServices.shared.onLink?(base, label) }
        }
        let lg = log
        logs = LogUploader(link: link) { lg.flush() }
        let meta: [String: Any] = ["app_version": version, "meta": ["device": DebugLog.deviceModel]]
        queue = UploadQueue(link: link, transfer: transfer, meta: meta,
                            log: { ev, data in lg.event(ev, data) },
                            report: { items, rate in
                                DispatchQueue.main.async { AppServices.shared.onUploads?(items, rate) }
                            })
        let q = queue, t = transfer, l = log, up = logs
        Task.detached {
            await q.start()
            for await e in t.events {
                await q.handle(e)
                if case .finishedEvents = e {
                    try? await up.syncAll()                             // ship the log while iOS gives us time
                    l.flush()
                    await MainActor.run {
                        let h = AppServices.shared.backgroundCompletion
                        AppServices.shared.backgroundCompletion = nil
                        h?()
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let s = AppServices.shared                    // reconnects the background session at every launch
        s.log.event("launch", ["state": .string(application.applicationState == .background ? "background" : "foreground"),
                               "version": .string(s.version)])
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        let s = AppServices.shared
        s.log.event("bg_session_events", ["id": .string(identifier)])
        guard identifier == BackgroundTransfer.identifier else { completionHandler(); return }
        s.backgroundCompletion = completionHandler
    }
}
