import SwiftUI
import MapKit

/// 受信した依頼 (SharedMemo) の詳細。場所・範囲・依頼者・期限を表示する。
/// 受信側は依頼元の GeoMemo を持たないため、SharedMemo の内容だけで構成する。
struct ReceivedSharedMemoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let shared: SharedMemo

    private var coordinate: CLLocationCoordinate2D { shared.memoCoordinate }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: max(shared.memoRadius * 6, 600),
                        longitudinalMeters: max(shared.memoRadius * 6, 600)
                    ))) {
                        MapCircle(center: coordinate, radius: shared.memoRadius)
                            .foregroundStyle(Brand.blue.opacity(0.15))
                            .stroke(Brand.blue, lineWidth: 1.5)
                        Marker(shared.memoLocationName, coordinate: coordinate)
                            .tint(Brand.blue)
                    }
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(String(localized: "依頼の場所の地図"))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                        Text(shared.memoLocationName)
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                    }

                    VStack(spacing: 0) {
                        infoRow(String(localized: "依頼者"), shared.requesterName)
                        infoRow(String(localized: "範囲"), "\(Int(shared.memoRadius))m")
                        if let deadline = shared.memoDeadline {
                            infoRow(String(localized: "期限"),
                                    deadline.formatted(date: .abbreviated, time: .shortened))
                        }
                        infoRow(String(localized: "状態"), statusText)
                    }
                    .background(Brand.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.background)
            .navigationTitle(String(localized: "受信した依頼"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        switch shared.status {
        case .active:    return String(localized: "到着待ち")
        case .fired:     return String(localized: "到着済み")
        case .completed: return String(localized: "完了")
        case .cancelled: return String(localized: "取り消し")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension SharedMemo {
    var memoCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: memoLatitude, longitude: memoLongitude)
    }
}
