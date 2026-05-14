import Foundation
import CloudKit

// MARK: - Pending Event（オフライン時の CloudKit 書き込みキュー）

/// CKShare 経由のレコード更新リトライ用イベント。
/// `zoneOwnerName` は CKRecordZone.ID の ownerName（自分の依頼=CKCurrentUserDefaultName、
/// 受け取った依頼=共有者の iCloud RecordID）を保持する。
enum PendingShareEvent: Codable {
    case fired(ckRecordName: String, zoneOwnerName: String, firedAt: Date)
    case completed(ckRecordName: String, zoneOwnerName: String, completedAt: Date)
    case cancelled(ckRecordName: String, zoneOwnerName: String)
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
            case .fired(let name, _, _):     return name != ckRecordName
            case .completed(let name, _, _): return name != ckRecordName
            case .cancelled(let name, _):    return name != ckRecordName
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
                case .fired(let name, let owner, let firedAt):
                    let recordID = makeRecordID(name: name, owner: owner)
                    try await CKShareService.shared.updateStatus(recordID: recordID, status: .fired, date: firedAt)
                case .completed(let name, let owner, let completedAt):
                    let recordID = makeRecordID(name: name, owner: owner)
                    try await CKShareService.shared.updateStatus(recordID: recordID, status: .completed, date: completedAt)
                case .cancelled(let name, let owner):
                    let recordID = makeRecordID(name: name, owner: owner)
                    try await CKShareService.shared.cancelSharedMemo(recordID: recordID)
                }
                remove(event)
            } catch { /* 失敗時はキューに残して次回再試行 */ }
        }
    }

    private func makeRecordID(name: String, owner: String) -> CKRecord.ID {
        let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: owner)
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    var all: [PendingShareEvent] { events }
    var isEmpty: Bool { events.isEmpty }

    /// テスト用: in-memory cache と UserDefaults の両方をクリアする
    func resetForTesting() {
        _cache = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    // PendingShareEvent には Equatable がない（CK 識別子＋日付の組合せで等価判定する）
    private static func areEqual(_ a: PendingShareEvent, _ b: PendingShareEvent) -> Bool {
        switch (a, b) {
        case (.fired(let n1, let o1, let d1), .fired(let n2, let o2, let d2)):
            return n1 == n2 && o1 == o2 && d1 == d2
        case (.completed(let n1, let o1, let d1), .completed(let n2, let o2, let d2)):
            return n1 == n2 && o1 == o2 && d1 == d2
        case (.cancelled(let n1, let o1), .cancelled(let n2, let o2)):
            return n1 == n2 && o1 == o2
        default: return false
        }
    }
}
