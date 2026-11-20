import Foundation
import CoreLocation

/// 監視（ジオフェンス）の登録まわり。地図と「通知のチェック」の両方から使う。
@MainActor
enum GeofenceRegistrar {
    /// 監視したいジオフェンスの数。ルートは経由地ごとに 1 件、受信した有効な依頼も 1 件。
    /// 経由地が 2 未満のルートは登録されない（LocationManager.startMonitoringRoute）ので数えない。
    static func requiredRegionCount(memos: [GeoMemo], sharedMemos: [SharedMemo]) -> Int {
        let own = memos.filter { !$0.isDone }.reduce(0) {
            $0 + MonitoringLimitState.regionCount(isRoute: $1.isRouteTrigger, waypointCount: $1.routeWaypoints.count)
        }
        let received = sharedMemos.filter { !$0.isMyRequest && $0.status == .active }.count
        return own + received
    }

    /// 入れ替えられない（上限に直接数える）領域の数。受信した有効な依頼は 1 件ずつ、いつも先に登録される。
    /// 自分のメモは近い順に入れ替わるので、20 件を超えても「溢れる」ものとして数えない。
    static func fixedRegionCount(sharedMemos: [SharedMemo]) -> Int {
        sharedMemos.filter { !$0.isMyRequest && $0.status == .active }.count
    }

    /// 全部外して登録し直す。受信した依頼を先に、自分のメモは現在地に近い順に（20 件を超えるときは入れ替え用の円も）登録する。
    static func reRegisterAll(memos: [GeoMemo], sharedMemos: [SharedMemo]) {
        LocationManager.shared.stopAllMonitoring()
        GeofenceReconciler.reconcile(memos: memos, sharedMemos: sharedMemos)
    }
}
