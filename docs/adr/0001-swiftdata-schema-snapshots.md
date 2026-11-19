# ADR-0001: SwiftData schema versioning by snapshot models

**Status:** Accepted (2026-05)

## Context

`GeoMemoMigrationPlan.swift` の `VersionedSchema` V1〜V5 は各 version 内で
`@Model final class GeoMemoV1` のようにスナップショット型を独立定義していた。しかし
V6〜V8 はそのパターンから逸脱し、**live model 型**（`GeoMemo.self`,
`FavoritePlace.self`, `UserProfile.self`, `FriendConnection.self`, `SharedMemo.self`）を
直接参照していた。

```swift
// 悪い例（V6/V7/V8 の元コード）
enum GeoMemoSchemaV6: VersionedSchema {
    static var models: [any PersistentModel.Type] {
        [GeoMemo.self, FavoritePlace.self]   // ← live 型を直接参照
    }
}
```

この構造の問題：

- Live model にプロパティを追加・削除・型変更すると、V6 の "history" 自体が silently
  書き換わる
- 旧バージョン store から V6 への migration path が壊れる（旧ユーザーがクラッシュ）
- SwiftData の VersionedSchema は「その時点の schema を凍結する」ことが前提の設計だが、
  live 型参照はその前提を壊す

デスクレビューで指摘され、次のリリース (2.0.1) に含めることにした。

## Decision

**各 VersionedSchema の中で該当バージョンの model 型をスナップショットとして独立定義する。**

- V1〜V5 は既にスナップショット型を持っていたのでそのまま
- **V6〜V8 に snapshot 型を追加**:
  - `GeoMemoSchemaV6.FavoritePlaceV6`
  - `GeoMemoSchemaV7.UserProfileV7`, `FriendConnectionV7`
  - `GeoMemoSchemaV8.SharedMemoV8`
- 変更のないモデルは前 version のスナップショット型を **再利用** する
  - V6 の `GeoMemo` は `GeoMemoSchemaV5.GeoMemoV5.self` を流用
  - V7 の `FavoritePlace` は `GeoMemoSchemaV6.FavoritePlaceV6.self` を流用

将来の変更ルール:

> **live `GeoMemo` / `FavoritePlace` / `UserProfile` / `FriendConnection` /
> `SharedMemo` の schema を変更したら、`SchemaV9` を新設して該当 model の
> スナップショットを作成し、migration stage を追加すること。**

このルールは `GeoMemoMigrationPlan.swift:236-239` のコメントとしても記載した。

## Consequences

### Pros

- Live model 変更が既存の migration history を書き換えない
- 旧バージョンからの migration path が確実に保存される
- SwiftData の VersionedSchema 設計と一致

### Cons

- スナップショット型のコード重複が発生する（実 model と同じフィールドを繰り返す）
- 新規モデルフィールド追加時に SchemaVN の作成を忘れる可能性
  → コメントによる warning と、次パッチでは lint / CI check を導入検討

### 副次的な変更

- `SharedMemoV8` に `requesterRecordID` を含めた（ADR-0002 と別件の P0-3 修正で
  live SharedMemo に永続化した field）
- MainActor isolation との調整で `nonisolated static let cachedContainerBox` を
  `GeoMemoStore` に配置（ADR-0002 参照）

## References

- 該当コミット: `0f7a536` (Tier 1)
- 主要ファイル: `geomemo/GeoMemoMigrationPlan.swift`
- 関連 ADR: [ADR-0002](0002-geomemostore-single-source-of-truth.md)

## 既知の問題（2026-11 追記）

スナップショット型の **型名が live model と異なる**（`SharedMemoV8`, `GeoMemoV5` 等）ため、
SwiftData の entity 名も異なり、既存ストア（live 名で作られている）がどの VersionedSchema の
ハッシュにも一致しない。live model に列を 1 つ足しただけで、既存ストアを開くと
`NSCocoaErrorDomain 134504 "Cannot use staged migration with an unknown coordinator model version"`
で失敗する（V9 で memoNote を追加しようとして判明、撤回済み）。

- 2.0.1 では SwiftData のスキーマを変えず、共有メモ本文は `SharedMemoNoteStore`（App Group UserDefaults）に保持して回避した
- **次に SwiftData のスキーマを変える前に**、スナップショット型を live と同名の入れ子型
  （例: `enum GeoMemoSchemaV8 { @Model final class SharedMemo { ... } }`）に揃え、
  実ストア（2.0 / 2.0.1 で作られたもの）からの移行をオンディスクのテストで確認すること

## 修正（2026-11 追記）

スナップショット型をすべて live model と同名の入れ子型に改名した（例: `GeoMemoSchemaV5.GeoMemo`,
`GeoMemoSchemaV8.SharedMemo`）。これで端末のストア（live 名）が各 VersionedSchema に一致し、
staged migration が既存ストアを識別できる。

- 1.3.x（V5 相当）のストアは、修正前の計画では 134504 で開けず、アプリはメモリ上の空ストアで起動していた
  （ストアファイル自体は削除されないため、修正版への更新で復旧する）
- `geomemoTests/MigrationStoreTests.swift` で次を検証する
  - V1〜最新の各スキーマで作ったストアが現行の計画で開ける
  - 1.3.x / 2.0 相当の実ストアが開ける
  - 最新の VersionedSchema と live model が一致している（スナップショット追加忘れの検知）
- 列追加（V9 で SharedMemo.memoNote を足す）を試行し、V8→V9 と V5→V9 の移行が通ることを確認済み
