# ADR-0003: Defer CLMonitor migration; retain CLLocationManager + delegate

**Status:** Deferred (2026-05)

## Context

iOS 17 で `CLCircularRegion` / `CLLocationManager.isMonitoringAvailable(for:)` /
`CLLocationManager.startMonitoring(for:)` などのジオフェンス系 API が deprecated
となり、後継として `CLMonitor` + `CLMonitor.CircularGeographicCondition` が導入された。

デスクレビュー (Tier 3) で移行を推奨されたが、影響範囲を調査した結果：

- **5 ファイル / 17 箇所**
  - `geomemo/LocationManager.swift` — 大半（monitor lifecycle, delegate）
  - `geomemo/ContentView.swift` — `reRegisterAllGeofences`, `.onChange(of: memos)`
  - `geomemo/MemoEditorView.swift` — save 時の geofence 登録
  - `geomemo/GeoMemo.swift` — `region` computed property
  - `geomemoTests/geomemoTests.swift` — 既存の geofence テスト
- API 構造そのものが違う
  - **旧**: `CLLocationManagerDelegate` の `didEnterRegion` / `didExitRegion` /
    `didFailWithError` にコールバック
  - **新**: `for await event in monitor.events { ... }` の async stream
- **ルートトリガー** と **共有メモジオフェンス** も同じ `CLLocationManager` に相乗り
  しているので、片方だけ移行するのは困難
- 移行後の挙動が実機で確認できないと保証できない（4 シナリオ検証必須：
  通常進入退出、ルート多段、共有メモ、監視失敗）

同セッション内で他 55 タスクを実装しリリース (2.0.1) を作った状況で、これほど大きな
書き換えを更に含めるのはリスクが高いと判断した。

## Decision

**CLMonitor 移行は次セッション以降に defer する。**

- 現行の CLLocationManager + `CLCircularRegion` を維持
- deprecation warning は許容（実行時挙動は問題ない）
- 該当タスクは `T3-1 [DEFERRED]` として TaskList に残す

移行を再開する際の推奨手順：

1. **専用ブランチを切る** — `feat/clmonitor-migration` など
2. **小さなステップに分割**（PR 単位）
   - a. `CLMonitor` インフラを LocationManager に並列に追加（既存パスは触らない）
   - b. 通常メモの geofence だけ CLMonitor に移す（feature flag / build config で切替可能に）
   - c. 共有メモの geofence を移す
   - d. ルートトリガーを移す（多段状態機械の書き換え）
   - e. 旧 API 呼び出しを削除、delegate 完全撤去
3. **各 PR の実機テスト** — 4 シナリオ全てをパスさせる
4. **移行完了後 ADR-0003 を Superseded に更新**して新 ADR で決定内容を記録

## Consequences

### Pros

- 既に安定している geofence 挙動を壊すリスクを回避
- 2.0.1 リリースを予定通り出せる
- 移行時に集中的なテスト時間を確保できる

### Cons

- deprecation warning が build ログに残り続ける
- 将来 Apple が該当 API を削除した際に緊急対応が必要になる可能性
- コードベースの「モダン化度」が下がる

### 実装のヒント（次セッションへ）

- `CLMonitor.create(name:)` は async。LocationManager `@MainActor` isolation
  と統合する際、初期化タイミングを SplashView か geomemoApp の `.task` で扱うのが良い
- Delegate callback を捨てるため、`nonisolated func locationManager(_ manager:...)`
  で書いていた `MainActor.assumeIsolated` ブリッジはすべて除去できる
- ContentView の `.onReceive(NotificationCenter.default.publisher(for: ...))`
  ベースの通知配信も、CLMonitor.events を直接 View レイヤで購読する形に置き換え可能
  （ただし notification-based fan-out は Live Activity trigger 等でも使われている
  ので慎重に）
- `CLCircularRegion` に紐付いていた `|wp|` 区切り identifier（ルートウェイポイント）と
  `shared_` プレフィックス（共有メモ）は `CLMonitor.Identifier` にそのまま流用可能

## References

- 該当タスク: `T3-1 [DEFERRED]`
- 該当ファイル: `geomemo/LocationManager.swift:184-247`,
  `geomemo/ContentView.swift:1122-1148`, `geomemo/MemoEditorView.swift:1216-1240`,
  `geomemo/GeoMemo.swift:66-68`
- Apple のガイド:
  <https://developer.apple.com/documentation/corelocation/clmonitor>
