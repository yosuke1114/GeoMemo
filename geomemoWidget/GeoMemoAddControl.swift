import WidgetKit
import SwiftUI
import AppIntents

// コントロールセンター・ロック画面・アクションボタンから「新しいメモ」を開く。
// 位置は取らず、アプリを開いて作成画面を出すだけ（`geomemo://new` を `DeepLinkRoute` が受ける）。
// iOS のコントロールは、対応する Apple Watch にも自動で現れる。
struct GeoMemoAddControl: ControlWidget {
    static let kind = "com.yokuro.geomemo.addMemoControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(WidgetDeepLink.newMemoURL)) {
                Label("Add Memo", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Add Memo")
        .description("Open GeoMemo to add a new memo")
    }
}
