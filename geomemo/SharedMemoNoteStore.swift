import Foundation

/// 依頼メモの本文を、共有レコード名 (`SharedMemo.ckRecordName`) ごとに保持する。
///
/// 本文は SwiftData の `SharedMemo` に列を足さずに App Group の UserDefaults へ置いている。
/// 2.0.1 時点ではスキーマ移行（docs/adr/0001）が既存ストアで失敗したため、この形で回避した。
/// 移行は直したので、将来 `SharedMemo` に列を足す際はこちらから移すこと。
enum SharedMemoNoteStore {
    private static let key = "sharedMemoNotes"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: GeoMemoStore.appGroupID) }

    static func note(for recordName: String) -> String {
        guard !recordName.isEmpty else { return "" }
        return (defaults?.dictionary(forKey: key) as? [String: String])?[recordName] ?? ""
    }

    static func setNote(_ note: String, for recordName: String) {
        guard !recordName.isEmpty, let defaults else { return }
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all[recordName] != (note.isEmpty ? nil : note) else { return }
        all[recordName] = note.isEmpty ? nil : note
        defaults.set(all, forKey: key)
    }
}
