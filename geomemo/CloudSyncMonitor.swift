import Foundation
import CoreData

// MARK: - CloudSyncMonitor

/// iCloud (CloudKit) の同期状態を監視する Observable クラス
/// SwiftData は内部で NSPersistentCloudKitContainer を使用しているため
/// eventChangedNotification を通じてイベントを受け取れる
@Observable
final class CloudSyncMonitor {

    // MARK: - State

    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var state: SyncState = .idle
    private(set) var lastSyncDate: Date?

    // MARK: - Init

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            self?.handle(event: event)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Event Handling

    private func handle(event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            // 同期中
            state = .syncing
        } else if let error = event.error {
            state = .failed(error.localizedDescription)
        } else {
            state = .idle
            lastSyncDate = event.endDate
        }
    }
}
