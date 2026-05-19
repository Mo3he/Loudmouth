import UIKit

// MARK: - ArtworkCache
/// Multi-resolution artwork cache backed by disk.
/// Never modifies original audio files — artwork is stored separately.
///
/// Resolutions:
///   thumbnail  —  64 px  (queue rows, small widgets)
///   grid       — 300 px  (library grid, Now Playing mini-player)
///   full       — 1000 px (Now Playing full-bleed)
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let gridCache      = NSCache<NSString, UIImage>()
    private let fullCache      = NSCache<NSString, UIImage>()

    private let diskURL: URL

    private init() {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.loudmouth")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskURL = base.appendingPathComponent("ArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)

        thumbnailCache.countLimit = 500
        gridCache.countLimit      = 200
        fullCache.countLimit      = 30
    }

    // MARK: - Read
    func thumbnailImage(forKey key: String) -> UIImage? { image(key: key, size: .thumbnail) }
    func gridImage(forKey key: String)      -> UIImage? { image(key: key, size: .grid) }
    func fullImage(forKey key: String)      -> UIImage? { image(key: key, size: .full) }

    private func image(key: String, size: ArtSize) -> UIImage? {
        let nsKey = (key + size.suffix) as NSString
        if let cached = cache(for: size).object(forKey: nsKey) { return cached }
        let url = diskURL.appendingPathComponent(nsKey as String).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        cache(for: size).setObject(img, forKey: nsKey)
        return img
    }

    // MARK: - Write
    /// Store raw artwork data (any size) for a given cache key.
    /// Generates all three resolutions and writes them to disk.
    func store(imageData: Data, forKey key: String) {
        guard let source = UIImage(data: imageData) else { return }
        for size in ArtSize.allCases {
            let resized = resize(source, to: size.targetPx)
            let nsKey = (key + size.suffix) as NSString
            cache(for: size).setObject(resized, forKey: nsKey)
            let url = diskURL.appendingPathComponent(nsKey as String).appendingPathExtension("jpg")
            if let jpg = resized.jpegData(compressionQuality: 0.92) {
                try? jpg.write(to: url, options: .atomic)
            }
        }
    }

    func hasArtwork(forKey key: String) -> Bool {
        let url = diskURL
            .appendingPathComponent(key + ArtSize.grid.suffix)
            .appendingPathExtension("jpg")
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Helpers
    private func cache(for size: ArtSize) -> NSCache<NSString, UIImage> {
        switch size {
        case .thumbnail: thumbnailCache
        case .grid:      gridCache
        case .full:      fullCache
        }
    }

    private func resize(_ image: UIImage, to px: CGFloat) -> UIImage {
        let size = CGSize(width: px, height: px)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - ArtSize
enum ArtSize: CaseIterable {
    case thumbnail, grid, full

    var targetPx: CGFloat {
        switch self {
        case .thumbnail: 64
        case .grid:      300
        case .full:      1000
        }
    }

    var suffix: String {
        switch self {
        case .thumbnail: "_thumb"
        case .grid:      "_grid"
        case .full:      "_full"
        }
    }
}
