import UIKit

/// デコード済み UIImage のメモリキャッシュ。
/// メモリ不足時に OS が自動解放する。
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 30 * 1024 * 1024 // 30MB
    }

    func image(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func store(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
    }

    func remove(forKey key: NSString) {
        cache.removeObject(forKey: key)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
