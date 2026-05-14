import SwiftUI
import CloudKit

/// `UICloudSharingController` を SwiftUI から利用するためのラッパー。
/// `.sheet(item:)` に渡せるよう `CKShare` を Identifiable な箱に包む。
struct ShareWrapper: Identifiable {
    let share: CKShare
    let container: CKContainer
    var id: String { share.recordID.recordName }
}

struct CloudSharingControllerSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onComplete: ((Bool) -> Void)? = nil  // true=完了, false=キャンセル

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onComplete: ((Bool) -> Void)?
        init(onComplete: ((Bool) -> Void)?) { self.onComplete = onComplete }

        func cloudSharingController(_ csc: UICloudSharingController,
                                     failedToSaveShareWithError error: Error) {
            print("[CKShare] failed to save share: \(error)")
            onComplete?(false)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onComplete?(true)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onComplete?(false)
        }
    }
}
