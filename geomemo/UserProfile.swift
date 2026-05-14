import Foundation
import SwiftData

// MARK: - UserProfile Model

@Model final class UserProfile {
    var id: UUID = UUID()
    var displayName: String = ""
    var iCloudRecordID: String = ""  // CKRecord.ID.recordName
    var createdAt: Date = Date()

    init(displayName: String, iCloudRecordID: String) {
        self.displayName = displayName
        self.iCloudRecordID = iCloudRecordID
    }
}
