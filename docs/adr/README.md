# Architecture Decision Records

このディレクトリには GeoMemo の主要な architectural decision を記録する。
新規追加時は連番でファイル名を付けて以下の index に追記すること。

## フォーマット

各 ADR は以下のセクションを持つ。

1. **Status** — Accepted / Superseded / Deferred など
2. **Context** — なぜこの決定が必要になったか
3. **Decision** — 決めたこと
4. **Consequences** — 決定によって得られたもの・失ったもの・注意点

## Index

| # | Title | Status |
|---|---|---|
| 0001 | [SwiftData schema versioning by snapshot models](0001-swiftdata-schema-snapshots.md) | Accepted (2026-05) |
| 0002 | [GeoMemoStore as single source of truth for shared IDs and ModelContainer](0002-geomemostore-single-source-of-truth.md) | Accepted (2026-05) |
| 0003 | [Defer CLMonitor migration; retain CLLocationManager + delegate](0003-defer-clmonitor-migration.md) | Deferred (2026-05) |
