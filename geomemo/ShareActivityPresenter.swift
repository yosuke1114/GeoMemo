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
/// 定まらず「送ったか」を判定しにくい。直接表示して `completionWithItemsHandler` だけで判定する。
/// （`UICloudSharingController` は保存済みの共有を渡すと完了コールバックが来なかったため使わない。）
@MainActor
enum ShareActivityPresenter {
    /// - Parameter completion: 送信（コピー等を含む）したら true、キャンセルしたら false。1 回だけ呼ぶ。
    /// - Returns: 表示できなかった（表示元の画面が無い）ら false。このとき `completion` は呼ばない。
    @discardableResult
    static func present(_ content: ShareActivityContent, completion: @escaping (Bool) -> Void) -> Bool {
        guard let presenter = topViewController() else { return false }

        let controller: UIActivityViewController
        switch content {
        case .url(let url):
            controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
            controller = UIActivityViewController(activityItemsConfiguration: configuration)
        }

        var didComplete = false
        // UIKit が main で呼ぶ（スワイプで閉じたときも completed == false で呼ばれる）
        controller.completionWithItemsHandler = { _, completed, _, _ in
            guard !didComplete else { return }
            didComplete = true
            completion(completed)
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
