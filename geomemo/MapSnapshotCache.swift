import MapKit
import UIKit

actor MapSnapshotCache {
    static let shared = MapSnapshotCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 50
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
            let image = renderer.image { context in
                snapshot.image.draw(at: .zero)

                // Draw pin at center
                let point = snapshot.point(for: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                let pinSize: CGFloat = 12
                let pinRect = CGRect(
                    x: point.x - pinSize / 2,
                    y: point.y - pinSize,
                    width: pinSize,
                    height: pinSize
                )
                let colors: [UIColor] = [
                    UIColor(red: 0.24, green: 0.23, blue: 0.95, alpha: 1), // blue
                    UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1), // red
                    UIColor(red: 0.90, green: 0.63, blue: 0.00, alpha: 1), // amber
                    UIColor(red: 0.19, green: 0.64, blue: 0.42, alpha: 1), // green
                    UIColor(red: 0.56, green: 0.31, blue: 0.78, alpha: 1), // purple
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

            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    func invalidate() {
        cache.removeAllObjects()
    }
}
