import Foundation

/// 依頼メモの本文を、共有レコード名 (`SharedMemo.ckRecordName`) ごとに保持する。
///
/// 本文は SwiftData の `SharedMemo` に列を足さずに App Group の UserDefaults へ置く。
/// 現行の VersionedSchema スナップショットは entity 名が live model と異なり
/// (`SharedMemoV8` 等)、列追加の staged migration が既存ストアで失敗するため
/// (docs/adr/0001 参照)。スキーマ移行を直すまではここで持つ。
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
