import Foundation
import CoreLocation
import UIKit
import Combine
import os

@MainActor
class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    private let manager = CLLocationManager()

    /// 領域の入退出の受け手。テストで差し替える。
    var eventHandler: RegionEventHandling = RegionEventService.shared
    /// Live Activity へ「発火したメモ」を伝える（保存先を読むので、テストでは差し替える）。
    var triggerLiveActivity: (String) -> Void = { LiveActivityManager.shared.triggerMemo(id: $0) }
    /// Live Activity へルートの進行を伝える。
    var updateRouteLiveActivity: (String, Int, Int) -> Void = {
        LiveActivityManager.shared.updateRouteProgress(memoID: $0, current: $1, total: $2)
    }

    /// バックグラウンド起動（領域の入退出・ウィジェットなど）では false。位置・方位の更新を始めない判断に使う。
    static var isForeground: Bool { UIApplication.shared.applicationState != .background }

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// 「正確な位置情報」がオフ（おおよその位置のみ）のとき false。
    @Published var isPreciseLocation: Bool = true
    @Published var location: CLLocation?
    @Published var heading: CLHeading?

    /// EMA（指数移動平均）で平滑化した方位角（度）。-1 = 未取得
    @Published var smoothedHeadingDegrees: Double = -1

    // EMA 平滑化係数: 0に近いほど滑らか・遅延大、1に近いほど即応・ノイジー
    private let headingSmoothingAlpha: Double = 0.25
    private var _smoothed: Double = 0

    // MARK: - Pass-through Notification (v1.1)

    /// notifyOnPass=true のメモを監視対象として保持する
    private var passMemosCache: [(id: String, title: String, coordinate: CLLocationCoordinate2D, radius: Double, colorIndex: Int)] = []
    /// 現在接近中と判定しているメモのID（重複更新を防ぐ）
    private var currentApproachingMemoID: String? = nil
    /// 接近検出の距離しきい値（メートル）
    private let approachThreshold: Double = 300

    /// notifyOnPass=true のメモ一覧をキャッシュに登録する。
    /// ContentView などでメモ一覧が変わるたびに呼ぶ。
    func updatePassMemos(_ memos: [GeoMemo]) {
        passMemosCache = memos
            .filter { $0.notifyOnPass && !$0.isRouteTrigger }
            .map { (id: $0.id.uuidString, title: $0.displayTitle,
                    coordinate: $0.coordinate, radius: $0.radius, colorIndex: $0.colorIndex) }

        if passMemosCache.isEmpty {
            // 監視対象がなければ連続更新を止める
            manager.stopUpdatingLocation()
            currentApproachingMemoID = nil
            Task { @MainActor in
                LiveActivityManager.shared.updateApproaching(memoID: nil)
            }
        } else {
            // 監視対象があれば連続位置更新を開始（精度は低め・電池節約）
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 20 // 20m 動くごとに更新
            if manager.authorizationStatus == .authorizedAlways ||
               manager.authorizationStatus == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }

    /// 現在地から最近傍の passThrough メモを探してLiveActivityを更新する。
    private func evaluateProximity(to userLocation: CLLocation) {
        guard !passMemosCache.isEmpty else { return }

        // ジオフェンス境界（edge）までの距離が最小のメモを探す
        var nearest: (id: String, title: String, edgeDistance: Double, colorIndex: Int)? = nil
        for memo in passMemosCache {
            let memoLocation = CLLocation(latitude: memo.coordinate.latitude,
                                         longitude: memo.coordinate.longitude)
            let centerDistance = userLocation.distance(from: memoLocation)
            let edgeDistance = max(0, centerDistance - memo.radius)
            if edgeDistance <= approachThreshold {
                if nearest == nil || edgeDistance < nearest!.edgeDistance {
                    nearest = (id: memo.id, title: memo.title,
                               edgeDistance: edgeDistance, colorIndex: memo.colorIndex)
                }
            }
        }

        if let nearest {
            let distanceInt = Int(nearest.edgeDistance.rounded())
            // 同じメモへの更新は20m以上変化がないとスキップ
            if nearest.id == currentApproachingMemoID,
               let prevDist = lastApproachingDistance,
               abs(prevDist - distanceInt) < 20 { return }

            currentApproachingMemoID = nearest.id
            lastApproachingDistance = distanceInt
            Task { @MainActor in
                LiveActivityManager.shared.updateApproaching(memoID: nearest.id, distance: distanceInt)
            }
        } else if currentApproachingMemoID != nil {
            // 接近メモがなくなった → クリア
            currentApproachingMemoID = nil
            lastApproachingDistance = nil
            Task { @MainActor in
                LiveActivityManager.shared.updateApproaching(memoID: nil)
            }
        }
    }

    private var lastApproachingDistance: Int? = nil

    // MARK: - Route Progress (メモリキャッシュ + UserDefaults 永続化)
    // バックグラウンド起動後も didEnterRegion で参照できるよう UserDefaults に書く。
    // ただし都度 UserDefaults を読むのではなく、起動時に一度だけロードしてメモリで管理する。

    private var _routeProgress: [String: Int]? = nil
    private var routeProgress: [String: Int] {
        get {
            if let cached = _routeProgress { return cached }
            let loaded = UserDefaults.standard.object(forKey: "routeProgress") as? [String: Int] ?? [:]
            _routeProgress = loaded
            return loaded
        }
        set {
            _routeProgress = newValue
            UserDefaults.standard.set(newValue, forKey: "routeProgress")
        }
    }

    private var _routeWaypointCounts: [String: Int]? = nil
    private var routeWaypointCounts: [String: Int] {
        get {
            if let cached = _routeWaypointCounts { return cached }
            let loaded = UserDefaults.standard.object(forKey: "routeWaypointCounts") as? [String: Int] ?? [:]
            _routeWaypointCounts = loaded
            return loaded
        }
        set {
            _routeWaypointCounts = newValue
            UserDefaults.standard.set(newValue, forKey: "routeWaypointCounts")
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.headingFilter = kCLHeadingFilterNone // すべての変化を即通知
        authorizationStatus = manager.authorizationStatus
        isPreciseLocation = manager.accuracyAuthorization == .fullAccuracy
        // アプリが終了している間、significant location change の購読は止まる。入れ替え中（円が登録済み）で
        // 「常に許可」なら、起動のたびに開始し直す（`didFinishLaunching` で生成される）。
        circleCache = readRegisteredCircle()
        if circleCache != nil { setSignificantChangeMonitoring(true) }
    }

    // 許可ダイアログは「説明を読んだユーザーがボタンを押したとき」だけ出す。
    // 起動時やデリゲートからの自動要求はしない（オンボーディングと地図のバナーから呼ぶ）。

    /// 「使用中のみ許可」を求める。未決定のときだけダイアログが出る。
    func requestWhenInUseAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// 「常に許可」への昇格を求める。使用中のときだけ有効で、iOS は 1 回しか出さない。
    /// 要求を出したら true（ダイアログが実際に出るかは iOS 次第）。使用中でなければ何もせず false。
    @discardableResult
    func requestAlwaysAuthorization() -> Bool {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return false }
        manager.requestAlwaysAuthorization()
        return true
    }

    /// 許可済みなら現在地と方位のウォームアップを始める。ダイアログは出さない。
    func warmUp() {
        guard Self.isForeground,
              manager.authorizationStatus == .authorizedWhenInUse ||
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
        manager.startUpdatingHeading()
    }

    /// マップ表示中のみ呼び出す。非表示時は stopHeading() で停止すること。
    func startHeading() {
        guard Self.isForeground,
              manager.authorizationStatus == .authorizedWhenInUse ||
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        manager.stopUpdatingHeading()
        heading = nil
        smoothedHeadingDegrees = -1
    }

    /// Request a fresh one-shot location update (e.g. for the "center on me" button).
    func refreshLocation() {
        guard Self.isForeground,
              manager.authorizationStatus == .authorizedWhenInUse ||
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    /// iOS は同時に最大 20 個のジオフェンスしか監視できない
    static let maxMonitoredRegions = 20

    /// 領域の識別子（共有メモの ID を含む）は `.private` で出す。
    nonisolated static let logger = Logger(subsystem: "com.yokuro.geomemo", category: "location")

    /// `checkInitialState` が true なら、登録の直後に内側にいるかを確かめる（入れ替えで登録した領域の取りこぼし対策）。
    /// すでに領域の中にいる状態で登録すると、進入のイベントは出ない。
    func startMonitoring(region: CLCircularRegion, checkInitialState: Bool = false) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            print("Geofencing is not available on this device")
            return
        }
        guard !manager.monitoredRegions.contains(where: { $0.identifier == region.identifier }) else { return }
        guard manager.monitoredRegions.count < Self.maxMonitoredRegions else {
            Self.logger.warning("20-region limit reached; cannot monitor \(region.identifier, privacy: .private)")
            return
        }
        // 状態の確認は、iOS が登録を終えた通知（didStartMonitoringFor）のあとにする
        if checkInitialState { pendingStateChecks.insert(region.identifier) }
        manager.startMonitoring(for: region)
    }

    func stopMonitoring(memoID: String) {
        if let region = manager.monitoredRegions.first(where: { $0.identifier == memoID }) {
            manager.stopMonitoring(for: region)
        }
        forgetInside(memoID)
        pendingStateChecks.remove(memoID)
    }

    /// 今登録されている領域の識別子（差分での登録に使う）。
    var monitoredRegionIdentifiers: Set<String> { Set(manager.monitoredRegions.map(\.identifier)) }

    // MARK: - Route Trigger Monitoring

    /// Waypoint identifier format: "{memoID}|wp|{index}"
    func startMonitoringRoute(for memo: GeoMemo) {
        let waypoints = memo.routeWaypoints
        guard waypoints.count >= 2 else { return }

        let memoID = memo.id.uuidString
        // 進捗・総数を記録（バックグラウンド起動後も didEnterRegion で参照できるよう永続化）
        var progress = routeProgress
        progress[memoID] = 0
        routeProgress = progress

        var counts = routeWaypointCounts
        counts[memoID] = waypoints.count
        routeWaypointCounts = counts

        for (index, waypoint) in waypoints.enumerated() {
            let region = CLCircularRegion(
                center: waypoint.coordinate,
                radius: memo.radius,
                identifier: "\(memoID)|wp|\(index)"
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            startMonitoring(region: region)
        }
    }

    func stopMonitoringRoute(memoID: String) {
        let prefix = "\(memoID)|wp|"
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
            manager.stopMonitoring(for: region)
        }
        // 進捗・総数をクリア
        var progress = routeProgress
        progress.removeValue(forKey: memoID)
        routeProgress = progress

        var counts = routeWaypointCounts
        counts.removeValue(forKey: memoID)
        routeWaypointCounts = counts
    }

    /// 実際に登録されている監視中の領域の数（「通知のチェック」で使う）。
    var monitoredRegionCount: Int { manager.monitoredRegions.count }

    /// この端末が場所の監視（ジオフェンス）に対応しているか。
    nonisolated static var isGeofencingAvailable: Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    /// Stop all currently monitored regions.
    func stopAllMonitoring() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        insideLedger = InsideLedger()
        recentEntries = RecentEntries()
        pendingStateChecks.removeAll()
        circleCache = nil
    }

    // MARK: - 近い順の入れ替え（20 件を超えるとき）

    /// 入れ替え用の円を張る（現在地中心。出たら入れ替える）。前の円は外す。
    /// 円の中心はアプリ側には保存しない（登録した領域そのものを読む。位置の履歴は持たない）。
    func startRotationCircle(center: CLLocationCoordinate2D, radius: Double) {
        stopRotationCircle()
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        guard manager.monitoredRegions.count < Self.maxMonitoredRegions else {
            // 張れないときは円が無いものとして扱い、位置の更新のたびに入れ替えを繰り返さない
            Self.logger.warning("20-region limit reached; cannot place the rotation circle")
            return
        }
        let region = CLCircularRegion(center: center, radius: radius, identifier: NearestRotation.circleIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        // 登録の直後に、円の外にいないかを確かめる（精度の粗い位置で張った場合の保険。1 回だけ入れ替える）
        pendingStateChecks.insert(NearestRotation.circleIdentifier)
        manager.startMonitoring(for: region)
        circleCache = RotationCircle(latitude: center.latitude, longitude: center.longitude, radius: region.radius)
    }

    func stopRotationCircle() {
        for region in manager.monitoredRegions where region.identifier == NearestRotation.circleIdentifier {
            manager.stopMonitoring(for: region)
        }
        pendingStateChecks.remove(NearestRotation.circleIdentifier)
        circleCache = nil
    }

    /// 大きな移動のときだけ起きる位置の更新（円の補助。円の退出は遅れることがあるため）。
    /// 「常に許可」のときだけ始める。
    func setSignificantChangeMonitoring(_ enabled: Bool) {
        if enabled {
            guard manager.authorizationStatus == .authorizedAlways,
                  CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    /// 登録されている入れ替え用の円（読むだけ。位置更新のたびに引くのでキャッシュを返す）。
    var rotationCircle: RotationCircle? { circleCache }
    private var circleCache: RotationCircle?

    private func readRegisteredCircle() -> RotationCircle? {
        guard let region = manager.monitoredRegions.first(where: { $0.identifier == NearestRotation.circleIdentifier })
                as? CLCircularRegion else { return nil }
        return RotationCircle(latitude: region.center.latitude, longitude: region.center.longitude, radius: region.radius)
    }

    /// ルートの進み具合（1 以上なら、入れ替えで外さない）。
    func routeProgressValue(memoID: String) -> Int { routeProgress[memoID] ?? 0 }

    /// iOS が監視できる円の最大の半径（m）。
    var maximumRegionRadius: Double { manager.maximumRegionMonitoringDistance }

    private static let insideLedgerKey = "geomemo.rotation.inside"

    /// 入れ替えのとき、内側として扱った領域の控え（重複通知の防止）。
    private var insideLedger: InsideLedger {
        get {
            if let cached = _insideLedger { return cached }
            let loaded = UserDefaults.standard.data(forKey: Self.insideLedgerKey)
                .flatMap { try? JSONDecoder().decode(InsideLedger.self, from: $0) } ?? InsideLedger()
            _insideLedger = loaded
            return loaded
        }
        set {
            _insideLedger = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.insideLedgerKey)
            }
        }
    }
    private var _insideLedger: InsideLedger?
    /// 登録の直後に内側かを確かめる領域（登録の完了を待っている・結果を待っている）。
    var pendingStateChecks: Set<String> = []
    /// 状態確認で進入として扱った時刻（直後の進入イベントを捨てる）。
    private var recentEntries = RecentEntries()
    var now: () -> Date = { Date() }

    private var lastCircleRecheck: Date = .distantPast

    private func markInside(_ id: String) {
        var ledger = insideLedger
        ledger.insert(id)
        insideLedger = ledger
    }

    private func forgetInside(_ id: String) {
        guard insideLedger.contains(id) else { return }
        var ledger = insideLedger
        ledger.remove(id)
        insideLedger = ledger
    }

    /// 現在地を取る。直近（`maxAge` 秒以内）のものがあればそれを返し、なければ 1 回だけ要求する。
    /// 取れなければ（時間切れ・失敗）最後に分かっている現在地。
    func freshLocation(maxAge: TimeInterval = 30) async -> CLLocation? {
        if let location, abs(location.timestamp.timeIntervalSinceNow) <= maxAge { return location }
        guard isLocationAuthorized() else { return location }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 {
                waiterGeneration += 1
                let generation = waiterGeneration
                performLocationRequest()
                // 取れないまま待ち続けない（バックグラウンドの実行時間は限られる）。
                // 取れたあとの古い時間切れが、次の待ちを早く終わらせないよう世代で見分ける
                Task { @MainActor [weak self] in
                    guard let timeout = self?.locationTimeout else { return }
                    try? await Task.sleep(for: timeout)
                    guard let self, self.waiterGeneration == generation else { return }
                    self.resumeLocationWaiters()
                }
            }
        }
    }

    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var waiterGeneration = 0
    /// 現在地の要求の待ち時間の上限。
    var locationTimeout: Duration = .seconds(15)
    /// テストで差し替える。
    lazy var isLocationAuthorized: () -> Bool = { [unowned self] in
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }
    lazy var performLocationRequest: () -> Void = { [unowned self] in manager.requestLocation() }

    /// 登録直後の状態確認が終わるのを、短い上限まで待つ（バックグラウンドの実行時間を、結果が届く前に返さないため）。
    func waitForStateChecks(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !pendingStateChecks.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func resumeLocationWaiters() {
        waiterGeneration += 1
        let waiters = locationWaiters
        locationWaiters = []
        for waiter in waiters { waiter.resume(returning: location) }
    }

    /// Check whether a memo's trigger conditions are currently satisfied.
    func shouldNotify(for memo: GeoMemo) -> Bool {
        // 期限・時間帯・曜日の判定は純粋ロジック（`TriggerConditions`）に切り出した
        TriggerConditions.isSatisfied(
            deadline: memo.deadline, timeWindowStart: memo.timeWindowStart,
            timeWindowEnd: memo.timeWindowEnd, activeDays: memo.activeDays,
            now: Date(), calendar: Calendar.current)
    }
}

extension LocationManager: @MainActor CLLocationManagerDelegate {
    // CLLocationManager はデリゲートを生成したスレッド（main）で呼ぶため、適合を MainActor に隔離する
    // （Swift 6 の isolated conformance）。もし main 以外から呼ばれれば実行時チェックで検出される。
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        evaluateProximity(to: latest)
        resumeLocationWaiters()
        // 入れ替え用の円の外に出ていたら入れ替える（円の退出のイベントが遅れても、ここで拾う）。
        // 円が無い（入れ替えが要らない）ときは何もしない。
        if let circle = circleCache, NearestRotation.isOutside(circle, location: latest) {
            eventHandler.handleRotationTrigger()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location request failed: \(error.localizedDescription)")
        resumeLocationWaiters()
    }

    /// iOS が領域の登録を終えた。状態の確認（`requestState`）は、ここから始める（登録の途中だと結果が不確かなため）。
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard pendingStateChecks.contains(region.identifier) else { return }
        manager.requestState(for: region)
    }

    /// 登録の直後の状態確認（`requestState`）の結果。内側にいれば、進入として扱う（進入のイベントは出ないため）。
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        let identifier = region.identifier
        guard pendingStateChecks.remove(identifier) != nil else { return }
        let isInside = state == .inside
        if identifier == NearestRotation.circleIdentifier {
            // 円の外にいた（精度の粗い位置で張った）。入れ替えを 1 回やり直す。繰り返さないよう間隔を空ける
            if state == .outside, now().timeIntervalSince(lastCircleRecheck) > 60 {
                lastCircleRecheck = now()
                eventHandler.handleRotationTrigger()
            }
            return
        }
        guard NearestRotation.shouldTreatAsEntry(isInside: isInside, alreadyInside: insideLedger.contains(identifier)) else {
            if isInside { markInside(identifier) }
            return
        }
        markInside(identifier)
        recentEntries.record(identifier, at: now())
        // 進入のイベントと同じ流れ。期間・時間帯・曜日・完了済みの判定は `RegionEventService` がする。
        if identifier.hasPrefix(SharedMemo.geofencePrefix) {
            eventHandler.handleSharedEntered(identifier: identifier)
        } else if !identifier.contains("|wp|") {
            eventHandler.handleEntered(memoID: identifier)
            triggerLiveActivity(identifier)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading

        let raw = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading

        // 初回は即セット
        if smoothedHeadingDegrees < 0 {
            _smoothed = raw
            smoothedHeadingDegrees = raw
            return
        }

        // 0/360 の折り返しを考慮した最短経路で EMA を適用
        var delta = raw - _smoothed
        if delta > 180  { delta -= 360 }
        if delta < -180 { delta += 360 }
        _smoothed += headingSmoothingAlpha * delta
        if _smoothed < 0   { _smoothed += 360 }
        if _smoothed >= 360 { _smoothed -= 360 }

        smoothedHeadingDegrees = _smoothed
    }

    /// 領域に入った通知を、画面に頼らず出す（アプリが終了した状態からの起動でも動く）。
    @MainActor
    private func notifyEntered(memoID: String) {
        eventHandler.handleEntered(memoID: memoID)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        // 状態確認で進入として扱った直後の同じ領域の進入は、同じ進入（二重に通知しない）
        let alreadyHandled = recentEntries.isRecent(circularRegion.identifier, now: now())
        recentEntries.forget(circularRegion.identifier)
        markInside(circularRegion.identifier)
        if alreadyHandled { return }
        // ウィジェットで完了にしたのに監視が残っていた場合に備え、通知・Live Activity より先に取り込む
        WidgetCompletion.drainPending()
        DiagnosticsLog.shared.recordRegionEvent()
        let identifier = circularRegion.identifier

        if let separatorRange = identifier.range(of: "|wp|") {
            // ── Route waypoint ──────────────────────────────────────────
            let memoID  = String(identifier[..<separatorRange.lowerBound])
            let indexStr = String(identifier[separatorRange.upperBound...])
            guard let enteredIndex = Int(indexStr) else { return }

            var progress = routeProgress
            let total    = routeWaypointCounts[memoID] ?? 0

            // 最初のウェイポイント(0)に入ったら必ず進捗をリセット（ルート再開）
            if enteredIndex == 0 {
                progress[memoID] = 0
                routeProgress = progress
            }

            let expected = progress[memoID] ?? 0

            // 順序が違うウェイポイントは無視
            guard enteredIndex == expected else { return }

            let next = expected + 1
            if total > 0 && next >= total {
                // ── 全ウェイポイント通過 → 発火 ──────────────────────
                progress.removeValue(forKey: memoID)
                routeProgress = progress
                notifyEntered(memoID: memoID)
                triggerLiveActivity(memoID)
            } else {
                // 次のウェイポイントを待つ
                progress[memoID] = next
                routeProgress = progress
                // Live Activity にルート進行状況を反映（次に向かうWP番号を1始まりで表示）
                updateRouteLiveActivity(memoID, next + 1, total)
            }
        } else if identifier.hasPrefix(SharedMemo.geofencePrefix) {
            // ── 共有メモジオフェンス（おつかい / 見守り）──────────────
            eventHandler.handleSharedEntered(identifier: identifier)
        } else {
            // ── 通常ジオフェンス ─────────────────────────────────────
            let memoID = identifier
            notifyEntered(memoID: memoID)
            triggerLiveActivity(memoID)
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        // 入れ替え用の円から出た: 通知ではなく、監視の入れ替え（アプリが終了していても、ここで起動される）
        if circularRegion.identifier == NearestRotation.circleIdentifier {
            eventHandler.handleRotationTrigger()
            return
        }
        forgetInside(circularRegion.identifier)
        recentEntries.forget(circularRegion.identifier)
        WidgetCompletion.drainPending()
        DiagnosticsLog.shared.recordRegionEvent()
        let identifier = circularRegion.identifier
        // ルートウェイポイントと共有メモの退出は無視
        guard !identifier.contains("|wp|") && !identifier.hasPrefix(SharedMemo.geofencePrefix) else { return }
        eventHandler.handleExited(memoID: identifier)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        if let id = region?.identifier { pendingStateChecks.remove(id) }
        Self.logger.error("Monitoring failed for region \(region?.identifier ?? "unknown", privacy: .private): \(error.localizedDescription, privacy: .public)")
    }
}
