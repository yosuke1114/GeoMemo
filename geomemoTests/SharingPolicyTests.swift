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

    @Test("同じ状態や後戻り、終点（完了・取り消し）の後は書き込まない", arguments: [
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
        // 再送キューに残った「取り消し」が、その後に相手が付けた「完了」を上書きしない
        (.cancelled, .completed, false),
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
        #expect(result == VerifiedRecipient(userRecordName: "_hanako", displayName: "山田花子", nameIsFromCloudKit: true))
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

    @Test("削除した日時を覚える（2 回目の追加では変えない）")
    func remembersDeletionDate() {
        let (store, _) = makeStore()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        store.add("_bob", at: first)
        store.add("_bob", at: first.addingTimeInterval(100))
        #expect(store.deletedAt("_bob") == first)
        #expect(store.deletedAt("_amy") == nil)
        #expect(store.deletedAt("") == nil)
    }

    @Test("以前の形式（ID の配列）の記録を読み込んで移す")
    func migratesLegacyFormat() {
        let (store, defaults) = makeStore()
        defaults.set(["_bob", "", "_amy"], forKey: "deletedFriendRecordIDs")
        let before = Date()
        #expect(store.all == ["_bob", "_amy"])
        #expect(defaults.object(forKey: "deletedFriendRecordIDs") == nil)
        #expect((store.deletedAt("_bob") ?? .distantPast) >= before.addingTimeInterval(-1))
        store.remove("_bob")
        #expect(store.all == ["_amy"])
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

// MARK: - フレンドの自動登録（依頼者側）

@Suite("FriendAutoRegistrationPolicy")
struct FriendAutoRegistrationPolicyTests {
    private let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("新しく受信者が決まり、削除の記録が無ければ登録する")
    func registersNewRecipient() {
        #expect(FriendAutoRegistrationPolicy.decide(
            isPublicShare: false, isNewRecipient: true, requestSentAt: deletedAt, tombstonedAt: nil) == .register)
    }

    @Test("受信者が新しくなければ登録しない")
    func skipsKnownRecipient() {
        #expect(FriendAutoRegistrationPolicy.decide(
            isPublicShare: false, isNewRecipient: false, requestSentAt: deletedAt, tombstonedAt: nil) == .skip)
    }

    @Test("旧版の公開リンクの共有では登録しない（表示だけ）")
    func skipsPublicShare() {
        #expect(FriendAutoRegistrationPolicy.decide(
            isPublicShare: true, isNewRecipient: true, requestSentAt: deletedAt, tombstonedAt: nil) == .skip)
    }

    @Test("削除する前に送った依頼では、削除したフレンドを登録し直さない")
    func skipsTombstonedForOlderRequest() {
        #expect(FriendAutoRegistrationPolicy.decide(
            isPublicShare: false, isNewRecipient: true,
            requestSentAt: deletedAt.addingTimeInterval(-60), tombstonedAt: deletedAt) == .skip)
    }

    @Test("削除した後に自分で招待して送った依頼なら、削除の記録を外して登録し直す")
    func reRegistersAfterExplicitInvite() {
        #expect(FriendAutoRegistrationPolicy.decide(
            isPublicShare: false, isNewRecipient: true,
            requestSentAt: deletedAt.addingTimeInterval(60), tombstonedAt: deletedAt) == .registerClearingTombstone)
        // 公開リンクの共有では、削除後でも登録し直さない
        #expect(FriendAutoRegistrationPolicy.decide(
            isPublicShare: true, isNewRecipient: true,
            requestSentAt: deletedAt.addingTimeInterval(60), tombstonedAt: deletedAt) == .skip)
    }
}

// MARK: - 本人確認できたフレンド

@Suite("本人確認できたフレンド")
@MainActor
struct VerifiedFriendTests {

    private func makeStore() -> VerifiedFriendStore {
        let suite = "test.verified.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return VerifiedFriendStore(defaults: defaults)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: FriendConnection.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test("確認済みの記録の追加と確認")
    func addAndContains() {
        let store = makeStore()
        #expect(!store.contains("_bob"))
        store.add("_bob")
        store.add("_bob")
        store.add("")
        #expect(store.contains("_bob"))
        #expect(!store.contains(""))
        #expect(store.all == ["_bob"])
    }

    @Test("CloudKit の情報から新しく登録したフレンドは確認済みになる")
    func registerMarksVerified() throws {
        let store = makeStore()
        let container = try makeContainer()
        let context = container.mainContext
        #expect(FriendConnection.registerIfNeeded(recordID: "_amy", displayName: "Amy", in: context, verified: store))
        #expect(store.contains("_amy"))
        // 確認の記録を渡さない登録（旧版と同じ経路）は確認済みにしない
        #expect(FriendConnection.registerIfNeeded(recordID: "_bob", displayName: "Bob", in: context))
        #expect(!store.contains("_bob"))
    }

    @Test("CloudKit の名前で、なりすました名前のフレンドを直して確認済みにする")
    func confirmIdentityRenames() throws {
        let store = makeStore()
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(FriendConnection(friendRecordID: "_mallory", friendDisplayName: "母"))
        context.insert(FriendConnection(friendRecordID: "_mallory", friendDisplayName: "母"))
        try context.save()

        #expect(FriendConnection.confirmIdentity(recordID: "_mallory", cloudKitName: " Mallory ",
                                                 in: context, verified: store))
        let names = try context.fetch(FetchDescriptor<FriendConnection>()).map(\.friendDisplayName)
        #expect(names == ["Mallory", "Mallory"])
        #expect(store.contains("_mallory"))
        // 同じ名前なら変更なし（確認済みのまま）
        #expect(!FriendConnection.confirmIdentity(recordID: "_mallory", cloudKitName: "Mallory",
                                                  in: context, verified: store))
    }

    @Test("CloudKit の名前が分からなければ、確認済みにしない")
    func confirmIdentityWithoutName() throws {
        let store = makeStore()
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(FriendConnection(friendRecordID: "_x", friendDisplayName: "母"))
        try context.save()
        #expect(!FriendConnection.confirmIdentity(recordID: "_x", cloudKitName: "", in: context, verified: store))
        #expect(!store.contains("_x"))
        #expect(try context.fetch(FetchDescriptor<FriendConnection>()).first?.friendDisplayName == "母")
    }

    @Test("登録していない相手は確認済みにしない")
    func confirmIdentityOfUnknownFriend() throws {
        let store = makeStore()
        let container = try makeContainer()
        let context = container.mainContext
        #expect(!FriendConnection.confirmIdentity(recordID: "_y", cloudKitName: "Y", in: context, verified: store))
        #expect(!store.contains("_y"))
        #expect(try context.fetch(FetchDescriptor<FriendConnection>()).isEmpty)
    }
}

// MARK: - 共有シートの結果

@Suite("ShareSheetCompletionTracker")
struct ShareSheetCompletionTrackerTests {
    private let message = "com.apple.UIKit.activity.Message"
    private let line = "jp.naver.line.Share"

    @Test("何も選ばずに閉じたら「送らなかった」")
    func closedWithoutActivity() {
        var tracker = ShareSheetCompletionTracker()
        #expect(tracker.record(activityType: nil, completed: false) == .notSent)
        #expect(tracker.sheetDismissedWithoutResult() == nil)
    }

    @Test("送信が完了したら「送った」")
    func sent() {
        var tracker = ShareSheetCompletionTracker()
        #expect(tracker.record(activityType: message, completed: true) == .sent)
        #expect(tracker.record(activityType: nil, completed: false) == nil)
        #expect(tracker.sheetDismissedWithoutResult() == nil)
    }

    @Test("メッセージの作成をキャンセルしても決めず、続けて別のアプリで送れば「送った」")
    func cancelledComposeThenSentElsewhere() {
        var tracker = ShareSheetCompletionTracker()
        #expect(tracker.record(activityType: message, completed: false) == nil)
        #expect(tracker.record(activityType: line, completed: true) == .sent)
    }

    @Test("作成をキャンセルしてから共有シートを閉じたら「送らなかった」")
    func cancelledComposeThenClosed() {
        var tracker = ShareSheetCompletionTracker()
        #expect(tracker.record(activityType: message, completed: false) == nil)
        #expect(tracker.record(activityType: nil, completed: false) == .notSent)
    }

    @Test("閉じたのに結果が来なければ「分からない」。後から送信完了が届けば「送った」に改める")
    func dismissedWithoutResult() {
        var tracker = ShareSheetCompletionTracker()
        #expect(tracker.record(activityType: line, completed: false) == nil)
        #expect(tracker.sheetDismissedWithoutResult() == .unknown)
        #expect(tracker.sheetDismissedWithoutResult() == nil)
        // 「分からない」の後の「閉じた」は、消す理由にしない
        #expect(tracker.record(activityType: nil, completed: false) == nil)
        #expect(tracker.record(activityType: line, completed: true) == .sent)
        #expect(tracker.record(activityType: line, completed: true) == nil)
    }

    @Test("完了ハンドラが一度も呼ばれずに閉じたら「分からない」")
    func dismissedWithoutAnyCallback() {
        var tracker = ShareSheetCompletionTracker()
        #expect(tracker.sheetDismissedWithoutResult() == .unknown)
    }
}

// MARK: - 送らなかった依頼の後片付け

@Suite("UnsentShareCleanupPolicy")
struct UnsentShareCleanupPolicyTests {
    private let owner = ShareParticipantSummary(userRecordName: "_owner", displayName: "", isOwner: true, isAccepted: true)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ state: UnsentShareEntry.State, friend: String = "", age: TimeInterval = 0) -> UnsentShareEntry {
        UnsentShareEntry(recordName: "rec", shareRecordName: "share", invitedFriendRecordName: friend,
                         createdAt: now.addingTimeInterval(-age), state: state)
    }

    @Test("所有者しかいなければ消せる。取り除かれた参加者は数えない")
    func ownerOnly() {
        let removed = ShareParticipantSummary(userRecordName: "_r", displayName: "", isOwner: false,
                                              isAccepted: false, isInvited: false)
        #expect(UnsentShareCleanupPolicy.canDelete(participants: [owner], allowedInviteeRecordName: nil))
        #expect(UnsentShareCleanupPolicy.canDelete(participants: [owner, removed], allowedInviteeRecordName: nil))
    }

    @Test("受諾した人がいれば、例外の相手でも消さない")
    func acceptedParticipantBlocks() {
        let accepted = ShareParticipantSummary(userRecordName: "_bob", displayName: "", isOwner: false, isAccepted: true)
        #expect(!UnsentShareCleanupPolicy.canDelete(participants: [owner, accepted], allowedInviteeRecordName: nil))
        #expect(!UnsentShareCleanupPolicy.canDelete(participants: [owner, accepted], allowedInviteeRecordName: "_bob"))
    }

    @Test("招待中の人がいれば消さない。自分で加えたフレンド（URL を送っていない）だけは例外にできる")
    func invitedParticipant() {
        let friend = ShareParticipantSummary(userRecordName: "_bob", displayName: "", isOwner: false,
                                             isAccepted: false, isInvited: true)
        let other = ShareParticipantSummary(userRecordName: "", displayName: "", isOwner: false,
                                            isAccepted: false, isInvited: true)
        #expect(!UnsentShareCleanupPolicy.canDelete(participants: [owner, friend], allowedInviteeRecordName: nil))
        #expect(UnsentShareCleanupPolicy.canDelete(participants: [owner, friend], allowedInviteeRecordName: "_bob"))
        #expect(!UnsentShareCleanupPolicy.canDelete(participants: [owner, friend, other], allowedInviteeRecordName: "_bob"))
        #expect(!UnsentShareCleanupPolicy.canDelete(participants: [owner, other], allowedInviteeRecordName: ""))
    }

    @Test("送らずに閉じた依頼は、フレンドを例外にして消し直す")
    func discarding() {
        #expect(UnsentShareCleanupPolicy.action(for: entry(.discarding, friend: "_bob"), now: now)
                == .delete(allowedInviteeRecordName: "_bob"))
        #expect(UnsentShareCleanupPolicy.action(for: entry(.discarding), now: now)
                == .delete(allowedInviteeRecordName: nil))
    }

    @Test("結果の分からないまま残った依頼は、時間が経ってから、例外なしで消す")
    func orphanedPresenting() {
        let age = UnsentShareCleanupPolicy.orphanAge
        #expect(UnsentShareCleanupPolicy.action(for: entry(.presenting, friend: "_bob", age: age - 1), now: now) == .leave)
        #expect(UnsentShareCleanupPolicy.action(for: entry(.presenting, friend: "_bob", age: age), now: now)
                == .delete(allowedInviteeRecordName: nil))
    }

    @Test("「未送信」として残した依頼は自動では消さない")
    func keptIsLeft() {
        #expect(UnsentShareCleanupPolicy.action(for: entry(.kept, age: 86_400), now: now) == .leave)
    }

    @Test("参加者の既定値は招待中でない")
    func participantDefault() {
        #expect(!ShareParticipantSummary(userRecordName: "_a", displayName: "", isOwner: false, isAccepted: false).isInvited)
    }
}

@Suite("UnsentShareStore")
@MainActor
struct UnsentShareStoreTests {

    private func makeStore() -> UnsentShareStore {
        let suite = "test.unsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UnsentShareStore(defaults: defaults)
    }

    @Test("追加・状態の変更・削除")
    func upsertSetStateRemove() {
        let store = makeStore()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        store.upsert(UnsentShareEntry(recordName: "a", shareRecordName: "sa", invitedFriendRecordName: "_bob",
                                      createdAt: created, state: .presenting))
        store.upsert(UnsentShareEntry(recordName: "b", shareRecordName: "sb", invitedFriendRecordName: "",
                                      createdAt: created, state: .presenting))
        #expect(store.entries.count == 2)
        #expect(store.keptRecordNames.isEmpty)

        store.setState(.kept, for: "a")
        #expect(store.entry(for: "a")?.state == .kept)
        #expect(store.entry(for: "a")?.invitedFriendRecordName == "_bob")
        #expect(store.entry(for: "a")?.createdAt == created)
        #expect(store.keptRecordNames == ["a"])

        // 同じレコードの追加は置き換え
        store.upsert(UnsentShareEntry(recordName: "b", shareRecordName: "sb", invitedFriendRecordName: "",
                                      createdAt: created, state: .discarding))
        #expect(store.entries.count == 2)
        #expect(store.entry(for: "b")?.state == .discarding)

        store.remove("a")
        store.remove("missing")
        store.setState(.kept, for: "missing")
        #expect(store.entries.map(\.recordName) == ["b"])
    }
}

// MARK: - 送信後の編集で本文を書き込むか

@Suite("SharedMemoNoteEditPolicy")
struct SharedMemoNoteEditPolicyTests {

    @Test("サーバから読めた本文は、そのまま保存する")
    func fromServer() {
        #expect(SharedMemoNoteEditPolicy.noteToSave(source: .server, loaded: "a", current: "a") == "a")
        #expect(SharedMemoNoteEditPolicy.noteToSave(source: .server, loaded: "a", current: "") == "")
    }

    @Test("キャッシュから出した本文は、書き換えたときだけ保存する")
    func fromCache() {
        #expect(SharedMemoNoteEditPolicy.noteToSave(source: .cache, loaded: "古い本文", current: "古い本文") == nil)
        #expect(SharedMemoNoteEditPolicy.noteToSave(source: .cache, loaded: "古い本文", current: "新しい本文") == "新しい本文")
    }

    @Test("読めなかったときは保存しない")
    func unavailable() {
        #expect(SharedMemoNoteEditPolicy.noteToSave(source: .unavailable, loaded: "", current: "") == nil)
    }
}

// MARK: - 依頼者への通知の購読

@Suite("RequesterSubscriptionPolicy")
struct RequesterSubscriptionPolicyTests {

    @Test("旧版の購読 ID を見分ける")
    func legacyIDs() {
        #expect(RequesterSubscriptionPolicy.isLegacy("requester-arrived-v1"))
        #expect(RequesterSubscriptionPolicy.isLegacy("requester-completed-v1"))
        #expect(!RequesterSubscriptionPolicy.isLegacy(CKShareService.arrivedSubscriptionID))
        #expect(!RequesterSubscriptionPolicy.isLegacy(CKShareService.completedSubscriptionID))
        #expect(!RequesterSubscriptionPolicy.isLegacy(nil))
    }

    @Test("既に無い購読の削除は成功とみなし、それ以外は失敗とする")
    func failures() {
        let unknownItem = CKError(.unknownItem)
        #expect(!RequesterSubscriptionPolicy.isFailure(unknownItem, deleting: true))
        #expect(RequesterSubscriptionPolicy.isFailure(unknownItem, deleting: false))
        #expect(RequesterSubscriptionPolicy.isFailure(CKError(.networkFailure), deleting: true))
        #expect(RequesterSubscriptionPolicy.isFailure(CKError(.permissionFailure), deleting: false))
    }
}

// MARK: - 受信した依頼の取り込み（プロフィールなし）

@Suite("受信した依頼の取り込み")
struct SharedImportPolicyTests {

    @Test("プロフィールが無い（または iCloud ID が空）なら、取り込みは行うが claim はしない", arguments: [
        (nil as String?, ""),
        ("" as String?, ""),
        (nil as String?, "someone"),
    ])
    func noProfileDoesNotClaim(me: String?, recipient: String) {
        #expect(!SharedImportPolicy.shouldClaim(recipientRecordID: recipient, status: .active, myICloudRecordID: me))
    }

    @Test("プロフィールがあり、受信者が未定で監視中なら claim する")
    func claimsWhenUnclaimedAndActive() {
        #expect(SharedImportPolicy.shouldClaim(recipientRecordID: "", status: .active, myICloudRecordID: "me"))
    }

    @Test("受信者が既に決まっている、または到着・完了・取り消し後は claim しない", arguments: [
        ("other", ShareStatus.active), ("", .fired), ("", .completed), ("", .cancelled),
    ])
    func doesNotClaimOtherwise(recipient: String, status: ShareStatus) {
        #expect(!SharedImportPolicy.shouldClaim(recipientRecordID: recipient, status: status, myICloudRecordID: "me"))
    }
}

// MARK: - 監視の登録順

@Suite("監視の登録順")
struct GeofenceRegistrationOrderTests {

    private func labels(_ entries: [GeofenceRegistrationOrder.Entry<String, Int>]) -> [String] {
        entries.map {
            switch $0 {
            case .received(let r): return "r:\(r)"
            case .own(let o): return "o:\(o)"
            }
        }
    }

    @Test("受信した依頼を先に、自分のメモを後に並べる。それぞれの順序は保つ")
    func receivedFirst() {
        let result = GeofenceRegistrationOrder.prioritized(received: ["a", "b"], own: [1, 2, 3])
        #expect(labels(result) == ["r:a", "r:b", "o:1", "o:2", "o:3"])
    }

    @Test("上限 20 件で切ると、溢れるのは自分のメモ側")
    func overflowDropsOwn() {
        let received = (0..<3).map { "s\($0)" }
        let own = Array(0..<25)
        let kept = labels(GeofenceRegistrationOrder.prioritized(received: received, own: own)).prefix(20)
        #expect(kept.filter { $0.hasPrefix("r:") }.count == 3)
        #expect(kept.filter { $0.hasPrefix("o:") }.count == 17)
    }

    @Test("片方が空でも並ぶ")
    func emptySides() {
        #expect(labels(GeofenceRegistrationOrder.prioritized(received: [], own: [1])) == ["o:1"])
        #expect(labels(GeofenceRegistrationOrder.prioritized(received: ["a"], own: [])) == ["r:a"])
    }
}
