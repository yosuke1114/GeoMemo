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

    /// 同じ ckRecordName の単一イベントだけ削除（drain中の個別成功を反映）
    private func remove(_ target: PendingShareEvent) {
        events = events.filter { !Self.areEqual($0, target) }
    }

    /// キューに溜まったイベントを順次 CloudKit へ flush する。
    /// - 成功したイベントだけ dequeue する。失敗したものは残してリトライ余地を残す。
    /// - 起動時 / フォアグラウンド復帰時に呼ぶ。
    func drain() async {
        guard !events.isEmpty else { return }
        let snapshot = events
        for event in snapshot {
            do {
                switch event {
                case .fired(let name, let firedAt):
                    try await CloudKitShareService.shared.updateStatus(name, status: .fired, date: firedAt)
                case .completed(let name, let completedAt):
                    try await CloudKitShareService.shared.updateStatus(name, status: .completed, date: completedAt)
                case .cancelled(let name):
                    try await CloudKitShareService.shared.cancelSharedMemo(name)
                }
                remove(event)
            } catch { /* 失敗時はキューに残して次回再試行 */ }
        }
    }

    var all: [PendingShareEvent] { events }
    var isEmpty: Bool { events.isEmpty }

    // PendingShareEvent には Equatable がない（CK 識別子＋日付の組合せで等価判定する）
    private static func areEqual(_ a: PendingShareEvent, _ b: PendingShareEvent) -> Bool {
        switch (a, b) {
        case (.fired(let n1, let d1), .fired(let n2, let d2)):
            return n1 == n2 && d1 == d2
        case (.completed(let n1, let d1), .completed(let n2, let d2)):
            return n1 == n2 && d1 == d2
        case (.cancelled(let n1), .cancelled(let n2)):
            return n1 == n2
        default: return false
        }
    }
}
