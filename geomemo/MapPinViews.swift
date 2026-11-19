import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// 地図上のピン・吹き出し・スナップショット・クラスタ一覧・検索補完。ContentView.swift から分離。

// MARK: - Single Pin View
struct SinglePinView: View {
    var color: Color = Brand.blue
    var isRoute: Bool = false

    var body: some View {
        if isRoute {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Brand.background, lineWidth: 2)
                    )
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Brand.background)
            }
        } else {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Brand.background, lineWidth: 2)
                )
        }
    }
}

// MARK: - Cluster Pin View
struct ClusterPinView: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.blue)
                .frame(width: 32, height: 32)
            Text("\(count)")
                .font(.footnote.weight(.bold))
                .foregroundColor(.white)
        }
        .overlay(
            Circle()
                .stroke(Brand.background, lineWidth: 2)
                .frame(width: 32, height: 32)
        )
    }
}

// MARK: - Callout View
struct CalloutView: View {
    let memo: GeoMemo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memo.displayTitle)
                        .font(.subheadline.weight(memo.isUntitled ? .regular : .bold))
                        .foregroundColor(memo.isUntitled ? Brand.tertiaryText : Brand.primaryText)
                        .italic(memo.isUntitled)
                        .lineLimit(1)
                    Text(memo.locationName.isEmpty ? String(localized: "Unknown Location") : memo.locationName)
                        .font(.caption)
                        .foregroundColor(Brand.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image("ph-caret-right-bold")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundColor(Brand.blue)
            }
            .padding(12)
            .frame(width: 220)
            .background(Brand.surface)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Map Snapshot View
struct MapSnapshotView: View {
    let coordinate: CLLocationCoordinate2D
    let colorIndex: Int
    @State private var snapshot: UIImage?

    var body: some View {
        Group {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Brand.primaryText.opacity(0.05))
                    .overlay(ProgressView().tint(Brand.primaryText.opacity(0.3)))
            }
        }
        .task {
            guard snapshot == nil else { return }
            snapshot = await MapSnapshotCache.shared.snapshot(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                colorIndex: colorIndex,
                mapStyleRaw: 0
            )
        }
    }
}

// MARK: - Cluster List Sheet
struct ClusterListSheet: View {
    let memos: [GeoMemo]
    let onSelectMemo: (GeoMemo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2)
                .fill(Brand.separator)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Header
            HStack {
                Text("\(memos.count) memos")
                    .font(.body.weight(.bold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Memo list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(memos) { memo in
                        Button {
                            onSelectMemo(memo)
                        } label: {
                            HStack(spacing: 12) {
                                MapSnapshotView(coordinate: memo.coordinate, colorIndex: memo.colorIndex)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(memo.displayTitle)
                                        .font(.subheadline.weight(memo.isUntitled ? .regular : .semibold))
                                        .foregroundColor(memo.isUntitled ? Brand.tertiaryText : Brand.primaryText)
                                        .italic(memo.isUntitled)
                                        .lineLimit(1)
                                    Text(memo.locationName.isEmpty ? String(localized: "Unknown Location") : memo.locationName)
                                        .font(.caption)
                                        .foregroundColor(Brand.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image("ph-caret-right-bold")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                    .foregroundColor(Brand.secondaryText)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 80)
                    }
                }
            }
        }
        .background(Brand.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - Search Completer Helper
@Observable
// MKLocalSearchCompleter はデリゲートをメインスレッドで呼ぶので、適合をメインアクターに隔離する
class SearchCompleterHelper: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func search(_ query: String) {
        guard !query.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func clear() {
        results = []
        completer.queryFragment = ""
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}
