import Foundation

// SnailSight 9.9 (owner on 9.8.91: "I want a way to delete cubes easily"). "Cubes" = the placed 10 cm test cubes
// (SceneRenderer) and the sim's box-shaped objects (blocks, crate, cardboard box). Tap one → ✕ on its bar, long-press
// = delete, swipe in the Cubes list, More ▸ Clear cubes; every deletion can be undone for 5 s.

public enum SimCubes {
    /// Box-shaped, roughly cubic catalog objects count as cubes (blocks, crate, cardboard box; not a book or pillow).
    public static func isCube(_ item: SimCatalogItem) -> Bool {
        guard !item.isAnimal, item.physicsOrDefault.shape == .box else { return false }
        let s = item.size
        let lo = min(s.x, min(s.y, s.z)), hi = max(s.x, max(s.y, s.z))
        return lo > 0 && hi / lo <= 1.5
    }
}

/// The last deletion, undoable for `window` seconds. A newer deletion replaces it (one Undo, like iOS shake-undo).
public struct UndoBuffer<Item> {
    public let window: Double
    public private(set) var items: [Item] = []
    public private(set) var label = ""
    public private(set) var at = -Double.infinity

    public init(window: Double = 5) { self.window = window }

    public mutating func record(_ items: [Item], label: String, now: Double) {
        guard !items.isEmpty else { return }
        self.items = items
        self.label = label
        at = now
    }

    public func canUndo(now: Double) -> Bool { !items.isEmpty && now - at <= window }

    public func remaining(now: Double) -> Double { canUndo(now: now) ? max(0, window - (now - at)) : 0 }

    /// The items to restore (empty when expired or already undone); clears the buffer.
    public mutating func undo(now: Double) -> [Item] {
        defer { items = []; label = "" }
        return canUndo(now: now) ? items : []
    }

    public mutating func expire(now: Double) {
        if !items.isEmpty && now - at > window { items = []; label = "" }
    }
}

/// Ordered list of placed cubes (number = "#n" shown on the cube). Deleting returns what is needed to put them
/// back; restoring keeps the original numbers and order.
public struct CubeLedger<Item>: Sequence {
    public struct Entry {
        public var id: String
        public var number: Int
        public var item: Item
        public init(id: String, number: Int, item: Item) { self.id = id; self.number = number; self.item = item }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var lastNumber = 0

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public func makeIterator() -> IndexingIterator<[Entry]> { entries.makeIterator() }

    /// A new cube: the next number.
    @discardableResult
    public mutating func add(id: String, item: Item) -> Int {
        lastNumber += 1
        entries.append(Entry(id: id, number: lastNumber, item: item))
        return lastNumber
    }

    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Remove these ids; returns the removed entries in list order.
    public mutating func remove(_ ids: Set<String>) -> [Entry] {
        let gone = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        return gone
    }

    public mutating func removeAll() -> [Entry] { remove(Set(entries.map { $0.id })) }

    /// Put entries back (an undo), sorted by number, with new ids if the caller re-created them.
    public mutating func restore(_ back: [Entry]) {
        for e in back where !entries.contains(where: { $0.id == e.id }) { entries.append(e) }
        entries.sort { $0.number < $1.number }
        lastNumber = Swift.max(lastNumber, back.map { $0.number }.max() ?? 0)
    }

    /// Numbering restarts when everything is cleared by a session reset (not by a deletion: an undo needs its number).
    public mutating func reset() { entries.removeAll(); lastNumber = 0 }
}
