import Foundation
import SwiftData

// MARK: - UserProfile Model

@Model final class UserProfile {
    var id: UUID = UUID()
    var displayName: String = ""
    var iCloudRecordID: String = ""  // CKRecord.ID.recordName
    var createdAt: Date = Date()

    init(
        displayName: String,
        iCloudRecordID: String,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.iCloudRecordID = iCloudRecordID
        self.createdAt = createdAt
    }
}
