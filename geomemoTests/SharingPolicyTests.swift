import Testing
import Foundation
import SwiftData
import CloudKit
@testable import geomemo

// 依頼の共有（CKShare）まわりの判断ロジックのテスト。CloudKit の実通信はシミュレータで確認できないため、
// 判断部分だけを検証する。実機での確認手順は docs/sharing.md を参照。

// MARK: - 状態遷移

@Suite("ShareStatus の遷移")
struct ShareStatusTransitionTests {

    @Test("同じ状態や後戻りは書き込まない", arguments: [
        (ShareStatus.fired, ShareStatus.fired, false),
        (.fired, .completed, false),
        (.fired, .cancelled, false),
        (.completed, .completed, false),
        (.completed, .cancelled, false),
        (.cancelled, .cancelled, false),
        (.fired, .active, true),
        (.completed, .active, true),
        (.completed, .fired, true),
        (.cancelled, .active, true),
        (.cancelled, .fired, true),
        (.cancelled, .completed, true),
    ])
    func shouldWrite(target: ShareStatus, current: ShareStatus, expected: Bool) {
        #expect(ShareStatus.shouldWrite(target, over: current) == expected)
    }

    @Test("取得した状態は、手元より進んでいるか同じときだけ受け入れる")
    func shouldAccept() {
        #expect(ShareStatus.shouldAccept(.fired, over: .active))
        #expect(ShareStatus.shouldAccept(.fired, over: .fired))
        #expect(!ShareStatus.shouldAccept(.active, over: .cancelled))
        #expect(!ShareStatus.shouldAccept(.active, over: .fired))
        #expect(!ShareStatus.shouldAccept(.fired, over: .completed))
        #expect(ShareStatus.shouldAccept(.cancelled, over: .completed))
    }

    @Test("完了・取り消しは終点")
    func terminal() {
        #expect(!ShareStatus.active.isTerminal)
        #expect(!ShareStatus.fired.isTerminal)
        #expect(ShareStatus.completed.isTerminal)
        #expect(ShareStatus.cancelled.isTerminal)
    }
}

// MARK: - SharedMemo.apply

@Suite("SharedMemo.apply の反映ルール")
struct SharedMemoApplyRuleTests {

    @Test("自分が送った依頼は、サーバのタイトル・期限で上書きしない")
    func requesterIgnoresTitleAndDeadline() {
        let shared = makeShared(isMyRequest: true)
        let data = makeData(for: shared, title: "相手が書き換えた", deadline: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(shared.apply(data) == false)
        #expect(shared.memoTitle == "元のタイトル")
        #expect(shared.memoDeadline == nil)
    }

    @Test("受け取った依頼は、依頼者が編集したタイトル・期限を反映する")
    func recipientAppliesTitleAndDeadline() {
        let shared = makeShared(isMyRequest: false)
        let deadline = Date(timeIntervalSince1970: 1_900_000_000)
        let data = makeData(for: shared, title: "編集後", deadline: deadline)
        #expect(shared.apply(data) == true)
        #expect(shared.memoTitle == "編集後")
        #expect(shared.memoDeadline == deadline)
    }

    @Test("索引が古い結果で、取り消し済みの依頼が監視中に戻らない")
    func staleActiveDoesNotRevertCancelled() {
        let shared = makeShared(isMyRequest: true)
        shared.status = .cancelled
        let data = makeData(for: shared, status: .active)
        #expect(shared.apply(data) == false)
        #expect(shared.status == .cancelled)
    }

    @Test("完了した依頼が到着済みに戻らない")
    func completedDoesNotRevertToFired() {
        let shared = makeShared(isMyRequest: false)
        let completedAt = Date()
        shared.status = .completed
        shared.completedAt = completedAt
        let data = makeData(for: shared, status: .fired, firedAt: Date())
        #expect(shared.apply(data) == false)
        #expect(shared.status == .completed)
        #expect(shared.completedAt == completedAt)
    }

    @Test("同じ状態でも日時が届けば反映する")
    func sameStatusUpdatesDates() {
        let shared = makeShared(isMyRequest: true)
        shared.status = .fired
        let firedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = makeData(for: shared, status: .fired, firedAt: firedAt)
        #expect(shared.apply(data) == true)
        #expect(shared.firedAt == firedAt)
    }

    // MARK: applyVerifiedRecipient

    @Test("招待で送った依頼は、受諾した参加者が受信者になる（新しい受信者として扱う）")
    func verifiedRecipientAppears() {
        let shared = makeShared(isMyRequest: true)
        shared.recipientRecordID = ""
        shared.recipientName = "リンクで共有"
        let result = shared.applyVerifiedRecipient(VerifiedRecipient(userRecordName: "_hanako", displayName: "花子"))
        #expect(result.changed && result.isNewRecipient)
        #expect(shared.recipientRecordID == "_hanako")
        #expect(shared.recipientName == "花子")
        // 2 回目は変化なし
        let again = shared.applyVerifiedRecipient(VerifiedRecipient(userRecordName: "_hanako", displayName: "花子"))
        #expect(!again.changed && !again.isNewRecipient)
    }

    @Test("フレンドに送った依頼は、同じ相手が受諾しても新しい受信者にならない")
    func friendRecipientIsNotNew() {
        let shared = makeShared(isMyRequest: true)
        shared.recipientRecordID = "_bob"
        shared.recipientName = "Bob"
        let result = shared.applyVerifiedRecipient(VerifiedRecipient(userRecordName: "_bob", displayName: ""))
        #expect(!result.changed && !result.isNewRecipient)
        #expect(shared.recipientName == "Bob")
    }

    @Test("名前が分からない新しい受信者は、前の名前を残さない")
    func unknownNameReplacesPlaceholder() {
        let shared = makeShared(isMyRequest: true)
        shared.recipientRecordID = ""
        shared.recipientName = "リンクで共有"
        let result = shared.applyVerifiedRecipient(VerifiedRecipient(userRecordName: "_x", displayName: ""))
        #expect(result.isNewRecipient)
        #expect(shared.recipientName != "リンクで共有")
        #expect(!shared.recipientName.isEmpty)
    }

    @Test("受け取った依頼には受信者の確定を適用しない")
    func verifiedRecipientIgnoredOnRecipientSide() {
        let shared = makeShared(isMyRequest: false)
        let result = shared.applyVerifiedRecipient(VerifiedRecipient(userRecordName: "_x", displayName: "X"))
        #expect(!result.changed && !result.isNewRecipient)
    }

    // MARK: Helpers

    private func makeShared(isMyRequest: Bool) -> SharedMemo {
        SharedMemo(
            ckRecordName: UUID().uuidString, memoTitle: "元のタイトル", memoLocationName: "L",
            memoLatitude: 0, memoLongitude: 0, memoRadius: 100,
            requesterRecordID: "r1", requesterName: "A",
            recipientRecordID: "r2", recipientName: "B",
            autoComplete: false, isMyRequest: isMyRequest
        )
    }

    private func makeData(
        for shared: SharedMemo,
        title: String? = nil,
        deadline: Date? = nil,
        status: ShareStatus? = nil,
        firedAt: Date? = nil
    ) -> SharedMemoCKData {
        let owner = shared.isMyRequest ? CKCurrentUserDefaultName : "requester"
        let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: owner)
        return SharedMemoCKData(
            ckRecordID: CKRecord.ID(recordName: shared.ckRecordName, zoneID: zoneID),
            memoTitle: title ?? shared.memoTitle, memoLocationName: shared.memoLocationName,
            memoLatitude: 0, memoLongitude: 0, memoRadius: shared.memoRadius,
            memoDeadline: deadline ?? shared.memoDeadline,
            memoTimeWindowStart: nil, memoTimeWindowEnd: nil,
            requesterName: "", recipientRecordID: "", recipientName: "",
            autoComplete: false, status: status ?? shared.status,
            firedAt: firedAt ?? shared.firedAt, completedAt: shared.completedAt,
            createdAt: Date(), isMyRequest: shared.isMyRequest
        )
    }
}

// MARK: - 受信者の決定

@Suite("SharedMemoRecipientResolver")
struct SharedMemoRecipientResolverTests {

    private let owner = ShareParticipantSummary(userRecordName: "_owner", displayName: "依頼者", isOwner: true, isAccepted: true)

    @Test("受諾した参加者がいなければ決まらない")
    func noAcceptedParticipant() {
        let pending = ShareParticipantSummary(userRecordName: "_p", displayName: "P", isOwner: false, isAccepted: false)
        #expect(SharedMemoRecipientResolver.resolve(
            participants: [owner, pending], claimedRecordName: "", claimedName: "") == nil)
    }

    @Test("所有者は受信者にしない")
    func ownerIsNeverRecipient() {
        #expect(SharedMemoRecipientResolver.resolve(
            participants: [owner], claimedRecordName: "_owner", claimedName: "なりすまし") == nil)
    }

    @Test("userRecordID が分からない参加者は受信者にしない")
    func participantWithoutRecordID() {
        let anonymous = ShareParticipantSummary(userRecordName: "", displayName: "?", isOwner: false, isAccepted: true)
        #expect(SharedMemoRecipientResolver.resolve(
            participants: [owner, anonymous], claimedRecordName: "", claimedName: "") == nil)
    }

    @Test("CloudKit の名前があればそれを使う（レコードに書かれた名前より優先）")
    func prefersCloudKitName() {
        let hanako = ShareParticipantSummary(userRecordName: "_hanako", displayName: "山田花子", isOwner: false, isAccepted: true)
        let result = SharedMemoRecipientResolver.resolve(
            participants: [owner, hanako], claimedRecordName: "_hanako", claimedName: "花子")
        #expect(result == VerifiedRecipient(userRecordName: "_hanako", displayName: "山田花子"))
    }

    @Test("CloudKit の名前が無ければ、本人がレコードに書いた名前を使う")
    func usesClaimedNameOfSamePerson() {
        let hanako = ShareParticipantSummary(userRecordName: "_hanako", displayName: "", isOwner: false, isAccepted: true)
        let result = SharedMemoRecipientResolver.resolve(
            participants: [owner, hanako], claimedRecordName: "_hanako", claimedName: " 花子 ")
        #expect(result == VerifiedRecipient(userRecordName: "_hanako", displayName: "花子"))
    }

    @Test("参加者でない人が名乗った名前は使わない")
    func ignoresClaimByNonParticipant() {
        let hanako = ShareParticipantSummary(userRecordName: "_hanako", displayName: "", isOwner: false, isAccepted: true)
        let result = SharedMemoRecipientResolver.resolve(
            participants: [owner, hanako], claimedRecordName: "_mallory", claimedName: "偽物")
        #expect(result == VerifiedRecipient(userRecordName: "_hanako", displayName: ""))
    }

    @Test("複数の参加者がいれば、名乗っている参加者を優先し、いなければ ID 順で先頭")
    func multipleParticipants() {
        let a = ShareParticipantSummary(userRecordName: "_a", displayName: "A", isOwner: false, isAccepted: true)
        let b = ShareParticipantSummary(userRecordName: "_b", displayName: "B", isOwner: false, isAccepted: true)
        #expect(SharedMemoRecipientResolver.resolve(
            participants: [owner, b, a], claimedRecordName: "_b", claimedName: "")?.userRecordName == "_b")
        #expect(SharedMemoRecipientResolver.resolve(
            participants: [owner, b, a], claimedRecordName: "", claimedName: "")?.userRecordName == "_a")
    }
}

// MARK: - リンクの送り直し

@Suite("ShareResendMethod")
struct ShareResendMethodTests {
    private let url = URL(string: "https://www.icloud.com/share/abc")!

    @Test("旧版の公開リンクは権限を変えずに同じ URL を送る")
    func legacyPublic() {
        #expect(ShareResendMethod.decide(url: url, isPublic: true, hasInvitedParticipant: false)
                == .legacyPublicURL(url))
    }

    @Test("招待済みの相手がいる非公開の共有は URL を送る")
    func privateWithParticipant() {
        #expect(ShareResendMethod.decide(url: url, isPublic: false, hasInvitedParticipant: true)
                == .invitedURL(url))
    }

    @Test("招待済みの相手がいなければシステムの共有シートで招待し直す")
    func privateWithoutParticipant() {
        #expect(ShareResendMethod.decide(url: url, isPublic: false, hasInvitedParticipant: false) == .systemInvite)
        #expect(ShareResendMethod.decide(url: nil, isPublic: false, hasInvitedParticipant: true) == .systemInvite)
    }
}

// MARK: - 本文の保持

@Suite("SharedMemoNotePolicy")
struct SharedMemoNotePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("監視中・到着済みは本文を残し、取り消しは消す")
    func activeAndCancelled() {
        #expect(SharedMemoNotePolicy.retainsReceivedNote(status: .active, completedAt: nil, now: now))
        #expect(SharedMemoNotePolicy.retainsReceivedNote(status: .fired, completedAt: nil, now: now))
        #expect(!SharedMemoNotePolicy.retainsReceivedNote(status: .cancelled, completedAt: nil, now: now))
    }

    @Test("完了は完了から一定時間だけ残す")
    func completedRetention() {
        let retention = SharedMemoNotePolicy.completedRetention
        #expect(SharedMemoNotePolicy.retainsReceivedNote(
            status: .completed, completedAt: now.addingTimeInterval(-60), now: now))
        #expect(!SharedMemoNotePolicy.retainsReceivedNote(
            status: .completed, completedAt: now.addingTimeInterval(-retention - 1), now: now))
        #expect(!SharedMemoNotePolicy.retainsReceivedNote(status: .completed, completedAt: nil, now: now))
    }
}

// MARK: - フレンドの削除記録と重複

@Suite("フレンドの削除記録と重複排除")
@MainActor
struct FriendTombstoneTests {

    private func makeStore() -> (FriendTombstoneStore, UserDefaults) {
        let suite = "test.tombstones.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FriendTombstoneStore(defaults: defaults), defaults)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: FriendConnection.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test("削除記録の追加・確認・解除")
    func addContainsRemove() {
        let (store, _) = makeStore()
        #expect(!store.contains("_bob"))
        store.add("_bob")
        store.add("_bob")
        store.add("")
        #expect(store.contains("_bob"))
        #expect(store.all == ["_bob"])
        store.remove("_bob")
        #expect(!store.contains("_bob"))
    }

    @Test("削除したフレンドは自動登録で戻らない")
    func registerSkipsTombstoned() throws {
        let (store, _) = makeStore()
        let container = try makeContainer()
        let context = container.mainContext
        store.add("_bob")
        #expect(FriendConnection.registerIfNeeded(recordID: "_bob", displayName: "Bob", in: context, tombstones: store) == false)
        #expect(FriendConnection.registerIfNeeded(recordID: "_amy", displayName: "Amy", in: context, tombstones: store) == true)
        #expect(try context.fetch(FetchDescriptor<FriendConnection>()).map(\.friendRecordID) == ["_amy"])
    }

    @Test("削除は重複分も含めて消し、削除記録を残す")
    func deleteRemovesDuplicatesAndRecordsTombstone() throws {
        let (store, _) = makeStore()
        let container = try makeContainer()
        let context = container.mainContext
        let first = FriendConnection(friendRecordID: "_bob", friendDisplayName: "Bob")
        context.insert(first)
        context.insert(FriendConnection(friendRecordID: "_bob", friendDisplayName: "Bob"))
        context.insert(FriendConnection(friendRecordID: "_amy", friendDisplayName: "Amy"))
        try context.save()

        FriendConnection.delete(recordID: "_bob", fallback: first, in: context, tombstones: store)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<FriendConnection>()).map(\.friendRecordID) == ["_amy"])
        #expect(store.contains("_bob"))
    }

    @Test("重複排除は相手ごとに最初に登録したものを残す")
    func deduplicatedKeepsEarliest() {
        let early = FriendConnection(friendRecordID: "_bob", friendDisplayName: "Bob",
                                     createdAt: Date(timeIntervalSince1970: 100))
        let late = FriendConnection(friendRecordID: "_bob", friendDisplayName: "Bob (2)",
                                    createdAt: Date(timeIntervalSince1970: 200))
        let amy = FriendConnection(friendRecordID: "_amy", friendDisplayName: "Amy",
                                   createdAt: Date(timeIntervalSince1970: 150))
        let legacyA = FriendConnection(friendRecordID: "", friendDisplayName: "?",
                                       createdAt: Date(timeIntervalSince1970: 300))
        let legacyB = FriendConnection(friendRecordID: "", friendDisplayName: "?",
                                       createdAt: Date(timeIntervalSince1970: 400))
        let result = FriendConnection.deduplicated([late, legacyB, amy, early, legacyA])
        #expect(result.map(\.friendDisplayName) == ["Bob", "Amy", "?", "?"])
        #expect(result.first?.id == early.id)
    }

    @Test("removeDuplicates は重複だけを削除する")
    func removeDuplicatesInContext() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(FriendConnection(friendRecordID: "_bob", friendDisplayName: "Bob",
                                        createdAt: Date(timeIntervalSince1970: 100)))
        context.insert(FriendConnection(friendRecordID: "_bob", friendDisplayName: "Bob (2)",
                                        createdAt: Date(timeIntervalSince1970: 200)))
        context.insert(FriendConnection(friendRecordID: "_amy", friendDisplayName: "Amy"))
        try context.save()
        #expect(FriendConnection.removeDuplicates(in: context) == true)
        try context.save()
        let names = try context.fetch(FetchDescriptor<FriendConnection>()).map(\.friendDisplayName).sorted()
        #expect(names == ["Amy", "Bob"])
        #expect(FriendConnection.removeDuplicates(in: context) == false)
    }
}

// MARK: - CKRecord からの変換

@Suite("SharedMemoCKData の共有 ID")
struct SharedMemoCKDataShareTests {

    @Test("共有の付いたレコードから共有のレコード ID を取り出す")
    func readsShareRecordID() {
        let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: CKShareService.recordType,
                              recordID: CKRecord.ID(recordName: "rec", zoneID: zoneID))
        record.encryptedValues["memoTitle"] = "T"
        record.encryptedValues["memoLocationName"] = "L"
        record.encryptedValues["memoLatitude"] = 35.0
        record.encryptedValues["memoLongitude"] = 139.0
        record["memoRadius"] = 100.0
        record["requesterName"] = "A"
        record["recipientRecordID"] = ""
        record["recipientName"] = ""
        record["autoComplete"] = 0
        record["status"] = ShareStatus.active.rawValue
        record["createdAt"] = Date()

        #expect(SharedMemoCKData(from: record, isMyRequest: true)?.shareRecordID == nil)

        let share = CKShare(rootRecord: record)
        let data = SharedMemoCKData(from: record, isMyRequest: true)
        #expect(data?.shareRecordID == share.recordID)
    }
}
