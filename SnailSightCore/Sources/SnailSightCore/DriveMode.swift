import Foundation

// SnailSight 12.7 drive mode (owner 2026-10-22: "It's hard to see and drive at the same time" — his view was buried
// under the command ring, the O2 ops card, the selection bar, a toast, the joystick and the sheet). Tapping Drive enters a
// full-screen driving layout: ring / O2 card / selection bar / rail / status pill / sheet hidden, a slim top strip
// (name, speed, lease holder / nav / connection, view toggle, Exit, E-stop), twin sticks. Exit restores the EXACT
// previous layout (sheet detent, selection, expanded cards) and releases the controller lease (`cmd {release: true}`).
// Also: the lease tracker (API §5.9.10 "Controller lease": a `granted:false` event is a RELEASE — never "driven by
// another device"; only `granted:true` for someone else, or a 409, means another controller), the view toggle
// (AR | FPV | Chase) and the quick wheel's items.
// Pure, Linux-tested (DriveModeTests).

public enum DriveView: String, CaseIterable, Equatable {
    case ar, fpv, chase

    public var title: String {
        switch self {
        case .ar: return "AR"
        case .fpv: return "FPV"
        case .chase: return "Chase"
        }
    }

    public var symbol: String {
        switch self {
        case .ar: return "arkit"
        case .fpv: return "scope"
        case .chase: return "car.rear.waves.up"
        }
    }

    public var next: DriveView {
        let all = DriveView.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// FPV / Chase render the 3D world without AR (the AR session is paused, as for Map 3D).
    public var pausesAR: Bool { self != .ar }
}

/// The parts of the normal HUD that drive mode hides.
public enum DriveChrome: String, CaseIterable, Equatable {
    case commandRing, opsCard, selectionBar, sheet, rightRail, statusPill, locPill, legacyJoystick, cards
}

/// What the layout looked like before drive mode (restored on Exit).
public struct DriveLayoutSnapshot: Equatable {
    public var sheetDetent: SheetDetent
    public var selectionID: String?
    public var statusExpanded: Bool
    public var locExpanded: Bool
    public var legacyJoystickHidden: Bool
    public init(sheetDetent: SheetDetent, selectionID: String?, statusExpanded: Bool = false, locExpanded: Bool = false,
                legacyJoystickHidden: Bool = false) {
        self.sheetDetent = sheetDetent; self.selectionID = selectionID; self.statusExpanded = statusExpanded
        self.locExpanded = locExpanded; self.legacyJoystickHidden = legacyJoystickHidden
    }
}

public struct DriveModeLayout: Equatable {
    public private(set) var active = false
    public private(set) var bodyID: String?
    public private(set) var saved: DriveLayoutSnapshot?
    public private(set) var view: DriveView = .ar
    public init() {}

    /// Everything but the drive strip + sticks is hidden while driving.
    public static let hiddenWhileDriving = Set(DriveChrome.allCases)

    public func isHidden(_ c: DriveChrome) -> Bool { active && Self.hiddenWhileDriving.contains(c) }

    /// Enter for `body` (re-entering for another body keeps the ORIGINAL snapshot). false = not entered.
    @discardableResult
    public mutating func enter(body: String, current: DriveLayoutSnapshot) -> Bool {
        guard !body.isEmpty else { return false }
        if !active { saved = current; view = .ar }
        active = true
        bodyID = body
        return true
    }

    /// Switch the driven body inside drive mode (L1 / R1): the snapshot stays the one from before drive mode.
    public mutating func switchBody(_ id: String) { if active { bodyID = id } }

    public struct Exit: Equatable {
        public var restore: DriveLayoutSnapshot
        public var release: String?            // the body whose controller lease to give back
        public var resumeAR: Bool              // FPV / Chase paused the AR session
    }

    /// Exit: what to restore + the lease to release; nil when not active.
    public mutating func exit() -> Exit? {
        guard active, let s = saved else { return nil }
        let out = Exit(restore: s, release: bodyID, resumeAR: view.pausesAR)
        active = false
        bodyID = nil
        saved = nil
        view = .ar
        return out
    }

    /// AR | FPV | Chase; returns (old, new) when it changed.
    @discardableResult
    public mutating func setView(_ v: DriveView) -> (from: DriveView, to: DriveView)? {
        guard active, v != view else { return nil }
        let old = view
        view = v
        return (old, v)
    }

    @discardableResult
    public mutating func cycleView() -> (from: DriveView, to: DriveView)? { setView(view.next) }
}

// MARK: - controller lease (API §5.9.10)

/// A `lease` event (sent by the server as `{type: "lease", …}`; also `{type: "event", kind: "lease", …}`).
public struct SimLeaseEvent: Equatable, Decodable {
    public var entityID: String
    public var owner: String?
    public var granted: Bool?
    public var by: String?
    public var holder: String?
    public var reason: String?                 // idle | release | disconnect (releases)
    public var takenFrom: String?
    public var releasedBy: String?

    enum K: String, CodingKey {
        case id, owner, granted, by, holder, reason
        case entityID = "entity_id", takenFrom = "taken_from", releasedBy = "released_by"
    }

    public init(entityID: String, owner: String?, granted: Bool?, by: String? = nil, holder: String? = nil,
                reason: String? = nil, takenFrom: String? = nil, releasedBy: String? = nil) {
        self.entityID = entityID; self.owner = owner; self.granted = granted; self.by = by; self.holder = holder
        self.reason = reason; self.takenFrom = takenFrom; self.releasedBy = releasedBy
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func s(_ k: K) -> String? { let x: String? = try? c.decodeIfPresent(String.self, forKey: k); return x }
        entityID = s(.entityID) ?? s(.id) ?? ""
        owner = s(.owner); by = s(.by); holder = s(.holder); reason = s(.reason)
        takenFrom = s(.takenFrom); releasedBy = s(.releasedBy)
        granted = try? c.decodeIfPresent(Bool.self, forKey: .granted)
    }

    /// The lease event in a raw WS message (nil = not a lease message).
    public static func parse(_ data: Data) -> SimLeaseEvent? {
        struct T: Decodable { var type: String?; var kind: String?; var event: String? }
        guard let t = try? JSONDecoder().decode(T.self, from: data),
              t.type == "lease" || (t.type == "event" && (t.kind ?? t.event) == "lease") else { return nil }
        return try? JSONDecoder().decode(SimLeaseEvent.self, from: data)
    }
}

/// Who holds a body's lease: from a 409 refusal `{detail: "leased", by, holder, until}` or an entity doc `lease`.
public struct LeaseHolder: Equatable, Decodable {
    public var by: String?
    public var holder: String?
    public var until: Double?
    public init(by: String? = nil, holder: String? = nil, until: Double? = nil) { self.by = by; self.holder = holder; self.until = until }

    /// "portal (cop.snail)" / the id / "another device".
    public var label: String { holder ?? by ?? "another device" }

    /// A WS ack `{type: ack, ok: false, status: 409, detail: {…} | "leased"}` → the holder (nil = not a lease refusal).
    public static func refusal(_ data: Data) -> (id: String?, holder: LeaseHolder)? {
        struct A: Decodable {
            var type: String?; var ok: Bool?; var status: Int?; var id: String?
            var detail: D?
            enum D: Decodable {
                case text(String), obj(LeaseHolder)
                init(from d: Decoder) throws {
                    if let s = try? d.singleValueContainer().decode(String.self) { self = .text(s); return }
                    self = .obj(try LeaseHolder(from: d))
                }
            }
        }
        guard let a = try? JSONDecoder().decode(A.self, from: data), a.type == "ack", a.ok == false, a.status == 409
        else { return nil }
        switch a.detail {
        case .obj(let h)?: return (a.id, h)
        default: return (a.id, LeaseHolder())
        }
    }
}

/// What the UI should say about a lease change (nil flash = say nothing).
public enum LeaseNotice: Equatable {
    case mine(takenFrom: String?)                         // I hold it (taken over from someone?)
    case takenByOther(holder: String, fromMe: Bool)       // someone else took it (from me?)
    case released(reason: String?, mine: Bool)            // a release (idle / release / disconnect): NOT "driven by another"
    case refused(holder: String)                          // 409: someone else holds it

    public func flash(title: String) -> String? {
        switch self {
        case .mine(let from?): return "You took over \(title) from \(from)"
        case .mine: return nil
        case .takenByOther(let h, true): return "\(h) took over \(title)"
        case .takenByOther(let h, false): return "\(title) is driven by \(h)"
        case .released: return nil
        case .refused(let h): return "\(title) is driven by \(h)"
        }
    }
}

/// Per body: does ANOTHER controller drive it (shown with a Take over action)? Only `granted:true` for someone else or
/// a 409 sets it; any release clears it. Own grants / releases never produce "driven by another".
public struct LeaseTracker: Equatable {
    private var others: [String: LeaseHolder] = [:]
    private var mine: Set<String> = []
    public init() {}

    public mutating func observe(_ e: SimLeaseEvent, me: String) -> LeaseNotice {
        let id = e.entityID
        if e.granted == true {
            let who = e.owner ?? e.by
            if who == me {
                others[id] = nil
                mine.insert(id)
                return .mine(takenFrom: e.takenFrom)
            }
            let fromMe = mine.contains(id) || e.takenFrom == me
            mine.remove(id)
            others[id] = LeaseHolder(by: who, holder: e.holder, until: nil)
            return .takenByOther(holder: e.holder ?? who ?? "another device", fromMe: fromMe)
        }
        // granted false / missing = a RELEASE (owner null): whoever held it, nobody does now
        let wasMine = mine.contains(id) || e.releasedBy == me
        mine.remove(id)
        others[id] = nil
        return .released(reason: e.reason, mine: wasMine)
    }

    public mutating func refused(_ id: String, holder: LeaseHolder) -> LeaseNotice {
        mine.remove(id)
        others[id] = holder
        return .refused(holder: holder.label)
    }

    /// The other controller's label, nil = free or mine. `until` (server time) past = free again.
    public func drivenByOther(_ id: String, serverNow: Double? = nil) -> String? {
        guard let h = others[id] else { return nil }
        if let u = h.until, let n = serverNow, n > u + 0.5 { return nil }
        return h.label
    }

    public func isMine(_ id: String) -> Bool { mine.contains(id) }
    public mutating func forget(_ id: String) { others[id] = nil; mine.remove(id) }
}

// MARK: - quick wheel (hold L2 / the on-screen wheel button)

public enum DriveWheelItem: String, CaseIterable, Equatable {
    case stop, centreTurret, view, tank, follow, goTo, exit, takeOver

    public var title: String {
        switch self {
        case .stop: return "Stop"
        case .centreTurret: return "Centre"
        case .view: return "View"
        case .tank: return "Tank"
        case .follow: return "Follow me"
        case .goTo: return "Go to"
        case .exit: return "Exit"
        case .takeOver: return "Take over"
        }
    }

    public var symbol: String {
        switch self {
        case .stop: return "stop.circle.fill"
        case .centreTurret: return "scope"
        case .view: return "eye"
        case .tank: return "arrow.triangle.2.circlepath"
        case .follow: return "figure.walk"
        case .goTo: return "mappin.and.ellipse"
        case .exit: return "xmark.circle"
        case .takeOver: return "hand.raised.fill"
        }
    }

    /// Items offered for the driven body (always 8 slots in the same order; unavailable ones are dimmed).
    public static func available(_ item: DriveWheelItem, hasTurret: Bool, ackermann: Bool, otherDriver: Bool) -> Bool {
        switch item {
        case .centreTurret: return hasTurret
        case .tank: return ackermann
        case .takeOver: return otherDriver
        default: return true
        }
    }
}
