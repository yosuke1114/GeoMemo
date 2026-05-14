import Foundation

// MARK: - Pending Event（オフライン時の CloudKit 書き込みキュー）

enum PendingShareEvent: Codable {
    case fired(ckRecordName: String, firedAt: Date)
    case completed(ckRecordName: String, completedAt: Date)
    case cancelled(ckRecordName: String)
}

@MainActor
final class PendingEventQueue {
    static let shared = PendingEventQueue()

    private let key = "pendingShareEvents"
    private var _cache: [PendingShareEvent]?

    private var events: [PendingShareEvent] {
        get {
            if let c = _cache { return c }
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([PendingShareEvent].self, from: data)
            else { _cache = []; return [] }
            _cache = decoded
            return decoded
        }
        set {
            _cache = newValue
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    func enqueue(_ event: PendingShareEvent) {
        var current = events
        current.append(event)
        events = current
    }

    func dequeue(ckRecordName: String) {
        events = events.filter { event in
            switch event {
            case .fired(let name, _):     return name != ckRecordName
            case .completed(let name, _): return name != ckRecordName
            case .cancelled(let name):    return name != ckRecordName
            }
        }
    }

    var all: [PendingShareEvent] { events }
    var isEmpty: Bool { events.isEmpty }
}
