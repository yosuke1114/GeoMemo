import UIKit
import CloudKit
import LinkPresentation

/// 依頼の共有に使うシステムの共有シートに渡す中身。
enum ShareActivityContent {
    /// 参加者を限定した共有の URL をそのまま送る（URL を開けるのは参加者だけ）。
    case url(URL)
    /// システムの共有シートで相手を招待する。選んだ相手をシステムが共有の参加者に加える
    /// （`CKShareService.allowedSharingOptions` により「招待した人だけ」に限定）。
    case cloudKitInvite(CKShare, CKContainer)
}

/// `UIActivityViewController` を UIKit から直接表示する。
///
/// SwiftUI の `.sheet` に包むと、スワイプで閉じたときに完了ハンドラと `onDismiss` の順序が
/// 定まらず「送ったか」を判定しにくい。直接表示し、完了ハンドラと「共有シートが閉じたこと」から
/// `ShareSheetCompletionTracker` で判定する。
/// （`UICloudSharingController` は保存済みの共有を渡すと完了コールバックが来なかったため使わない。）
@MainActor
enum ShareActivityPresenter {
    /// 共有シートが閉じてから、完了ハンドラを待つ時間。閉じた後に完了ハンドラが呼ばれることがあるため。
    static let resultGracePeriod: Duration = .seconds(2)

    /// - Parameter completion: 結果を知らせる。通常は 1 回だけ呼ぶ。ただし `.unknown` を知らせた後に
    ///   送信完了が届いた場合は、続けて `.sent` で呼ぶ（それ以外の 2 回目は無い）。
    /// - Returns: 表示できなかった（表示元の画面が無い）ら false。このとき `completion` は呼ばない。
    @discardableResult
    static func present(_ content: ShareActivityContent,
                        completion: @escaping (ShareSheetOutcome) -> Void) -> Bool {
        guard let presenter = topViewController() else { return false }

        let controller: DismissObservingActivityViewController
        switch content {
        case .url(let url):
            controller = DismissObservingActivityViewController(activityItems: [url], applicationActivities: nil)
        case .cloudKitInvite(let share, let container):
            let provider = NSItemProvider()
            provider.registerCKShare(share, container: container,
                                     allowedSharingOptions: CKShareService.allowedSharingOptions)
            let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
            // 共有シートの見出し。依頼の内容は出さない（CKShare の題名と同じ固定の文言）。
            let title = String(localized: "geomemo の依頼")
            configuration.metadataProvider = { @Sendable key in
                switch key {
                case .title:
                    return title
                case .linkPresentationMetadata:
                    let metadata = LPLinkMetadata()
                    metadata.title = title
                    return metadata
                default:
                    return nil
                }
            }
            controller = DismissObservingActivityViewController(activityItemsConfiguration: configuration)
        }

        let state = TrackerBox()
        // UIKit が main で呼ぶ。閉じたとき（スワイプを含む）は activityType == nil, completed == false。
        // 作成画面をキャンセルしたとき（共有シートは開いたまま）は activityType != nil, completed == false。
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            if let outcome = state.tracker.record(activityType: activityType?.rawValue, completed: completed) {
                completion(outcome)
            }
        }
        controller.onDismiss = {
            // 閉じた直後に完了ハンドラが呼ばれることがあるので、少し待ってから決める
            Task {
                try? await Task.sleep(for: resultGracePeriod)
                if let outcome = state.tracker.sheetDismissedWithoutResult() {
                    completion(outcome)
                }
            }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// 完了ハンドラと閉じたときの処理で共有する判定の状態
private final class TrackerBox {
    var tracker = ShareSheetCompletionTracker()
}

/// 閉じられたこと（`viewDidDisappear` かつ `isBeingDismissed`）を知らせる共有シート。
/// 作成画面（メッセージ等）を上に重ねたときは閉じたことにしない。
private final class DismissObservingActivityViewController: UIActivityViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let handler = onDismiss
            onDismiss = nil
            handler?()
        }
    }
}
