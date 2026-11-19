# ADR-0004: 依頼の共有を非公開の CKShare（参加者を明示）にする

**Status:** Accepted (2026-11)

## Context

2.0.1 までの依頼の共有は `share.publicPermission = .readWrite` で作っていた。

- 共有 URL を知っていれば誰でも参加でき、参加者は暗号化フィールド（場所・タイトル・本文）も復号して読み書きできる。
  「暗号化しているので第三者は読めない」というコメントは誤りで、`encryptedValues` は CloudKit 上での保存時暗号化にすぎない。
- 「リンクを送り直す」は同じ公開 URL を配り直すだけで、受信者の書き込み（`claimRecipient`）は先着順。
- 依頼者側は、参加者が書いた受信者名・ID をそのまま信用し、通知文やフレンド登録に使っていた。

セキュリティレビューで指摘され、共有方式の変更が承認された。

## Decision

- 新しい共有は `publicPermission = .none`。参加者を明示的に加える。
  - フレンド: userRecordID から `shareParticipants(forUserRecordIDs:)` で参加者を引き、`.readWrite` で加えてから URL を送る。
  - 新しい相手: `NSItemProvider.registerCKShare` + `CKAllowedSharingOptions(.readWrite, .specifiedRecipientsOnly)` を
    `UIActivityViewController` で表示し、システムに参加者を加えさせる。
  - `UICloudSharingController` は使わない（保存済みの共有で完了コールバックが来なかった）。
- 依頼者側の受信者は `CKShare.participants` の受諾済み参加者から決める。レコードの受信者フィールドは本人確認に使わない。
- 通知文は固定の文言にし、到着・完了後はレコードを書き換えない（購読の再通知を防ぐ）。
- 旧版で作った公開共有は変更しない（`.none` にすると公開リンクから参加した受信者が外れるため）。

詳細と実機の確認手順は [docs/sharing.md](../sharing.md)。

## Consequences

- URL が転送・漏えいしても、招待されていない人は参加できない。
- 新しい相手への招待は、共有シートで宛先が分かる送り方（メッセージ・メール）が前提になる。
- 旧版の公開共有は、依頼が終わるまで公開のまま残る（既知の制限）。
- CloudKit のスキーマ変更はない。購読は ID を `-v2` に変えて作り直す。

### 検討して見送った案

- **ワンタイム URL の参加者（`CKShare.Participant.oneTimeURLParticipant()`、iOS 18+）**: 宛先が分からないアプリ
  （LINE 等）でも送れるが、最初に開いた人が参加できる先着順のため、URL が漏れた場合の保護はシステムの招待より弱い。
- **到着・完了を小さなイベントレコードの作成で通知する**: 再通知の問題は根本的に消えるが、新しいレコードタイプと
  Production スキーマの Deploy が必要。状態の書き込みを冪等にし、到着後の更新をやめることで十分と判断した。
