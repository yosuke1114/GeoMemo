import Testing
import Foundation
import CloudKit
@testable import geomemo

// 依頼を受け取った人向けの画面の判断ロジック（RecipientLogic.swift）のテスト。
// 対象はすべて nonisolated なので、テストもメインアクターを要求しない。

private func item(_ name: String, _ status: ShareStatus = .active, owner: String = "_owner",
                  deadline: Date? = nil, created: TimeInterval = 0, completedAt: Date? = nil) -> ReceivedSummary {
    ReceivedSummary(recordName: name, zoneOwner: owner, status: status, deadline: deadline,
                    createdAt: Date(timeIntervalSince1970: created), completedAt: completedAt)
}

@Suite("HomeMode")
struct HomeModeTests {
    @Test("メモ 0・送信 0・受信 1 以上のときだけ受信だけの表示")
    func receiverOnly() {
        #expect(HomeMode.resolve(ownMemoCount: 0, sentRequestCount: 0, receivedRequestCount: 1) == .receiverOnly)
        #expect(HomeMode.resolve(ownMemoCount: 0, sentRequestCount: 0, receivedRequestCount: 5) == .receiverOnly)
    }

    @Test("それ以外の組み合わせは通常の表示")
    func standard() {
        #expect(HomeMode.resolve(ownMemoCount: 0, sentRequestCount: 0, receivedRequestCount: 0) == .standard)
        #expect(HomeMode.resolve(ownMemoCount: 1, sentRequestCount: 0, receivedRequestCount: 0) == .standard)
        #expect(HomeMode.resolve(ownMemoCount: 0, sentRequestCount: 1, receivedRequestCount: 0) == .standard)
        #expect(HomeMode.resolve(ownMemoCount: 1, sentRequestCount: 1, receivedRequestCount: 0) == .standard)
        #expect(HomeMode.resolve(ownMemoCount: 1, sentRequestCount: 0, receivedRequestCount: 2) == .standard)
        #expect(HomeMode.resolve(ownMemoCount: 0, sentRequestCount: 1, receivedRequestCount: 2) == .standard)
        #expect(HomeMode.resolve(ownMemoCount: 3, sentRequestCount: 2, receivedRequestCount: 1) == .standard)
    }
}

@Suite("ReceivedBadgeState")
struct ReceivedBadgeStateTests {
    @Test("0 件なら隠す（未読があっても）")
    func hidden() {
        #expect(ReceivedBadgeState.resolve(waiting: 0, arrived: 0, unseen: 0) == .hidden)
        #expect(ReceivedBadgeState.resolve(waiting: 0, arrived: 0, unseen: 2) == .hidden)
    }

    @Test("件数・到着済みの有無・未読の有無")
    func visible() {
        #expect(ReceivedBadgeState.resolve(waiting: 2, arrived: 0, unseen: 0)
                == .visible(count: 2, hasArrived: false, hasUnseen: false))
        #expect(ReceivedBadgeState.resolve(waiting: 1, arrived: 1, unseen: 1)
                == .visible(count: 2, hasArrived: true, hasUnseen: true))
    }

    @Test("要約から: 完了・取り消しは数えず、既読は未読に数えない")
    func fromSummaries() {
        let items = [item("a"), item("b", .fired), item("c", .completed), item("d", .cancelled)]
        #expect(ReceivedBadgeState.resolve(items, seen: ["a"])
                == .visible(count: 2, hasArrived: true, hasUnseen: true))
        #expect(ReceivedBadgeState.resolve(items, seen: ["a", "b", "c", "d"])
                == .visible(count: 2, hasArrived: true, hasUnseen: false))
        // 完了済みの依頼が未読でも、バッジの未読には数えない
        #expect(ReceivedBadgeState.resolve([item("c", .completed)], seen: []) == .hidden)
    }
}

@Suite("ReceivedRequestSections")
struct ReceivedRequestSectionsTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("到着済み・到着待ち・最近終わった依頼に分ける")
    func split() {
        let items = [
            item("wait"), item("arrived", .fired),
            item("doneNew", .completed, completedAt: now.addingTimeInterval(-3600)),
            item("doneOld", .completed, completedAt: now.addingTimeInterval(-SharedMemoNotePolicy.completedRetention - 1)),
            item("gone", .cancelled),
        ]
        let sections = ReceivedRequestSections.resolve(items, now: now)
        #expect(sections.arrived == ["arrived"])
        #expect(sections.waiting == ["wait"])
        #expect(sections.recent == ["doneNew"])
    }

    @Test("完了から 24 時間ちょうどは含めない。完了日時が無ければ含めない")
    func recentBoundary() {
        let edge = item("edge", .completed, completedAt: now.addingTimeInterval(-SharedMemoNotePolicy.completedRetention))
        let none = item("none", .completed)
        #expect(ReceivedRequestSections.resolve([edge, none], now: now).recent.isEmpty)
    }

    @Test("節の中は期限の近い順、期限なしは後、同じなら新しく受け取った順")
    func ordering() {
        let items = [
            item("noDeadlineOld", created: 1),
            item("late", deadline: now.addingTimeInterval(7200), created: 2),
            item("soon", deadline: now.addingTimeInterval(60), created: 3),
            item("noDeadlineNew", created: 9),
        ]
        #expect(ReceivedRequestSections.resolve(items, now: now).waiting
                == ["soon", "late", "noDeadlineNew", "noDeadlineOld"])
    }

    @Test("空")
    func empty() {
        #expect(ReceivedRequestSections.resolve([], now: now).isEmpty)
        #expect(ReceivedRequestSections.resolve([], now: now).count == 0)
    }

    @Test("件数は、有効な依頼と完了から 24 時間以内の依頼だけ（すべて終わったら 0）")
    func count() {
        let items = [item("a"), item("b", .fired), item("c", .completed, completedAt: now.addingTimeInterval(-60)),
                     item("d", .completed, completedAt: now.addingTimeInterval(-SharedMemoNotePolicy.completedRetention - 5)),
                     item("e", .cancelled)]
        #expect(ReceivedRequestSections.resolve(items, now: now).count == 3)
        #expect(ReceivedRequestSections.resolve(Array(items.suffix(2)), now: now).count == 0)
    }
}

@Suite("RequestDeadline")
struct RequestDeadlineTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("期限なし・前・ちょうど・後")
    func overdue() {
        #expect(!RequestDeadline.isOverdue(nil, now: now))
        #expect(!RequestDeadline.isOverdue(now.addingTimeInterval(1), now: now))
        #expect(!RequestDeadline.isOverdue(now, now: now))
        #expect(RequestDeadline.isOverdue(now.addingTimeInterval(-1), now: now))
    }
}

@Suite("ReceivedHighlight")
struct ReceivedHighlightTests {
    @Test("到着済みが先")
    func arrivedFirst() {
        let items = [item("wait", deadline: Date(timeIntervalSince1970: 10)), item("arrived", .fired)]
        #expect(ReceivedHighlight.pick(items) == "arrived")
    }

    @Test("期限の近い順、期限なしは後")
    func deadlineOrder() {
        let items = [
            item("none", created: 100),
            item("far", deadline: Date(timeIntervalSince1970: 2000)),
            item("near", deadline: Date(timeIntervalSince1970: 1000)),
        ]
        #expect(ReceivedHighlight.pick(items) == "near")
        #expect(ReceivedHighlight.pick([item("old", created: 1), item("new", created: 5)]) == "new")
    }

    @Test("完了・取り消しだけなら nil")
    func none() {
        #expect(ReceivedHighlight.pick([]) == nil)
        #expect(ReceivedHighlight.pick([item("a", .completed), item("b", .cancelled)]) == nil)
    }
}

@Suite("ArrivalResolver")
struct ArrivalResolverTests {
    private func key(_ root: String?, owner: String = "_owner") -> AcceptedShareKey {
        AcceptedShareKey(rootRecordName: root, ownerRecordID: owner)
    }

    @Test("新しく取り込んだ依頼は受け取り画面")
    func newArrival() {
        let result = ArrivalResolver.resolve(
            accepted: [key("r1")], received: [item("r1")], newlyInserted: ["r1"], skippedCancelled: [:])
        #expect(result == .arrival(recordName: "r1"))
    }

    @Test("取り込み済み（リンクを 2 回開いた）なら通常の詳細")
    func existing() {
        let result = ArrivalResolver.resolve(
            accepted: [key("r1")], received: [item("r1")], newlyInserted: [], skippedCancelled: [:])
        #expect(result == .existing(recordName: "r1"))
    }

    @Test("取り消し済みで取り込まなかった依頼は知らせるだけ")
    func cancelledBeforeOpen() {
        let result = ArrivalResolver.resolve(
            accepted: [key("r1")], received: [], newlyInserted: [], skippedCancelled: ["r1": "_owner"])
        #expect(result == .cancelledBeforeOpen)
    }

    @Test("複数まとめて受諾したら一覧")
    func list() {
        let result = ArrivalResolver.resolve(
            accepted: [key("r1"), key("r2")], received: [item("r1"), item("r2")],
            newlyInserted: ["r1", "r2"], skippedCancelled: [:])
        #expect(result == .list(recordNames: ["r1", "r2"]))
    }

    @Test("ルートのレコード名が無いときは、新しく取り込んだ依頼のうち依頼者が同じものを使う")
    func fallbackByOwner() {
        let received = [item("r1", owner: "_a"), item("r2", owner: "_b")]
        let result = ArrivalResolver.resolve(
            accepted: [key(nil, owner: "_a")], received: received,
            newlyInserted: ["r1", "r2"], skippedCancelled: [:])
        #expect(result == .arrival(recordName: "r1"))
    }

    @Test("ルートが無く、同じ依頼者の依頼が 2 件同時に入ったら区別できず一覧")
    func fallbackAmbiguous() {
        let received = [item("r1", owner: "_a"), item("r2", owner: "_a")]
        let result = ArrivalResolver.resolve(
            accepted: [key(nil, owner: "_a")], received: received,
            newlyInserted: ["r1", "r2"], skippedCancelled: [:])
        #expect(result == .list(recordNames: ["r1", "r2"]))
    }

    @Test("ルートが無く取り消し済みの依頼者のものだけなら知らせるだけ")
    func fallbackCancelled() {
        let result = ArrivalResolver.resolve(
            accepted: [key(nil, owner: "_a")], received: [], newlyInserted: [], skippedCancelled: ["r9": "_a"])
        #expect(result == .cancelledBeforeOpen)
    }

    @Test("まだ見つからなければ nil（同期をやり直す）")
    func notFound() {
        #expect(ArrivalResolver.resolve(accepted: [key("r1")], received: [], newlyInserted: [], skippedCancelled: [:]) == nil)
        #expect(ArrivalResolver.resolve(accepted: [key(nil)], received: [item("r1")], newlyInserted: [], skippedCancelled: [:]) == nil)
        #expect(ArrivalResolver.resolve(accepted: [], received: [item("r1")], newlyInserted: ["r1"], skippedCancelled: [:]) == nil)
    }

    @Test("ルートが無いときの取り消しは、受諾の後に初めて見つけたものだけ（前から残る取り消し済みを取り違えない）")
    func fallbackCancelledFresh() {
        let skipped = ["old": "_a"]
        #expect(ArrivalResolver.resolve(accepted: [key(nil, owner: "_a")], received: [], newlyInserted: [],
                                        skippedCancelled: skipped, freshCancelled: []) == nil)
        #expect(ArrivalResolver.resolve(accepted: [key(nil, owner: "_a")], received: [], newlyInserted: [],
                                        skippedCancelled: skipped, freshCancelled: ["old"]) == .cancelledBeforeOpen)
        // ルートが分かっていれば、受諾より前から取り消し済みでも知らせる
        #expect(ArrivalResolver.resolve(accepted: [key("old")], received: [], newlyInserted: [],
                                        skippedCancelled: skipped, freshCancelled: []) == .cancelledBeforeOpen)
    }

    @Test("見つかった鍵だけを返す（残りは次の試行に回す）")
    func resolvedKeys() {
        let keys = [key("r1"), key("r2"), key("r3")]
        let resolved = ArrivalResolver.resolvedKeys(
            accepted: keys, received: [item("r1")], newlyInserted: ["r1"], skippedCancelled: ["r3": "_owner"])
        #expect(resolved == [key("r1"), key("r3")])
    }

    @Test("別の端末から来た依頼（newlyInserted に無い）は、受諾していなければ対象にならない")
    func notAccepted() {
        let result = ArrivalResolver.resolve(
            accepted: [key("r1")], received: [item("r1"), item("other")], newlyInserted: ["other"], skippedCancelled: [:])
        #expect(result == .existing(recordName: "r1"))
    }
}

@Suite("ReceivedArrivalContent")
struct ReceivedArrivalContentTests {
    private func snapshot(_ location: LocationAccess = .always, precise: Bool = true,
                          _ notification: NotificationAccess = .allowed) -> PermissionSnapshot {
        PermissionSnapshot(location: location, isPreciseLocation: precise, notification: notification)
    }

    private func resolve(_ status: ShareStatus = .active, permissions s: PermissionSnapshot? = nil,
                         hasProfile: Bool = true, regions: Int = 0) -> ReceivedArrivalContent {
        ReceivedArrivalContent.resolve(status: status, permissions: s ?? snapshot(), hasProfile: hasProfile, requiredRegions: regions)
    }

    @Test("許可が足りていて、プロフィールがあれば案内なし。3 項目と「あなたの名前」を出す")
    func allGood() {
        #expect(resolve(regions: 3) == ReceivedArrivalContent(
            notice: nil, showsAbout: true, showsNamePrompt: false, showsYourName: true))
    }

    @Test("使用中のみは専用の文、それ以外は PR #11 の案内")
    func notices() {
        #expect(resolve(permissions: snapshot(.whenInUse)).notice == .whenInUseOnly)
        #expect(resolve(permissions: snapshot(.denied)).notice == .permission(.locationDenied))
        #expect(resolve(permissions: snapshot(.notDetermined)).notice == .permission(.locationNotDetermined))
        #expect(resolve(permissions: snapshot(.always, .denied)).notice == .permission(.notificationsDenied))
        #expect(resolve(permissions: snapshot(.always, precise: false)).notice == .permission(.locationReducedAccuracy))
    }

    @Test("許可の不足が無くて上限を超えているときだけ上限の案内。許可の不足があればそちらが先")
    func limit() {
        #expect(resolve(regions: 22).notice == .monitoringLimit(.overLimit(used: 22, unmonitored: 2)))
        #expect(resolve(regions: 19).notice == nil)
        #expect(resolve(permissions: snapshot(.denied), regions: 22).notice == .permission(.locationDenied))
    }

    @Test("名前の行はプロフィールが無いときだけ、「あなたの名前」はあるときだけ")
    func nameRows() {
        let noProfile = resolve(hasProfile: false)
        #expect(noProfile.showsNamePrompt && !noProfile.showsYourName)
        let profile = resolve(hasProfile: true)
        #expect(!profile.showsNamePrompt && profile.showsYourName)
    }

    @Test("監視中でない依頼（到着済み・完了・取り消し）には、3 項目・案内・名前の行を出さない")
    func notActive() {
        for status in [ShareStatus.fired, .completed, .cancelled] {
            let content = resolve(status, permissions: snapshot(.denied), hasProfile: false, regions: 30)
            #expect(content == ReceivedArrivalContent(notice: nil, showsAbout: false, showsNamePrompt: false, showsYourName: false))
        }
    }
}

@Suite("RequesterIdentity")
struct RequesterIdentityTests {
    @Test("確認済みの名前が無ければ、レコードに書かれた名前をそのまま使う")
    func unverified() {
        #expect(RequesterIdentity.resolve(writtenName: " 母 ", verifiedName: nil) == RequesterIdentity(displayName: "母", writtenName: nil))
        #expect(RequesterIdentity.resolve(writtenName: "母", verifiedName: "  ") == RequesterIdentity(displayName: "母", writtenName: nil))
        #expect(RequesterIdentity.resolve(writtenName: "", verifiedName: nil).displayName.isEmpty)
    }

    @Test("確認済みの名前を優先し、食い違うときだけ書かれた名前を添える")
    func verified() {
        #expect(RequesterIdentity.resolve(writtenName: "母", verifiedName: "母") == RequesterIdentity(displayName: "母", writtenName: nil))
        #expect(RequesterIdentity.resolve(writtenName: "社長", verifiedName: "山田") == RequesterIdentity(displayName: "山田", writtenName: "社長"))
        #expect(RequesterIdentity.resolve(writtenName: "", verifiedName: "山田") == RequesterIdentity(displayName: "山田", writtenName: nil))
    }
}

@Suite("DeclinedRequestStore")
struct DeclinedRequestStoreTests {
    private func makeStore() -> DeclinedRequestStore {
        let suite = "test.declined.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DeclinedRequestStore(defaults: defaults)
    }

    @Test("断った記録の追加・確認・削除")
    func addRemove() {
        let store = makeStore()
        #expect(!store.contains("r1"))
        store.add(recordName: "r1", zoneOwner: "_a")
        store.add(recordName: "", zoneOwner: "_a")
        #expect(store.contains("r1"))
        #expect(store.entries == ["r1": "_a"])
        store.remove("r1")
        store.remove("none")
        #expect(store.entries.isEmpty)
    }

    @Test("受諾し直したら、ルートのレコード名で記録を消す")
    func reacceptByRoot() {
        let store = makeStore()
        store.add(recordName: "r1", zoneOwner: "_a")
        store.add(recordName: "r2", zoneOwner: "_a")
        store.removeForReaccept(rootRecordName: "r1", ownerRecordID: "_a")
        #expect(store.entries == ["r2": "_a"])
    }

    @Test("ルートが取れないときは、依頼者が同じ記録を消す")
    func reacceptByOwner() {
        let store = makeStore()
        store.add(recordName: "r1", zoneOwner: "_a")
        store.add(recordName: "r2", zoneOwner: "_b")
        store.removeForReaccept(rootRecordName: nil, ownerRecordID: "_a")
        #expect(store.entries == ["r2": "_b"])
    }

    @Test("UserDefaults が無くても落ちない")
    func noDefaults() {
        let store = DeclinedRequestStore(defaults: nil)
        store.add(recordName: "r1", zoneOwner: "_a")
        store.remove("r1")
        #expect(store.entries.isEmpty)
    }
}

@Suite("ShareAcceptFailure")
struct ShareAcceptFailureTests {
    @Test("CKError のコードごとの分類")
    func classify() {
        #expect(ShareAcceptFailure.classify(.notAuthenticated) == .notSignedIn)
        #expect(ShareAcceptFailure.classify(.accountTemporarilyUnavailable) == .notSignedIn)
        #expect(ShareAcceptFailure.classify(.networkUnavailable) == .network)
        #expect(ShareAcceptFailure.classify(.networkFailure) == .network)
        #expect(ShareAcceptFailure.classify(.unknownItem) == .goneOrCancelled)
        #expect(ShareAcceptFailure.classify(.zoneNotFound) == .goneOrCancelled)
        #expect(ShareAcceptFailure.classify(.permissionFailure) == .notInvited)
        #expect(ShareAcceptFailure.classify(.participantMayNeedVerification) == .needsVerification)
    }

    @Test("分からないコード・nil は汎用")
    func other() {
        #expect(ShareAcceptFailure.classify(.quotaExceeded) == .other)
        #expect(ShareAcceptFailure.classify(.internalError) == .other)
        #expect(ShareAcceptFailure.classify(nil) == .other)
    }

    @Test("CKError でないエラーは汎用")
    func nonCKError() {
        #expect(ShareAcceptFailure.classify(error: NSError(domain: "x", code: 1)) == .other)
        #expect(ShareAcceptFailure.classify(error: CKError(.notAuthenticated)) == .notSignedIn)
    }

    @Test("partialFailure に包まれていれば中身で分類し、食い違えば汎用")
    func partial() {
        let id1 = CKRecord.ID(recordName: "a")
        let id2 = CKRecord.ID(recordName: "b")
        let same = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [id1: CKError(.unknownItem), id2: CKError(.unknownItem)],
        ])
        #expect(ShareAcceptFailure.classify(error: same) == .goneOrCancelled)
        let mixed = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [id1: CKError(.unknownItem), id2: CKError(.networkFailure)],
        ])
        #expect(ShareAcceptFailure.classify(error: mixed) == .other)
        #expect(ShareAcceptFailure.classify(error: CKError(.partialFailure)) == .other)
    }

    @Test("どの分類にも文がある（空でない）")
    func messages() {
        for failure in [ShareAcceptFailure.notSignedIn, .network, .goneOrCancelled, .notInvited, .needsVerification, .other] {
            #expect(!failure.message.isEmpty)
        }
    }
}

@Suite("ReceivedRequestSeenStore")
struct ReceivedRequestSeenStoreTests {
    private func makeStore() -> ReceivedRequestSeenStore {
        let suite = "test.seen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ReceivedRequestSeenStore(defaults: defaults)
    }

    @Test("既読の追加（重複・空は無視）")
    func markSeen() {
        let store = makeStore()
        #expect(!store.isSeen("a"))
        store.markSeen("a")
        store.markSeen("a")
        store.markSeen("")
        #expect(store.isSeen("a"))
        #expect(store.all == ["a"])
    }

    @Test("種まきは 1 回だけ。その時点の依頼を既読にする")
    func seed() {
        let store = makeStore()
        #expect(store.seedIfNeeded(existing: ["a", "b"]))
        #expect(store.all == ["a", "b"])
        // 2 回目は何もしない（後から取り込んだ依頼は新着のまま）
        #expect(!store.seedIfNeeded(existing: ["c"]))
        #expect(!store.isSeen("c"))
    }

    @Test("無くなった依頼の記録を掃除する")
    func prune() {
        let store = makeStore()
        ["a", "b", "c"].forEach { store.markSeen($0) }
        store.prune(keeping: ["b", "z"])
        #expect(store.all == ["b"])
    }

    @Test("UserDefaults が無くても落ちない")
    func noDefaults() {
        let store = ReceivedRequestSeenStore(defaults: nil)
        store.markSeen("a")
        #expect(store.all.isEmpty)
        #expect(!store.seedIfNeeded(existing: ["a"]))
        store.prune(keeping: [])
    }
}
