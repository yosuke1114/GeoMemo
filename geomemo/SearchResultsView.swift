import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// 検索結果。ContentView.swift から分離。

// MARK: - Search Results View
struct SearchResultsView: View {
    let memoResults: [GeoMemo]
    let placeResults: [MKLocalSearchCompletion]
    let onMemoSelected: (GeoMemo) -> Void
    let onPlaceSelected: (MKLocalSearchCompletion) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !memoResults.isEmpty {
                    SectionHeader(title: String(localized: "SAVED MEMOS"))
                    ForEach(memoResults) { memo in
                        MemoResultRow(memo: memo)
                            .onTapGesture { onMemoSelected(memo) }
                        Divider().padding(.leading, 52)
                    }
                }

                if !placeResults.isEmpty {
                    SectionHeader(title: String(localized: "PLACES"))
                    ForEach(placeResults, id: \.self) { completion in
                        PlaceResultRow(completion: completion)
                            .onTapGesture { onPlaceSelected(completion) }
                        Divider().padding(.leading, 52)
                    }
                }

                if memoResults.isEmpty && placeResults.isEmpty {
                    Text("No results found")
                        .font(.subheadline)
                        .foregroundColor(Brand.secondaryText)
                        .padding(24)
                }
            }
        }
        .background(Brand.background)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundColor(Brand.secondaryText)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

struct MemoResultRow: View {
    let memo: GeoMemo
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Brand.blue.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image("ph-map-pin-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(memo.displayTitle)
                    .font(.subheadline.weight(memo.isUntitled ? .regular : .semibold))
                    .foregroundColor(memo.isUntitled ? Brand.tertiaryText : Brand.primaryText)
                    .italic(memo.isUntitled)
                Text(memo.locationName)
                    .font(.caption)
                    .foregroundColor(Brand.secondaryText)
            }
            Spacer()
            Image("ph-caret-right-bold")
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundColor(Brand.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct PlaceResultRow: View {
    let completion: MKLocalSearchCompletion
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Brand.primaryText.opacity(0.08))
                    .frame(width: 36, height: 36)
                Image("ph-map-trifold-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.secondaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.primaryText)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.caption)
                        .foregroundColor(Brand.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image("ph-arrow-up-right-bold")
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundColor(Brand.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
