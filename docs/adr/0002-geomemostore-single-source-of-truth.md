# ADR-0002: GeoMemoStore as single source of truth for shared IDs and ModelContainer

**Status:** Accepted (2026-05)

## Context

App Group ID / CloudKit container ID / Schema / ModelContainer 構築が **少なくとも 4 箇所**
で重複していた。

| 場所 | 何が重複していたか |
|---|---|
| `geomemoApp.swift` | `static let appGroupID = "group.com.yokuro.geomemo"` / `cloudKitContainerID` / `Schema([GeoMemo.self, ...])` / ModelContainer 手動構築 |
| `geomemo/GeoMemoEntity.swift` (`GeoMemoStore`) | 同じ IDs と Schema、独自の `makeContainer()` |
| `LiveActivityManager.swift` | `nonisolated private static let appGroupID = "group.com.yokuro.geomemo"` |
| `geomemoWidget/geomemoWidget.swift` | `private let appGroupID = "group.com.yokuro.geomemo"` |
| `geomemoWatch Watch App/geomemoWatchApp.swift` | `let appGroupID = "group.com.yokuro.geomemo"` |

この構造の問題：

1. **Drift リスク** — App Group ID を変えると 4-5 箇所修正しないと不整合が起きる
   （Widget target と Watch target は独立ビルドなので気付きにくい）
2. **同じ store URL を別 configuration で開くと migration が壊れる** — `GeoMemoStore`
   の初版は `Schema([GeoMemo.self])` のみ、`cloudKitDatabase: .none`、migration plan なし
   で開いていた。一方 `geomemoApp` は 5 model + private CloudKit + migration plan 付き。
   これは実バグ (P0-4) で、`geomemo.store` を別構成で 2 回開くと migration thrash や
   in-memory フォールバック（＝ユーザデータ喪失）を引き起こす
3. **App Intent / Spotlight のたびに ModelContainer を再構築** — SQLite + CloudKit
   初期化で 100ms+ かかる hot path

## Decision

**`GeoMemoStore` を single source of truth として集約する。**

### Same-target 集約（app target 内）

`geomemo/GeoMemoEntity.swift` の `GeoMemoStore` に以下を集約：

```swift
enum GeoMemoStore {
    static let appGroupID          = "group.com.yokuro.geomemo"
    static let cloudKitContainerID = "iCloud.com.yokuro.geomemo"

    nonisolated static func makeSchema() -> Schema { ... }
    nonisolated static func makeContainer() throws -> ModelContainer { ... }
    nonisolated static func sharedContainer() throws -> ModelContainer { ... }

    // ...
}
```

- `geomemoApp.appGroupID` / `cloudKitContainerID` は `GeoMemoStore` への forward に置き換え
- `geomemoApp.sharedModelContainer` は `GeoMemoStore.sharedContainer()` に委譲。
  テスト・CloudKit 失敗時のみ in-memory フォールバック
- `LiveActivityManager.lookupMemo` も自前の ModelContainer を捨てて `sharedContainer()`
  経由に

### Cross-target ミラー（Widget / Watch）

Widget 拡張と Watch app は **別ターゲット** なので `GeoMemoStore` を直接参照できない。
これらは各 target 内に **mirror 定数** を保持し、コメントで同期義務を明示する。

```swift
// geomemoWidget.swift
private enum WidgetDeepLink {
    static let scheme = "geomemo"           // geomemoApp.deepLinkScheme と同期
    static let memoHost = "memo"            // geomemoApp.DeepLinkHost.memo と同期
    static let fallback = URL(string: "\(scheme)://")!
}
```

将来的にはこれらの共通コードを **shared Swift package** に切り出す方針だが、
target 追加はリスクを伴うので次バージョン以降に先送り。

### ModelContainer キャッシュ

`GeoMemoStore.sharedContainer()` は **プロセス全体で 1 インスタンス** を再利用する。

```swift
private static let cachedContainerBox = ContainerBox()

nonisolated private final class ContainerBox: @unchecked Sendable {
    let lock = NSLock()
    var container: ModelContainer?
}

nonisolated static func sharedContainer() throws -> ModelContainer {
    cachedContainerBox.lock.lock()
    defer { cachedContainerBox.lock.unlock() }
    if let c = cachedContainerBox.container { return c }
    let c = try makeContainer()
    cachedContainerBox.container = c
    return c
}
```

- `NSLock` で thread-safe（App Intent は複数スレッドから呼ばれうる）
- 初回失敗時は `container` に nil のまま残るので次回再試行される
- `@unchecked Sendable` + `nonisolated` で `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  の環境下でも nonisolated context から触れる

## Consequences

### Pros

- App Group ID / CloudKit ID / Schema の drift を排除
- 同一 store URL の二重構成問題（P0-4）が根本解決
- App Intent / Spotlight レイテンシが container 初期化ぶん改善
- テストと本番で構成が一致する（テストのみ in-memory）

### Cons

- **Cross-target の string constants が依然として mirror 定義**
  → 将来 shared package で解消予定
- **container キャッシュは "健全" な失敗を想定していない**
  初回 open 成功後にファイルが破壊されても新しいコンテナは作らない
  → 現状は再起動で復旧するので許容

### 実装上の注意点

- `nonisolated final class ContainerBox: @unchecked Sendable` を付けないと、
  Swift 6 strict concurrency で「main actor-isolated static property が nonisolated
  context から参照不可」の警告が出る
- `nonisolated(unsafe)` は `@unchecked Sendable` 型では不要（warning）。ただし
  `nonisolated` は必要
- `SortDescriptor(\.isFavorite, order: .reverse)` は使えない（Bool: Comparable でない）。
  `createdAt` で SQL 側 sort し、`isFavorite` の優先付けは Swift 側で行う

## References

- 該当コミット: `0f7a536` (Tier 1 P0-4), `20a8193` (Post-review CR-1, CR-7)
- 主要ファイル: `geomemo/GeoMemoEntity.swift`, `geomemo/geomemoApp.swift`,
  `LiveActivityManager.swift`
- 関連 ADR: [ADR-0001](0001-swiftdata-schema-snapshots.md)
