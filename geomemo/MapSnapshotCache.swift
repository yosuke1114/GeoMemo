import MapKit
import UIKit

actor MapSnapshotCache {
    static let shared = MapSnapshotCache()

    private let cache = NSCache<NSString, UIImage>()
    /// 同一キーの進行中リクエストを共有し、重複生成を防ぐ
    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 20 * 1024 * 1024 // 20MB
    }

    func snapshot(
        latitude: Double,
        longitude: Double,
        colorIndex: Int,
        mapStyleRaw: Int,
        size: CGSize = CGSize(width: 112, height: 112)
    ) async -> UIImage? {
        let key = "\(latitude)_\(longitude)_\(mapStyleRaw)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        // 同じキーのリクエストが既に進行中なら結果を共有して待つ
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: 300,
                longitudinalMeters: 300
            )
            options.size = size
            options.scale = UITraitCollection.current.displayScale

            do {
                let snapshotter = MKMapSnapshotter(options: options)
                let snapshot = try await snapshotter.start()

                let renderer = UIGraphicsImageRenderer(size: options.size)
                let image = renderer.image { _ in
                    snapshot.image.draw(at: .zero)

                    let point = snapshot.point(for: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    let pinSize: CGFloat = 12
                    let pinRect = CGRect(
                        x: point.x - pinSize / 2,
                        y: point.y - pinSize,
                        width: pinSize,
                        height: pinSize
                    )
                    let colors: [UIColor] = [
                        UIColor(red: 0.24, green: 0.23, blue: 0.95, alpha: 1),
                        UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1),
                        UIColor(red: 0.90, green: 0.63, blue: 0.00, alpha: 1),
                        UIColor(red: 0.19, green: 0.64, blue: 0.42, alpha: 1),
                        UIColor(red: 0.56, green: 0.31, blue: 0.78, alpha: 1),
                        UIColor.gray
                    ]
                    let pinColor = colors[min(colorIndex, colors.count - 1)]
                    pinColor.setFill()
                    UIBezierPath(ovalIn: pinRect).fill()

                    UIColor.white.setStroke()
                    let strokePath = UIBezierPath(ovalIn: pinRect.insetBy(dx: 1, dy: 1))
                    strokePath.lineWidth = 1.5
                    strokePath.stroke()
                }

                await MapSnapshotCache.shared.store(image, forKey: key)
                return image
            } catch {
                return nil
            }
        }

        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    private func store(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
    }

    func invalidate() {
        cache.removeAllObjects()
    }
}
