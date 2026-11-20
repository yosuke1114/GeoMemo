import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// 地図表示の補助型（方位コーン・ピン/クラスタ・シート種別・クラスタリング）。ContentView.swift から分離。

// MARK: - Heading Cone Shape

nonisolated struct HeadingCone: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 先端（下）= ドット位置、広がりは上（進行方向）
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        // 上辺を弧にして扇形らしく
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.25)
        )
        path.closeSubpath()
        return path
    }
}

/// 現在地の向きを示す扇形。degrees が負（方位が未取得）のときは何も描かない。
struct HeadingConeIndicator: View {
    let degrees: Double

    var body: some View {
        if degrees >= 0 {
            HeadingCone()
                .fill(
                    LinearGradient(
                        colors: [Brand.blue.opacity(0.5), Brand.blue.opacity(0.0)],
                        startPoint: UnitPoint(x: 0.5, y: 0.5),
                        endPoint: .top
                    )
                )
                .frame(width: 36, height: 56)
                .padding(.bottom, 56)
                .rotationEffect(.degrees(degrees))
        }
    }
}

// MARK: - Map Item (single pin or cluster)
enum MapItem: Identifiable {
    case single(GeoMemo)
    case cluster(id: String, coordinate: CLLocationCoordinate2D, memos: [GeoMemo])

    var id: String {
        switch self {
        case .single(let memo):
            return memo.id.uuidString
        case .cluster(let id, _, _):
            return id
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .single(let memo):
            return memo.coordinate
        case .cluster(_, let coordinate, _):
            return coordinate
        }
    }
}

// MARK: - Active Sheet
enum ActiveSheet: Identifiable {
    case memoEditor(coordinate: CLLocationCoordinate2D)
    case clusterList([GeoMemo])

    var id: String {
        switch self {
        case .memoEditor:
            return "editor"
        case .clusterList(let memos):
            return "cluster-\(memos.map(\.id.uuidString).joined())"
        }
    }
}

// MARK: - Clustering Function
func clusterMemos(_ memos: [GeoMemo], in region: MKCoordinateRegion) -> [MapItem] {
    let cellWidth = region.span.longitudeDelta / 8.0
    let cellHeight = region.span.latitudeDelta / 8.0

    guard cellWidth > 0, cellHeight > 0 else {
        return memos.map { .single($0) }
    }

    var grid: [String: [GeoMemo]] = [:]
    for memo in memos {
        let col = Int(floor(memo.longitude / cellWidth))
        let row = Int(floor(memo.latitude / cellHeight))
        let key = "\(col),\(row)"
        grid[key, default: []].append(memo)
    }

    return grid.map { key, cellMemos in
        if cellMemos.count == 1 {
            return .single(cellMemos[0])
        } else {
            let count = Double(cellMemos.count)
            let avgLat = cellMemos.reduce(0.0) { $0 + $1.latitude } / count
            let avgLon = cellMemos.reduce(0.0) { $0 + $1.longitude } / count
            // グリッドキーをそのまま ID に流用 → sorted().joined() 不要で O(1)
            return .cluster(
                id: "cluster-\(key)",
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                memos: cellMemos
            )
        }
    }
}
