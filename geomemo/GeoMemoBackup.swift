import Foundation
import SwiftData

// MARK: - Backup Codable Model

struct BackupMemo: Codable {
    var id: UUID
    var title: String
    var note: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var locationName: String
    var imageData: Data?
    var notifyOnEntry: Bool
    var notifyOnExit: Bool
    var createdAt: Date
    var deadline: Date?
    var timeWindowStart: Int?
    var timeWindowEnd: Int?
    var activeDays: [Int]?
    var colorIndex: Int
    var isFavorite: Bool
    var isDone: Bool
    var exitDelayMinutes: Int?
    var isRouteTrigger: Bool
    var waypointData: Data?
    var tags: [Int]
    var customTags: [String]

    init(from memo: GeoMemo) {
        id               = memo.id
        title            = memo.title
        note             = memo.note
        latitude         = memo.latitude
        longitude        = memo.longitude
        radius           = memo.radius
        locationName     = memo.locationName
        imageData        = memo.imageData
        notifyOnEntry    = memo.notifyOnEntry
        notifyOnExit     = memo.notifyOnExit
        createdAt        = memo.createdAt
        deadline         = memo.deadline
        timeWindowStart  = memo.timeWindowStart
        timeWindowEnd    = memo.timeWindowEnd
        activeDays       = memo.activeDays
        colorIndex       = memo.colorIndex
        isFavorite       = memo.isFavorite
        isDone           = memo.isDone
        exitDelayMinutes = memo.exitDelayMinutes
        isRouteTrigger   = memo.isRouteTrigger
        waypointData     = memo.waypointData
        tags             = memo.tags
        customTags       = memo.customTags
    }

    /// BackupMemo → GeoMemo（id を保持）
    func toGeoMemo() -> GeoMemo {
        let memo = GeoMemo(
            title:            title,
            note:             note,
            latitude:         latitude,
            longitude:        longitude,
            radius:           radius,
            locationName:     locationName,
            imageData:        imageData,
            notifyOnEntry:    notifyOnEntry,
            notifyOnExit:     notifyOnExit,
            exitDelayMinutes: exitDelayMinutes,
            createdAt:        createdAt,
            deadline:         deadline,
            timeWindowStart:  timeWindowStart,
            timeWindowEnd:    timeWindowEnd,
            activeDays:       activeDays,
            colorIndex:       colorIndex,
            isFavorite:       isFavorite,
            isRouteTrigger:   isRouteTrigger,
            waypointData:     waypointData,
            tags:             tags,
            customTags:       customTags
        )
        memo.id     = id
        memo.isDone = isDone
        return memo
    }
}

// MARK: - Backup File Container

struct GeoMemoBackupFile: Codable {
    var version:    Int    = 1
    var exportedAt: Date   = Date()
    var memos:      [BackupMemo]
}

// MARK: - Import Result

struct GeoMemoImportResult {
    var added:    Int
    var skipped:  Int
    var total:    Int
}

// MARK: - Import Helper

enum GeoMemoImporter {

    /// JSON → GeoMemo をマージ挿入（同一 UUID は重複挿入しない）
    static func importData(
        from data: Data,
        into context: ModelContext
    ) throws -> GeoMemoImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(GeoMemoBackupFile.self, from: data)

        let existing = try context.fetch(FetchDescriptor<GeoMemo>())
        let existingIDs = Set(existing.map { $0.id })

        var added = 0
        for backup in file.memos {
            guard !existingIDs.contains(backup.id) else { continue }
            context.insert(backup.toGeoMemo())
            added += 1
        }

        return GeoMemoImportResult(
            added:   added,
            skipped: file.memos.count - added,
            total:   file.memos.count
        )
    }
}
