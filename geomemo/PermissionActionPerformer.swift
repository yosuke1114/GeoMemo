import SwiftUI
import UIKit

/// 許可の案内のボタン（地図のバナー・通知のチェック）を押したときの動作。
///
/// 許可のダイアログは、利用者がボタンを押したときにだけ出す。「常に」は iOS が 1 回しか尋ねないので、
/// ダイアログが出なかった（scene が inactive にならなかった）ときだけ設定アプリを開く。
@MainActor
final class PermissionActionPerformer {
    private let alwaysDialogProbe = SystemDialogProbe()

    func perform(_ action: PermissionNotice.Action) {
        HapticManager.impact(.light)
        switch action {
        case .requestLocation:
            LocationManager.shared.requestWhenInUseAuthorization()
        case .requestAlways:
            // 「あとで」を選んだ人にも、まず「常に」のダイアログを出す。
            let requested = LocationManager.shared.requestAlwaysAuthorization()
            alwaysDialogProbe.begin(requested: requested) { dialogShown in
                if !dialogShown { Self.openSettings() }
            }
        case .requestNotifications:
            Task { _ = await NotificationManager.shared.requestAuthorization() }
        case .openSettings:
            Self.openSettings()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        alwaysDialogProbe.scenePhaseChanged(phase)
    }

    func cancel() {
        alwaysDialogProbe.cancel()
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    static func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
