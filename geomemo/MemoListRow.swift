import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// メモ一覧の行。ContentView.swift から分離。

// MARK: - Memo List Row
struct MemoListRow: View {
    let memo: GeoMemo
    let userLocation: CLLocationCoordinate2D?
    
    @State private var mapSnapshot: UIImage?
    
    var body: some View {
        HStack(spacing: 12) {
            // Map Thumbnail
            Group {
                if let snapshot = mapSnapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Brand.primaryText.opacity(0.05))
                        .overlay(
                            ProgressView()
                                .tint(Brand.primaryText.opacity(0.3))
                        )
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Title
                HStack(spacing: 6) {
                    if memo.colorIndex != 0 {
                        Circle()
                            .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                            .frame(width: 8, height: 8)
                    }
                    if memo.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(Color(hex: "E5484D"))
                            .accessibilityLabel("Favorite")
                    }
                    Text(memo.displayTitle)
                        .font(.body.weight(memo.isUntitled ? .regular : .bold))
                        .foregroundColor(memo.isUntitled ? Brand.tertiaryText : (memo.isDone ? Brand.secondaryText : Brand.primaryText))
                        .italic(memo.isUntitled)
                        .strikethrough(memo.isDone, color: Brand.primaryText.opacity(0.4))
                        .lineLimit(1)
                }
                
                // Note
                if !memo.note.isEmpty {
                    Text(memo.note)
                        .font(.subheadline)
                        .foregroundColor(Brand.primaryText.opacity(0.6))
                        .lineLimit(1)
                }
                
                // Location Info
                HStack(spacing: 4) {
                    Text(locationText)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Brand.secondaryText)
                        .textCase(.uppercase)
                    
                    if let distanceText {
                        Text("•")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Brand.secondaryText)
                        
                        Text(distanceText)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Brand.secondaryText)
                    }
                }
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
        .onAppear {
            generateMapSnapshot()
        }
    }
    
    private var locationText: String {
        if memo.locationName.isEmpty || memo.locationName == "LOCATION" {
            return String(localized: "Not fetched")
        }
        return memo.locationName
    }
    
    private var distanceText: String? {
        guard let userLocation = userLocation else {
            return nil
        }
        
        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let memoCLLocation = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
        let meters = userCLLocation.distance(from: memoCLLocation)
        
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000)
        }
    }
    
    private func generateMapSnapshot() {
        Task {
            let image = await MapSnapshotCache.shared.snapshot(
                latitude: memo.latitude,
                longitude: memo.longitude,
                colorIndex: memo.colorIndex,
                mapStyleRaw: 0,
                size: CGSize(width: 120, height: 120)
            )
            await MainActor.run {
                mapSnapshot = image
            }
        }
    }
}
