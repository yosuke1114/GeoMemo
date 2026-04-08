import ActivityKit
import SwiftData
import Foundation

@MainActor
class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<GeoMemoActivityAttributes>?

    private static let appGroupID = "group.com.yokuro.geomemo"

    // MARK: - Start Monitoring

    /// Start a Live Activity showing that GeoMemo is monitoring nearby memos.
    /// Call this when the app launches and has active memos.
    func startMonitoring(count: Int) {
        guard count > 0 else {
            endActivity()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // If already running, just update the count
        if let activity = currentActivity {
            let state = GeoMemoActivityAttributes.ContentState(
                isTriggered: false,
                memoTitle: "",
                memoLocation: String(localized: "Monitoring \(count) memos"),
                memoColorIndex: 0,
                triggeredAt: nil
            )
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
            return
        }

        let attributes = GeoMemoActivityAttributes(monitoredCount: count)
        let state = GeoMemoActivityAttributes.ContentState(
            isTriggered: false,
            memoTitle: "",
            memoLocation: String(localized: "Monitoring \(count) memos"),
            memoColorIndex: 0,
            triggeredAt: nil
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            currentActivity = activity
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    // MARK: - Trigger Memo

    /// Update the Live Activity to show a triggered memo.
    /// Can be called from the background when a geofence event fires.
    nonisolated func triggerMemo(id: String) {
        guard let memo = lookupMemo(id: id) else { return }

        Task { @MainActor in
            guard let activity = currentActivity else { return }

            let state = GeoMemoActivityAttributes.ContentState(
                isTriggered: true,
                memoTitle: memo.title,
                memoLocation: memo.locationName,
                memoColorIndex: memo.colorIndex,
                triggeredAt: Date()
            )

            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 30)),
                alertConfiguration: AlertConfiguration(
                    title: "\(memo.title)",
                    body: "\(memo.locationName)",
                    sound: .default
                )
            )
        }
    }

    // MARK: - End Activity

    func endActivity() {
        guard let activity = currentActivity else { return }
        let state = GeoMemoActivityAttributes.ContentState(
            isTriggered: false,
            memoTitle: "",
            memoLocation: "",
            memoColorIndex: 0,
            triggeredAt: nil
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    // MARK: - Memo Lookup

    /// Look up a memo from the shared SwiftData store by its UUID string.
    /// This works independently of SwiftUI views, so it can be called from the background.
    nonisolated private func lookupMemo(id: String) -> (title: String, locationName: String, colorIndex: Int)? {
        let schema = Schema([GeoMemo.self])
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent("geomemo.store") else { return nil }

        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else { return nil }

        let context = ModelContext(container)
        guard let memos = try? context.fetch(FetchDescriptor<GeoMemo>()) else { return nil }
        guard let memo = memos.first(where: { $0.id.uuidString == id }) else { return nil }

        return (title: memo.title, locationName: memo.locationName, colorIndex: memo.colorIndex)
    }
}
