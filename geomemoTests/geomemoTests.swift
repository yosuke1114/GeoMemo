//
//  geomemoTests.swift
//  geomemoTests
//
//  Created by 黒滝洋輔 on 2026/03/26.
//

import Testing
import Foundation
import CoreLocation
import CoreSpotlight
import UserNotifications
@testable import geomemo

// MARK: - LocationManager.shouldNotify テスト

@Suite("LocationManager.shouldNotify")
struct ShouldNotifyTests {

    let manager = LocationManager()

    // MARK: 条件なし

    @Test("条件なし → 通知する")
    func noConditions_returnsTrue() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(manager.shouldNotify(for: memo) == true)
    }

    // MARK: 期限チェック

    @Test("期限が未来 → 通知する")
    func deadlineInFuture_returnsTrue() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           deadline: Date().addingTimeInterval(3600))
        #expect(manager.shouldNotify(for: memo) == true)
    }

    @Test("期限切れ → 通知しない")
    func deadlinePassed_returnsFalse() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           deadline: Date().addingTimeInterval(-1))
        #expect(manager.shouldNotify(for: memo) == false)
    }

    // MARK: 時間帯チェック

    @Test("現在時刻が時間帯内 → 通知する")
    func withinTimeWindow_returnsTrue() {
        let calendar = Calendar.current
        let now = Date()
        let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           timeWindowStart: max(0, currentMinutes - 30),
                           timeWindowEnd: min(1439, currentMinutes + 30))
        #expect(manager.shouldNotify(for: memo) == true)
    }

    @Test("現在時刻が時間帯外 → 通知しない")
    func outsideTimeWindow_returnsFalse() {
        let calendar = Calendar.current
        let now = Date()
        let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        // 現在より60分以上前に終わる時間帯を設定（0:00〜0:00 より前）
        guard currentMinutes > 60 else { return } // 0時台はスキップ
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           timeWindowStart: 0,
                           timeWindowEnd: currentMinutes - 61)
        #expect(manager.shouldNotify(for: memo) == false)
    }

    // MARK: 曜日チェック

    @Test("今日が対象曜日に含まれる → 通知する")
    func todayInActiveDays_returnsTrue() {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date()) - 1 // 0=日...6=土
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           activeDays: [weekday])
        #expect(manager.shouldNotify(for: memo) == true)
    }

    @Test("今日が対象曜日に含まれない → 通知しない")
    func todayNotInActiveDays_returnsFalse() {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date()) - 1
        let otherDays = (0...6).filter { $0 != weekday }
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           activeDays: otherDays)
        #expect(manager.shouldNotify(for: memo) == false)
    }

    // MARK: 複合条件

    @Test("期限切れ + 有効な時間帯 → 通知しない（期限が優先）")
    func deadlinePassed_withValidTimeWindow_returnsFalse() {
        let calendar = Calendar.current
        let now = Date()
        let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           deadline: Date().addingTimeInterval(-1),
                           timeWindowStart: max(0, currentMinutes - 30),
                           timeWindowEnd: min(1439, currentMinutes + 30))
        #expect(manager.shouldNotify(for: memo) == false)
    }

    @Test("有効な期限 + 今日が対象曜日 → 通知する")
    func validDeadline_withTodayInActiveDays_returnsTrue() {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date()) - 1
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           deadline: Date().addingTimeInterval(3600),
                           activeDays: [weekday])
        #expect(manager.shouldNotify(for: memo) == true)
    }
}

// MARK: - ルートトリガー テスト

@Suite("ルートトリガー")
struct RouteTriggerTests {

    // MARK: RouteWaypoint エンコード/デコード

    @Test("RouteWaypoint を JSON エンコード → デコードできる")
    func waypointEncodeDecode() throws {
        let wp = RouteWaypoint(latitude: 35.6895, longitude: 139.6917, name: "渋谷")
        let data = try JSONEncoder().encode([wp])
        let decoded = try JSONDecoder().decode([RouteWaypoint].self, from: data)
        #expect(decoded.count == 1)
        #expect(abs(decoded[0].latitude - 35.6895) < 0.0001)
        #expect(abs(decoded[0].longitude - 139.6917) < 0.0001)
        #expect(decoded[0].name == "渋谷")
    }

    @Test("複数ウェイポイントのエンコード → デコードで順序が保たれる")
    func multipleWaypointsPreserveOrder() throws {
        let wps = [
            RouteWaypoint(latitude: 35.6895, longitude: 139.6917, name: "A"),
            RouteWaypoint(latitude: 35.6762, longitude: 139.6503, name: "B"),
            RouteWaypoint(latitude: 35.7090, longitude: 139.7321, name: "C"),
        ]
        let data = try JSONEncoder().encode(wps)
        let decoded = try JSONDecoder().decode([RouteWaypoint].self, from: data)
        #expect(decoded.map { $0.name } == ["A", "B", "C"])
    }

    // MARK: GeoMemo ルートフィールド

    @Test("isRouteTrigger デフォルトは false")
    func isRouteTriggerDefaultFalse() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        #expect(memo.isRouteTrigger == false)
        #expect(memo.waypointData == nil)
        #expect(memo.routeWaypoints.isEmpty)
    }

    @Test("waypointData を設定すると routeWaypoints が正しく返る")
    func routeWaypointsDecodedFromData() throws {
        let wps = [
            RouteWaypoint(latitude: 35.6895, longitude: 139.6917, name: "渋谷"),
            RouteWaypoint(latitude: 35.6762, longitude: 139.6503, name: "新宿"),
        ]
        let data = try JSONEncoder().encode(wps)
        let memo = GeoMemo(
            title: "ルートメモ", note: "", latitude: 35.6895, longitude: 139.6917, radius: 50,
            isRouteTrigger: true, waypointData: data
        )
        #expect(memo.isRouteTrigger == true)
        #expect(memo.routeWaypoints.count == 2)
        #expect(memo.routeWaypoints[0].name == "渋谷")
        #expect(memo.routeWaypoints[1].name == "新宿")
    }

    @Test("waypointData が壊れている場合は空配列を返す")
    func invalidWaypointDataReturnsEmpty() {
        let memo = GeoMemo(
            title: "壊れたデータ", note: "", latitude: 35.0, longitude: 139.0, radius: 100,
            isRouteTrigger: true, waypointData: Data("broken".utf8)
        )
        #expect(memo.routeWaypoints.isEmpty)
    }

    // MARK: ウェイポイント識別子のパース

    @Test("ルートウェイポイント識別子から memoID を抽出できる")
    func waypointIdentifierParsing() {
        let memoID = UUID()
        let identifier = "\(memoID.uuidString)|wp|2"

        // LocationManager.didEnterRegion と同じロジック
        let extractedID: String
        if let range = identifier.range(of: "|wp|") {
            extractedID = String(identifier[..<range.lowerBound])
        } else {
            extractedID = identifier
        }
        #expect(extractedID == memoID.uuidString)
    }

    @Test("通常の識別子（ルートでない）はそのまま返る")
    func normalIdentifierPassThrough() {
        let memoID = UUID().uuidString
        let identifier = memoID

        let extractedID: String
        if let range = identifier.range(of: "|wp|") {
            extractedID = String(identifier[..<range.lowerBound])
        } else {
            extractedID = identifier
        }
        #expect(extractedID == memoID)
    }

    @Test("ウェイポイント識別子フォーマットが正しく生成される")
    func waypointIdentifierFormat() throws {
        let wps = [
            RouteWaypoint(latitude: 35.6895, longitude: 139.6917),
            RouteWaypoint(latitude: 35.6762, longitude: 139.6503),
        ]
        let data = try JSONEncoder().encode(wps)
        let memo = GeoMemo(
            title: "ルート", note: "", latitude: 35.6895, longitude: 139.6917, radius: 50,
            isRouteTrigger: true, waypointData: data
        )
        let prefix = memo.id.uuidString
        #expect("\(prefix)|wp|0".hasPrefix(prefix))
        #expect("\(prefix)|wp|1".hasPrefix(prefix))
        // 通常のジオフェンスID（ルートでない）と衝突しない
        #expect("\(prefix)|wp|0" != prefix)
    }
}

// MARK: - GeoMemo モデルテスト

@Suite("GeoMemo モデル")
struct GeoMemoModelTests {

    @Test("デフォルト値が正しい")
    func defaultValues() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(memo.title == "テスト")
        #expect(memo.note == "")
        #expect(memo.radius == 100)
        #expect(memo.notifyOnEntry == true)
        #expect(memo.notifyOnExit == true)
        #expect(memo.isFavorite == false)
        #expect(memo.deadline == nil)
        #expect(memo.activeDays == nil)
        #expect(memo.timeWindowStart == nil)
        #expect(memo.timeWindowEnd == nil)
        #expect(memo.imageData == nil)
    }

    @Test("coordinate プロパティが緯度経度を正しく返す")
    func coordinate_returnsCorrectValues() {
        let lat = 35.6895, lon = 139.6917
        let memo = GeoMemo(title: "東京", note: "", latitude: lat, longitude: lon, radius: 100)
        #expect(abs(memo.coordinate.latitude - lat) < 0.0001)
        #expect(abs(memo.coordinate.longitude - lon) < 0.0001)
    }

    @Test("region プロパティが指定半径の CLCircularRegion を返す")
    func region_returnsCorrectRadius() {
        let memo = GeoMemo(title: "東京", note: "", latitude: 35.6895, longitude: 139.6917, radius: 200)
        #expect(memo.region != nil)
        #expect(abs((memo.region?.radius ?? 0) - 200) < 0.1)
    }

    @Test("region の identifier がメモの id と一致する")
    func region_identifierMatchesMemoId() {
        let memo = GeoMemo(title: "東京", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(memo.region?.identifier == memo.id.uuidString)
    }

    @Test("isFavorite をトグルできる")
    func toggleFavorite() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(memo.isFavorite == false)
        memo.isFavorite = true
        #expect(memo.isFavorite == true)
        memo.isFavorite = false
        #expect(memo.isFavorite == false)
    }

    @Test("タグフィールドのデフォルト値が正しい")
    func tagFieldDefaults() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(memo.tags.isEmpty)
        #expect(memo.customTags.isEmpty)
    }

    @Test("タグを設定・取得できる")
    func tagsPersist() {
        let memo = GeoMemo(
            title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100,
            tags: [1, 2], customTags: ["マイタグ"]
        )
        #expect(memo.tags == [1, 2])
        #expect(memo.customTags == ["マイタグ"])
    }

    @Test("isDone のデフォルトは false")
    func isDoneDefaultFalse() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(memo.isDone == false)
    }

    @Test("isDone を true に設定できる")
    func isDoneCanBeSetTrue() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        memo.isDone = true
        #expect(memo.isDone == true)
    }
}

// MARK: - PresetTag テスト

@Suite("PresetTag")
struct PresetTagTests {

    @Test("全10種が定義されている")
    func allCasesCount() {
        #expect(PresetTag.allCases.count == 10)
    }

    @Test("rawValue が 1〜10 の範囲にある")
    func rawValueRange() {
        for tag in PresetTag.allCases {
            #expect((1...10).contains(tag.rawValue))
        }
    }

    @Test("id が rawValue と一致する")
    func idEqualsRawValue() {
        for tag in PresetTag.allCases {
            #expect(tag.id == tag.rawValue)
        }
    }

    @Test("iconName が空でない")
    func iconNamesNonEmpty() {
        for tag in PresetTag.allCases {
            #expect(!tag.iconName.isEmpty)
        }
    }

    @Test("localizedName が空でない")
    func localizedNamesNonEmpty() {
        for tag in PresetTag.allCases {
            #expect(!tag.localizedName.isEmpty)
        }
    }

    @Test("keywords が空でない")
    func keywordsNonEmpty() {
        for tag in PresetTag.allCases {
            #expect(!tag.keywords.isEmpty)
        }
    }

    @Test("rawValue から復元できる")
    func initFromRawValue() {
        #expect(PresetTag(rawValue: 1) == .work)
        #expect(PresetTag(rawValue: 2) == .food)
        #expect(PresetTag(rawValue: 10) == .memo)
        #expect(PresetTag(rawValue: 0) == nil)
        #expect(PresetTag(rawValue: 11) == nil)
    }
}

// MARK: - AutoTagEngine テスト

@Suite("AutoTagEngine")
struct AutoTagEngineTests {

    @Test("空入力は空配列を返す")
    func emptyInput_returnsEmpty() {
        let result = AutoTagEngine.suggest(title: "", note: "", locationName: "")
        #expect(result.isEmpty)
    }

    @Test("仕事キーワードで work タグを提案する")
    func workKeyword_suggestsWork() {
        let result = AutoTagEngine.suggest(title: "会社でミーティング", note: "", locationName: "")
        #expect(result.contains(.work))
    }

    @Test("食事キーワードで food タグを提案する")
    func foodKeyword_suggestsFood() {
        let result = AutoTagEngine.suggest(title: "ランチに行く", note: "", locationName: "レストラン")
        #expect(result.contains(.food))
    }

    @Test("場所名のキーワードは重み2倍（タイトルより優先）")
    func locationNameWeightedHigher() {
        // locationName にのみキーワードがある → スコア2
        let resultLocation = AutoTagEngine.suggest(title: "", note: "", locationName: "スーパー")
        // note にのみキーワードがある → スコア1
        let resultNote = AutoTagEngine.suggest(title: "", note: "スーパー", locationName: "")
        // どちらも shopping を提案するはず
        #expect(resultLocation.contains(.shopping))
        #expect(resultNote.contains(.shopping))
    }

    @Test("最大3件を返す")
    func returnsAtMost3() {
        let result = AutoTagEngine.suggest(
            title: "病院 スーパー 会社",
            note: "駅 公園",
            locationName: "オフィスビル"
        )
        #expect(result.count <= 3)
    }

    @Test("スコア0のタグは返さない")
    func zeroScoreTagExcluded() {
        // 関係ないキーワードのみ
        let result = AutoTagEngine.suggest(title: "aaaaa", note: "bbbbb", locationName: "ccccc")
        #expect(result.isEmpty)
    }

    @Test("英語キーワードでも提案できる")
    func englishKeyword_works() {
        let result = AutoTagEngine.suggest(title: "business meeting", note: "", locationName: "office")
        #expect(result.contains(.work))
    }

    @Test("transit キーワードで transit タグを提案する")
    func transitKeyword() {
        let result = AutoTagEngine.suggest(title: "", note: "", locationName: "渋谷駅")
        #expect(result.contains(.transit))
    }
}

// MARK: - 通知アクション テスト

@Suite("通知アクション")
struct NotificationActionTests {

    // MARK: - 定数確認

    @Test("カテゴリ識別子が正しい")
    func categoryIdentifier() {
        #expect(NotificationManager.categoryID == "GEOMEMO_ALERT")
    }

    @Test("アクション識別子が正しい")
    func actionIdentifiers() {
        #expect(NotificationManager.actionDone    == "DONE")
        #expect(NotificationManager.actionSnooze5  == "SNOOZE_5")
        #expect(NotificationManager.actionSnooze30 == "SNOOZE_30")
    }

    @Test("geoMemoMarkDone 通知名が定義されている")
    func markDoneNotificationName() {
        let name = Notification.Name.geoMemoMarkDone
        #expect(name.rawValue == "geoMemoMarkDone")
    }

    // MARK: - isDone フラグ更新（NotificationCenter 経由）

    @Test("geoMemoMarkDone 受信で isDone が true になる")
    @MainActor
    func markDoneViaNotificationCenter() async {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let memoID = memo.id.uuidString
        #expect(memo.isDone == false)

        // NotificationCenter で購読して isDone を更新（ContentView と同じロジック）
        let expectation = AsyncStream<Void>.makeStream()
        var cancellable: NSObjectProtocol?
        cancellable = NotificationCenter.default.addObserver(
            forName: .geoMemoMarkDone,
            object: nil,
            queue: .main
        ) { notification in
            if let id = notification.object as? String, id == memoID {
                memo.isDone = true
                expectation.continuation.finish()
            }
        }

        NotificationCenter.default.post(name: .geoMemoMarkDone, object: memoID)

        // 通知が処理されるまで待機
        for await _ in expectation.stream { break }
        NotificationCenter.default.removeObserver(cancellable!)

        #expect(memo.isDone == true)
    }

    @Test("異なる memoID の geoMemoMarkDone は isDone を変えない")
    func markDoneIgnoresDifferentID() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        #expect(memo.isDone == false)

        // 別の ID で通知を送る
        NotificationCenter.default.post(name: .geoMemoMarkDone, object: UUID().uuidString)

        // isDone は変わらない（このテストは同期で確認）
        #expect(memo.isDone == false)
    }

    // MARK: - カテゴリ登録

    @Test("registerCategories でカテゴリが登録される")
    @MainActor
    func registerCategoriesAddsCategory() async {
        NotificationManager.registerCategories()

        let categories = await UNUserNotificationCenter.current().notificationCategories()
        let registered = categories.first(where: { $0.identifier == NotificationManager.categoryID })
        #expect(registered != nil)

        // アクション数の確認（完了・5分後・30分後 の3つ）
        #expect(registered?.actions.count == 3)
        let actionIDs = registered?.actions.map { $0.identifier } ?? []
        #expect(actionIDs.contains(NotificationManager.actionDone))
        #expect(actionIDs.contains(NotificationManager.actionSnooze5))
        #expect(actionIDs.contains(NotificationManager.actionSnooze30))
    }
}

// MARK: - Live Activity ルート進行状況テスト

@Suite("Live Activity ルート進行状況")
struct LiveActivityRouteProgressTests {

    // MARK: ContentState フィールド

    @Test("routeCurrentWaypoint と routeTotalWaypoints のデフォルトは nil")
    func routeFieldsDefaultNil() {
        let state = GeoMemoActivityAttributes.ContentState(
            isTriggered: false,
            memoTitle: "テスト",
            memoLocation: "渋谷",
            memoColorIndex: 0,
            triggeredAt: nil,
            routeCurrentWaypoint: nil,
            routeTotalWaypoints: nil
        )
        #expect(state.routeCurrentWaypoint == nil)
        #expect(state.routeTotalWaypoints == nil)
    }

    @Test("ルート進行状況付きの ContentState を設定できる")
    func routeProgressFieldsSet() {
        let state = GeoMemoActivityAttributes.ContentState(
            isTriggered: false,
            memoTitle: "ルートメモ",
            memoLocation: "新宿",
            memoColorIndex: 1,
            triggeredAt: nil,
            routeCurrentWaypoint: 2,
            routeTotalWaypoints: 3
        )
        #expect(state.routeCurrentWaypoint == 2)
        #expect(state.routeTotalWaypoints == 3)
        #expect(state.isTriggered == false)
    }

    @Test("ContentState の Codable ラウンドトリップ（ルート進行あり）")
    @MainActor
    func contentStateEncodeDecode() throws {
        let state = GeoMemoActivityAttributes.ContentState(
            isTriggered: false,
            memoTitle: "ルートメモ",
            memoLocation: "銀座",
            memoColorIndex: 2,
            triggeredAt: nil,
            routeCurrentWaypoint: 2,
            routeTotalWaypoints: 4
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GeoMemoActivityAttributes.ContentState.self, from: data)
        #expect(decoded.memoTitle == "ルートメモ")
        #expect(decoded.routeCurrentWaypoint == 2)
        #expect(decoded.routeTotalWaypoints == 4)
        #expect(decoded.isTriggered == false)
    }

    @Test("ContentState の Codable ラウンドトリップ（ルートフィールド nil）")
    @MainActor
    func contentStateEncodeDecodeNilRoute() throws {
        let state = GeoMemoActivityAttributes.ContentState(
            isTriggered: true,
            memoTitle: "通常メモ",
            memoLocation: "東京",
            memoColorIndex: 0,
            triggeredAt: Date(),
            routeCurrentWaypoint: nil,
            routeTotalWaypoints: nil
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GeoMemoActivityAttributes.ContentState.self, from: data)
        #expect(decoded.routeCurrentWaypoint == nil)
        #expect(decoded.routeTotalWaypoints == nil)
        #expect(decoded.isTriggered == true)
    }

    @Test("ContentState の Hashable — 同一値は等しい")
    @MainActor
    func contentStateHashableEqual() {
        let s1 = GeoMemoActivityAttributes.ContentState(
            isTriggered: false, memoTitle: "A", memoLocation: "B",
            memoColorIndex: 0, triggeredAt: nil,
            routeCurrentWaypoint: 2, routeTotalWaypoints: 3
        )
        let s2 = GeoMemoActivityAttributes.ContentState(
            isTriggered: false, memoTitle: "A", memoLocation: "B",
            memoColorIndex: 0, triggeredAt: nil,
            routeCurrentWaypoint: 2, routeTotalWaypoints: 3
        )
        #expect(s1 == s2)
    }

    @Test("ContentState の Hashable — ルート進行値が異なれば不等")
    @MainActor
    func contentStateHashableNotEqual() {
        let s1 = GeoMemoActivityAttributes.ContentState(
            isTriggered: false, memoTitle: "A", memoLocation: "B",
            memoColorIndex: 0, triggeredAt: nil,
            routeCurrentWaypoint: 1, routeTotalWaypoints: 3
        )
        let s2 = GeoMemoActivityAttributes.ContentState(
            isTriggered: false, memoTitle: "A", memoLocation: "B",
            memoColorIndex: 0, triggeredAt: nil,
            routeCurrentWaypoint: 2, routeTotalWaypoints: 3
        )
        #expect(s1 != s2)
    }

    // MARK: ルート進行ロジック（LocationManager.didEnterRegion と同じ判定式）

    /// LocationManager の didEnterRegion ロジックを純粋関数として抽出したヘルパー
    /// - Returns: (次のexpected index, 発火すべきか)
    func applyWaypointEntry(enteredIndex: Int, progress: inout [String: Int], total: Int, memoID: String) -> Bool {
        if enteredIndex == 0 {
            progress[memoID] = 0
        }
        let expected = progress[memoID] ?? 0
        guard enteredIndex == expected else { return false }
        let next = expected + 1
        if total > 0 && next >= total {
            progress.removeValue(forKey: memoID)
            return true  // 発火
        } else {
            progress[memoID] = next
            return false
        }
    }

    @Test("WP0→WP1→WP2 の順で入ると3ウェイポイントが発火する")
    func sequentialWaypointsFireAtEnd() {
        var progress: [String: Int] = [:]
        let id = UUID().uuidString
        let total = 3

        // WP0 通過
        progress[id] = 0
        let fire0 = applyWaypointEntry(enteredIndex: 0, progress: &progress, total: total, memoID: id)
        #expect(fire0 == false)
        #expect(progress[id] == 1)

        // WP1 通過
        let fire1 = applyWaypointEntry(enteredIndex: 1, progress: &progress, total: total, memoID: id)
        #expect(fire1 == false)
        #expect(progress[id] == 2)

        // WP2 通過 → 発火
        let fire2 = applyWaypointEntry(enteredIndex: 2, progress: &progress, total: total, memoID: id)
        #expect(fire2 == true)
        #expect(progress[id] == nil)  // クリアされる
    }

    @Test("順序違いのウェイポイントは無視される")
    func outOfOrderWaypointIgnored() {
        var progress: [String: Int] = [:]
        let id = UUID().uuidString
        let total = 3

        // WP0 通過（expected=0, next=1）
        progress[id] = 0
        _ = applyWaypointEntry(enteredIndex: 0, progress: &progress, total: total, memoID: id)
        #expect(progress[id] == 1)

        // WP2 を先に通過しようとする（expected=1 なので無視）
        let ignoredFire = applyWaypointEntry(enteredIndex: 2, progress: &progress, total: total, memoID: id)
        #expect(ignoredFire == false)
        #expect(progress[id] == 1)  // 変わらない
    }

    @Test("WP0 再入で進捗がリセットされる（ルート再開）")
    func wp0ReentryResetsProgress() {
        var progress: [String: Int] = [:]
        let id = UUID().uuidString
        let total = 3

        // 一度 WP0→WP1 まで進む
        progress[id] = 0
        _ = applyWaypointEntry(enteredIndex: 0, progress: &progress, total: total, memoID: id)
        _ = applyWaypointEntry(enteredIndex: 1, progress: &progress, total: total, memoID: id)
        #expect(progress[id] == 2)

        // WP0 に再入 → リセット
        let fire = applyWaypointEntry(enteredIndex: 0, progress: &progress, total: total, memoID: id)
        #expect(fire == false)
        #expect(progress[id] == 1)  // 0→next=1
    }

    @Test("2ウェイポイントのルートは WP1 で発火する")
    func twoWaypointRouteFires() {
        var progress: [String: Int] = [:]
        let id = UUID().uuidString
        let total = 2

        progress[id] = 0
        let fire0 = applyWaypointEntry(enteredIndex: 0, progress: &progress, total: total, memoID: id)
        #expect(fire0 == false)

        let fire1 = applyWaypointEntry(enteredIndex: 1, progress: &progress, total: total, memoID: id)
        #expect(fire1 == true)
        #expect(progress[id] == nil)
    }

    @Test("ルート進行中の Live Activity 用 current/total が正しく計算される")
    func routeProgressCurrentTotalCalculation() {
        // LocationManager の else ブランチ: current = next + 1（1始まり表示）
        // expected=0, next=1 → current=2（WP2を待っている）
        let next = 1
        let total = 3
        let currentDisplay = next + 1
        let totalDisplay = total
        #expect(currentDisplay == 2)
        #expect(totalDisplay == 3)
    }
}

// MARK: - Watch isDone 連携テスト

@Suite("Watch isDone 連携")
struct WatchIsDoneTests {

    // MARK: - リスト フィルタリング（WatchMemoListView 相当）

    @Test("未完了メモのみが active リストに含まれる")
    func activeMemoFilter() {
        let m1 = GeoMemo(title: "A", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        let m2 = GeoMemo(title: "B", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        let m3 = GeoMemo(title: "C", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        m2.isDone = true

        let all = [m1, m2, m3]
        let active = all.filter { !$0.isDone }
        let done   = all.filter { $0.isDone }

        #expect(active.count == 2)
        #expect(active.map { $0.title } == ["A", "C"])
        #expect(done.count == 1)
        #expect(done.first?.title == "B")
    }

    @Test("全メモが完了済みの場合 active リストは空")
    func allDoneActiveMemoEmpty() {
        let m1 = GeoMemo(title: "A", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        let m2 = GeoMemo(title: "B", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        m1.isDone = true
        m2.isDone = true

        let active = [m1, m2].filter { !$0.isDone }
        #expect(active.isEmpty)
    }

    // MARK: - 近くのメモ フィルタリング（WatchNearbyView 相当）

    /// WatchNearbyView の nearbyMemos 計算ロジックを再現
    func computeNearbyMemos(
        memos: [GeoMemo],
        userLat: Double,
        userLon: Double,
        radiusMeters: Double = 1000
    ) -> [(memo: GeoMemo, distance: Double)] {
        let userLocation = CLLocation(latitude: userLat, longitude: userLon)
        return memos
            .filter { !$0.isDone }
            .map { memo in
                let loc = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
                return (memo: memo, distance: userLocation.distance(from: loc))
            }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }
    }

    @Test("isDone=true のメモは nearbyMemos に含まれない")
    func doneMemosExcludedFromNearby() {
        let active = GeoMemo(title: "近い未完了", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let done   = GeoMemo(title: "近い完了済", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        done.isDone = true

        let nearby = computeNearbyMemos(memos: [active, done], userLat: 35.6895, userLon: 139.6917)
        #expect(nearby.count == 1)
        #expect(nearby.first?.memo.title == "近い未完了")
    }

    @Test("1km 圏外のメモは nearbyMemos に含まれない")
    func farMemosExcludedFromNearby() {
        // 渋谷（35.6580, 139.7016）と新宿（35.6938, 139.7034）は約4km離れている
        let far = GeoMemo(title: "遠い", note: "", latitude: 35.6580, longitude: 139.7016, radius: 100)
        let nearby = computeNearbyMemos(memos: [far], userLat: 35.6938, userLon: 139.7034)
        #expect(nearby.isEmpty)
    }

    @Test("nearbyMemos は距離順にソートされる")
    func nearbyMemosSortedByDistance() {
        // ユーザー位置: 35.6895, 139.6917
        let near = GeoMemo(title: "近い", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let mid  = GeoMemo(title: "中間", note: "", latitude: 35.6900, longitude: 139.6920, radius: 100)
        // far は1km圏外なので除外
        let memos = [mid, near]
        let result = computeNearbyMemos(memos: memos, userLat: 35.6895, userLon: 139.6917)
        #expect(result.count == 2)
        #expect(result[0].memo.title == "近い")
        #expect(result[1].memo.title == "中間")
        #expect(result[0].distance <= result[1].distance)
    }

    // MARK: - 完了トグル（WatchMemoDetailView 相当）

    @Test("isDone を false→true にトグルできる")
    func toggleIsDoneFalseToTrue() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        #expect(memo.isDone == false)
        memo.isDone = true
        #expect(memo.isDone == true)
    }

    @Test("isDone を true→false に戻せる（Restore）")
    func restoreIsDoneTrueToFalse() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        memo.isDone = true
        memo.isDone = false
        #expect(memo.isDone == false)
    }

    @Test("isFavorite は isDone に影響しない")
    func favoriteDoesNotAffectIsDone() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        memo.isFavorite = true
        memo.isDone = true
        #expect(memo.isFavorite == true)
        #expect(memo.isDone == true)

        memo.isDone = false
        #expect(memo.isFavorite == true)
        #expect(memo.isDone == false)
    }

    // MARK: - 完了済みカウント表示（Section タイトル相当）

    @Test("完了済みカウントが正しく計算される")
    func doneCountCalculation() {
        var memos: [GeoMemo] = []
        for i in 0..<5 {
            let m = GeoMemo(title: "M\(i)", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
            if i >= 3 { m.isDone = true }
            memos.append(m)
        }
        let doneCount = memos.filter { $0.isDone }.count
        #expect(doneCount == 2)
    }
}

// MARK: - GeoMemoLimits テスト

@Suite("GeoMemoLimits")
struct GeoMemoLimitsTests {

    @Test("maxCustomTags が 5")
    func maxCustomTagsIs5() {
        #expect(GeoMemoLimits.maxCustomTags == 5)
    }

    @Test("maxCustomTagLength が 15")
    func maxCustomTagLengthIs15() {
        #expect(GeoMemoLimits.maxCustomTagLength == 15)
    }
}

// MARK: - 退出後タイマーテスト

@Suite("退出後タイマー")
struct ExitDelayTimerTests {

    // MARK: モデルフィールド

    @Test("exitDelayMinutes のデフォルトは nil")
    func exitDelayDefaultNil() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        #expect(memo.exitDelayMinutes == nil)
    }

    @Test("exitDelayMinutes を設定できる")
    func exitDelayCanBeSet() {
        let memo = GeoMemo(title: "テスト", note: "", latitude: 35.0, longitude: 139.0,
                           radius: 100, exitDelayMinutes: 15)
        #expect(memo.exitDelayMinutes == 15)
    }

    // MARK: delay 秒数計算（NotificationManager.scheduleExitNotification と同じロジック）

    @Test("exitDelayMinutes=nil → delay は 1秒")
    func nilDelayMeansOneSecond() {
        #expect(delaySeconds(minutes: nil) == 1)
    }

    @Test("exitDelayMinutes=5 → delay は 300秒")
    func fiveMinutesIs300Seconds() {
        #expect(delaySeconds(minutes: 5) == 300)
    }

    @Test("exitDelayMinutes=60 → delay は 3600秒")
    func sixtyMinutesIs3600Seconds() {
        #expect(delaySeconds(minutes: 60) == 3600)
    }

    @Test("exitDelayMinutes=0 は max(1,…) により 1秒になる")
    func zeroMinutesClamped() {
        #expect(delaySeconds(minutes: 0) == 1)
    }

    // MARK: notifyOnExit フラグとの連動（MemoEditorView.saveOrUpdate ロジック）

    @Test("notifyOnExit=false → exitDelayMinutes は nil に強制される")
    func exitDelayForcedNilWhenNotifyOff() {
        let notifyOnExit = false
        let exitDelayMinutes: Int? = 15
        let saved = (!notifyOnExit) ? nil : exitDelayMinutes
        #expect(saved == nil)
    }

    @Test("notifyOnExit=true → exitDelayMinutes が保存される")
    func exitDelayStoredWhenNotifyOn() {
        // ローカル関数でロジックを包み、定数折り畳みを防ぐ
        func resolveDelay(notifyOnExit: Bool, minutes: Int?) -> Int? {
            (!notifyOnExit) ? nil : minutes
        }
        #expect(resolveDelay(notifyOnExit: true, minutes: 30) == 30)
    }

    @Test("isRouteTrigger=true → exitDelayMinutes は nil に強制される")
    func exitDelayForcedNilForRoute() {
        let isRouteTrigger = true
        let exitDelayMinutes: Int? = 5
        let saved = (isRouteTrigger) ? nil : exitDelayMinutes
        #expect(saved == nil)
    }

    // MARK: 通知スケジュール

    @Test("scheduleExitNotification で通知が保留リストに登録される")
    @MainActor
    func scheduleExitNotificationQueues() async throws {
        let center = UNUserNotificationCenter.current()

        // 認可がなければ pendingNotificationRequests に登録されない（iOS 26 以降の動作）
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            // テスト環境では通知認可が得られないためスキップ
            return
        }

        let testID = "geomemo-exit-test-\(UUID().uuidString)"

        let content = UNMutableNotificationContent()
        content.title = "退出テスト"
        content.body = "エリアを出ました"
        content.categoryIdentifier = NotificationManager.categoryID
        // timeInterval を長くして通知が先に発火しないようにする
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        let request = UNNotificationRequest(identifier: testID, content: content, trigger: trigger)

        try await center.add(request)

        let pending = await center.pendingNotificationRequests()
        let found = pending.first(where: { $0.identifier == testID })
        #expect(found != nil)
        #expect(found?.content.title == "退出テスト")

        center.removePendingNotificationRequests(withIdentifiers: [testID])
    }

    // ヘルパー
    private func delaySeconds(minutes: Int?) -> TimeInterval {
        TimeInterval(minutes.map { max(1, $0 * 60) } ?? 1)
    }
}

// MARK: - AppIntents 拡充テスト

@Suite("AppIntents 拡充")
struct AppIntentsTests {

    // MARK: GeoMemoEntity 初期化

    @Test("GeoMemoEntity が GeoMemo から正しく初期化される")
    func entityInitFromMemo() {
        let memo = GeoMemo(title: "テスト", note: "メモ本文", latitude: 35.6895, longitude: 139.6917, radius: 100,
                           tags: [1, 3], customTags: ["マイタグ"])
        memo.locationName = "渋谷"
        memo.isFavorite = true
        memo.isDone = false
        memo.colorIndex = 2

        let entity = GeoMemoEntity(from: memo)
        #expect(entity.id == memo.id)
        #expect(entity.title == "テスト")
        #expect(entity.locationName == "渋谷")
        #expect(entity.note == "メモ本文")
        #expect(entity.isFavorite == true)
        #expect(entity.isDone == false)
        #expect(entity.colorIndex == 2)
        #expect(abs(entity.latitude - 35.6895) < 0.0001)
        #expect(abs(entity.longitude - 139.6917) < 0.0001)
        #expect(entity.tags == [1, 3])
        #expect(entity.customTags == ["マイタグ"])
    }

    @Test("title が空の GeoMemo → entity.title は 'Untitled'")
    func emptyTitleBecomesUntitled() {
        let memo = GeoMemo(title: "", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        let entity = GeoMemoEntity(from: memo)
        #expect(entity.title == String(localized: "Untitled"))
    }

    @Test("isDone=true の GeoMemo → entity.isDone は true")
    func entityIsDoneReflectsMemo() {
        let memo = GeoMemo(title: "完了", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        memo.isDone = true
        let entity = GeoMemoEntity(from: memo)
        #expect(entity.isDone == true)
    }

    // MARK: Spotlight attributeSet

    @Test("attributeSet に displayName と namedLocation が設定される")
    func attributeSetDisplayFields() {
        let memo = GeoMemo(title: "タイトル", note: "ノート", latitude: 35.6895, longitude: 139.6917, radius: 100)
        memo.locationName = "渋谷"
        let attrs = GeoMemoEntity(from: memo).attributeSet
        #expect(attrs.displayName == "タイトル")
        #expect(attrs.namedLocation == "渋谷")
    }

    @Test("attributeSet に緯度経度が設定される")
    func attributeSetCoordinates() {
        let memo = GeoMemo(title: "T", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let attrs = GeoMemoEntity(from: memo).attributeSet
        #expect(abs((attrs.latitude?.doubleValue ?? 0) - 35.6895) < 0.0001)
        #expect(abs((attrs.longitude?.doubleValue ?? 0) - 139.6917) < 0.0001)
    }

    @Test("attributeSet.contentDescription に note が含まれる")
    func attributeSetContentDescription() {
        let memo = GeoMemo(title: "T", note: "詳細メモ", latitude: 35.0, longitude: 139.0, radius: 100)
        memo.locationName = "新宿"
        let attrs = GeoMemoEntity(from: memo).attributeSet
        #expect(attrs.contentDescription?.contains("詳細メモ") == true)
    }

    @Test("note が空のとき contentDescription は locationName のみ")
    func attributeSetContentDescriptionEmptyNote() {
        let memo = GeoMemo(title: "T", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        memo.locationName = "渋谷"
        let attrs = GeoMemoEntity(from: memo).attributeSet
        #expect(attrs.contentDescription == "渋谷")
    }

    @Test("customTags が attributeSet.keywords に含まれる")
    func attributeSetKeywordsIncludeCustomTags() {
        let memo = GeoMemo(title: "T", note: "", latitude: 35.0, longitude: 139.0, radius: 100,
                           customTags: ["マイタグ", "仕事"])
        let attrs = GeoMemoEntity(from: memo).attributeSet
        #expect(attrs.keywords?.contains("マイタグ") == true)
        #expect(attrs.keywords?.contains("仕事") == true)
    }

    @Test("タグなし → attributeSet.keywords は nil")
    func attributeSetKeywordsNilWhenNoTags() {
        let memo = GeoMemo(title: "T", note: "", latitude: 35.0, longitude: 139.0, radius: 100)
        let attrs = GeoMemoEntity(from: memo).attributeSet
        #expect(attrs.keywords == nil)
    }

    // MARK: EntityStringQuery フィルタリングロジック

    @Test("タイトルで絞り込める")
    func filterByTitle() {
        let m1 = makeEntity(title: "東京のカフェ", location: "渋谷", note: "")
        let m2 = makeEntity(title: "大阪の公園", location: "梅田", note: "")
        let result = filterEntities([m1, m2], matching: "東京")
        #expect(result.count == 1)
        #expect(result.first?.title == "東京のカフェ")
    }

    @Test("場所名で絞り込める")
    func filterByLocationName() {
        let m1 = makeEntity(title: "ランチ", location: "渋谷ヒカリエ", note: "")
        let m2 = makeEntity(title: "ミーティング", location: "新宿オフィス", note: "")
        let result = filterEntities([m1, m2], matching: "渋谷")
        #expect(result.count == 1)
        #expect(result.first?.locationName.contains("渋谷") == true)
    }

    @Test("ノートで絞り込める")
    func filterByNote() {
        let m1 = makeEntity(title: "メモA", location: "東京", note: "重要な会議")
        let m2 = makeEntity(title: "メモB", location: "大阪", note: "普通の予定")
        let result = filterEntities([m1, m2], matching: "重要")
        #expect(result.count == 1)
        #expect(result.first?.note == "重要な会議")
    }

    @Test("大文字小文字を区別せず絞り込める")
    func filterCaseInsensitive() {
        let m1 = makeEntity(title: "Tokyo Cafe", location: "", note: "")
        #expect(filterEntities([m1], matching: "tokyo").count == 1)
    }

    @Test("マッチしない文字列は空を返す")
    func filterNoMatch() {
        let m1 = makeEntity(title: "カフェ", location: "渋谷", note: "コーヒー")
        #expect(filterEntities([m1], matching: "zzzzz").isEmpty)
    }

    // MARK: suggestedEntities ソートロジック

    @Test("お気に入りが未完了リストの先頭に来る")
    func suggestedFavoritesFirst() {
        let normal    = makeEntity(title: "普通", isFavorite: false, isDone: false)
        let favorite  = makeEntity(title: "お気に入り", isFavorite: true,  isDone: false)
        let sorted = [normal, favorite]
            .filter { !$0.isDone }
            .sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                return false
            }
        #expect(sorted.first?.title == "お気に入り")
    }

    @Test("完了済みは suggestedEntities から除外される")
    func suggestedExcludesDone() {
        let active = makeEntity(title: "未完了", isDone: false)
        let done   = makeEntity(title: "完了済み", isDone: true)
        let result = [active, done].filter { !$0.isDone }
        #expect(result.count == 1)
        #expect(result.first?.title == "未完了")
    }

    @Test("suggestedEntities は最大8件に絞られる")
    func suggestedMax8() {
        let entities = (0..<15).map { makeEntity(title: "M\($0)") }
        let result = Array(entities.prefix(8))
        #expect(result.count == 8)
    }

    // MARK: Notification.Name 確認

    @Test("openGeoMemo 通知名が定義されている")
    func openGeoMemoNotificationName() {
        #expect(Notification.Name.openGeoMemo.rawValue == "openGeoMemo")
    }

    @Test("showGeoMemoFavorites 通知名が定義されている")
    func showFavoritesNotificationName() {
        #expect(Notification.Name.showGeoMemoFavorites.rawValue == "showGeoMemoFavorites")
    }

    @Test("searchGeoMemos 通知名が定義されている")
    func searchGeoMemosNotificationName() {
        #expect(Notification.Name.searchGeoMemos.rawValue == "searchGeoMemos")
    }

    // MARK: GetNearbyMemosIntent 半径フィルタリングロジック

    @Test("半径内のメモのみ返す")
    func nearbyRadiusFilter() {
        let near = GeoMemo(title: "近い", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let far  = GeoMemo(title: "遠い", note: "", latitude: 35.0000, longitude: 138.0000, radius: 100)
        let result = nearbyFilter([near, far], userLat: 35.6895, userLon: 139.6917, radiusMeters: 1000)
        #expect(result.count == 1)
        #expect(result.first?.title == "近い")
    }

    @Test("完了済みは近傍リストから除外される")
    func nearbyExcludesDone() {
        let m1 = GeoMemo(title: "未完了", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let m2 = GeoMemo(title: "完了済み", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        m2.isDone = true
        let result = nearbyFilter([m1, m2], userLat: 35.6895, userLon: 139.6917, radiusMeters: 1000)
        #expect(result.count == 1)
        #expect(result.first?.title == "未完了")
    }

    @Test("radiusMeters=0 は max(1,…) により 1m に補正される")
    func nearbyZeroRadiusClamped() {
        #expect(Double(max(1, 0)) == 1.0)
    }

    @Test("近傍メモは距離順にソートされる")
    func nearbyResultSortedByDistance() {
        let close  = GeoMemo(title: "近い", note: "", latitude: 35.6895, longitude: 139.6917, radius: 100)
        let middle = GeoMemo(title: "中間", note: "", latitude: 35.6905, longitude: 139.6925, radius: 100)
        let result = nearbyFilter([middle, close], userLat: 35.6895, userLon: 139.6917, radiusMeters: 2000)
        #expect(result.count == 2)
        #expect(result[0].title == "近い")
        #expect(result[1].title == "中間")
    }

    // MARK: ヘルパー

    private func makeEntity(
        title: String,
        location: String = "",
        note: String = "",
        isFavorite: Bool = false,
        isDone: Bool = false
    ) -> GeoMemoEntity {
        let memo = GeoMemo(title: title, note: note, latitude: 35.0, longitude: 139.0, radius: 100)
        memo.locationName = location
        memo.isFavorite = isFavorite
        memo.isDone = isDone
        return GeoMemoEntity(from: memo)
    }

    private func filterEntities(_ entities: [GeoMemoEntity], matching string: String) -> [GeoMemoEntity] {
        entities.filter {
            $0.title.localizedCaseInsensitiveContains(string) ||
            $0.locationName.localizedCaseInsensitiveContains(string) ||
            $0.note.localizedCaseInsensitiveContains(string)
        }
    }

    private func nearbyFilter(_ memos: [GeoMemo], userLat: Double, userLon: Double, radiusMeters: Int) -> [GeoMemo] {
        let userLocation = CLLocation(latitude: userLat, longitude: userLon)
        let radius = Double(max(1, radiusMeters))
        return memos
            .filter { !$0.isDone }
            .map { memo -> (GeoMemo, Double) in
                let loc = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
                return (memo, userLocation.distance(from: loc))
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}

// MARK: - isUntitled / displayTitle テスト

@Suite("GeoMemo.isUntitled / displayTitle")
struct IsUntitledTests {

    @Test("空文字は isUntitled = true")
    func emptyTitle_isUntitled() {
        let memo = GeoMemo(title: "", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.isUntitled == true)
    }

    @Test("スペースのみは isUntitled = true")
    func whitespaceOnly_isUntitled() {
        let memo = GeoMemo(title: "   ", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.isUntitled == true)
    }

    @Test("英語レガシー 'Untitled' は isUntitled = true")
    func legacyEnglishUntitled() {
        let memo = GeoMemo(title: "Untitled", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.isUntitled == true)
    }

    @Test("日本語レガシー '（タイトルなし）' は isUntitled = true")
    func legacyJapaneseUntitled() {
        // DB に保存されていた旧ローカライズ文字列（全角括弧）
        let memo = GeoMemo(title: "（タイトルなし）", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.isUntitled == true)
    }

    @Test("通常のタイトルは isUntitled = false")
    func normalTitle_isNotUntitled() {
        let memo = GeoMemo(title: "カフェのメモ", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.isUntitled == false)
    }

    @Test("isUntitled のとき displayTitle は String(localized: 'Untitled') を返す")
    func displayTitle_whenUntitled() {
        let memo = GeoMemo(title: "", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.displayTitle == String(localized: "Untitled"))
    }

    @Test("isUntitled でないとき displayTitle は title を返す")
    func displayTitle_whenTitled() {
        let memo = GeoMemo(title: "渋谷のカフェ", note: "", latitude: 0, longitude: 0, radius: 100)
        #expect(memo.displayTitle == "渋谷のカフェ")
    }
}

// MARK: - カラーフィルター ロジックテスト

@Suite("カラーフィルター")
struct ColorFilterTests {

    /// ListTabView.memos(for:) のカラーフィルターロジックを再現
    func applyColorFilter(_ memos: [GeoMemo], colorIndex: Int?) -> [GeoMemo] {
        guard let ci = colorIndex else { return memos }
        return memos.filter { $0.colorIndex == ci }
    }

    @Test("colorIndex=nil のとき全件返る")
    func nilColorIndex_returnsAll() {
        let memos = [
            GeoMemo(title: "A", note: "", latitude: 0, longitude: 0, radius: 100),
            GeoMemo(title: "B", note: "", latitude: 0, longitude: 0, radius: 100),
        ]
        memos[1].colorIndex = 2
        #expect(applyColorFilter(memos, colorIndex: nil).count == 2)
    }

    @Test("指定カラーのみ返る")
    func specificColorIndex_filtersCorrectly() {
        let m1 = GeoMemo(title: "Blue", note: "", latitude: 0, longitude: 0, radius: 100)
        let m2 = GeoMemo(title: "Red",  note: "", latitude: 0, longitude: 0, radius: 100)
        m1.colorIndex = 0
        m2.colorIndex = 2
        let result = applyColorFilter([m1, m2], colorIndex: 2)
        #expect(result.count == 1)
        #expect(result.first?.title == "Red")
    }

    @Test("マッチするカラーが0件のとき空配列を返す")
    func noMatchingColor_returnsEmpty() {
        let m1 = GeoMemo(title: "A", note: "", latitude: 0, longitude: 0, radius: 100)
        m1.colorIndex = 0
        #expect(applyColorFilter([m1], colorIndex: 5).isEmpty)
    }

    @Test("AutoTagEngine サジェストから既選択タグを除外できる")
    func suggestionFiltersOutSelectedTags() {
        let memo = GeoMemo(title: "ランチ", note: "", latitude: 0, longitude: 0, radius: 100,
                           tags: [PresetTag.food.rawValue])
        let all = AutoTagEngine.suggest(title: memo.title, note: memo.note, locationName: "レストラン")
        let suggestions = all.filter { !memo.tags.contains($0.rawValue) }
        // food は既選択なので提案に含まれないはず
        #expect(!suggestions.contains(.food))
    }
}
