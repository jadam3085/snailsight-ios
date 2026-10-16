import Foundation

/// The COP power gate (10.9). The map server's stack can be switched OFF by its owner. While it is OFF, a small
/// always-on gate answers on the server's address with HTTP 503 and a JSON body:
///     {"cop": "waking" | "off", "retry_s": N, "detail": "..."}
/// "waking" means this request woke the server: retry after N s. "off" means it stays off (this request may not
/// wake it): keep captures queued and try again later. Requests may say why they knock with the header
/// `X-Cop-Wake-Class` (`phone-capture` when uploads are waiting, else `phone-live`) plus `X-Agent-Id`.
public struct CopState: Equatable {
    public enum Kind: String { case off, waking }

    public var kind: Kind
    public var retryS: Double
    public var detail: String

    public init(kind: Kind, retryS: Double, detail: String) {
        self.kind = kind
        self.retryS = retryS
        self.detail = detail
    }

    /// nil unless this is a power-gate answer (503 + a `cop` field).
    public static func parse(status: Int, body: Data) -> CopState? {
        guard status == 503,
              let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let k = o["cop"] as? String, let kind = Kind(rawValue: k) else { return nil }
        var r = 10.0
        if let d = o["retry_s"] as? Double { r = d } else if let i = o["retry_s"] as? Int { r = Double(i) }
        return CopState(kind: kind, retryS: max(2, min(r, 300)), detail: (o["detail"] as? String) ?? "")
    }

    /// Short text for the status pill.
    public var label: String { kind == .waking ? "COP waking…" : "COP off" }

    /// Pill text with the number of captures waiting to upload.
    public static func pill(_ label: String, pending: Int) -> String {
        pending > 0 ? "\(label) · \(pending) waiting" : label
    }

    /// Is a server label one of ours ("COP off" / "COP waking…")?
    public static func isCopLabel(_ label: String) -> Bool { label.hasPrefix("COP ") }
}

public enum CopWake {
    public static let header = "X-Cop-Wake-Class"
    public static let agentHeader = "X-Agent-Id"

    /// Captures waiting to upload may wake the server (owner default); otherwise the phone only asks (`phone-live`).
    public static func wakeClass(pendingUploads: Int) -> String {
        pendingUploads > 0 ? "phone-capture" : "phone-live"
    }
}
