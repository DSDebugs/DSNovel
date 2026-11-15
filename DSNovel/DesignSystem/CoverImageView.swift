import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// 高性能封面图片管线：内存 NSCache（上限 64 MB）+ 磁盘缓存（上限 200 MB）+ ImageIO 按目标像素尺寸降采样
actor CoverImagePipeline {
    static let shared = CoverImagePipeline()

    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
        return cache
    }()

    private let diskDirectory: URL
    private let maxDiskBytes: Int = 200 * 1024 * 1024 // 200 MB

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.diskDirectory = caches.appendingPathComponent("CoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    func cachedImage(for key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    func loadImage(url: String, headers: [String: String] = [:], targetPointSize: CGSize, scale: CGFloat = 3.0) async -> UIImage? {
        guard !url.isEmpty, let requestURL = URL(string: url) else { return nil }
        let pixelMax = Int(max(targetPointSize.width, targetPointSize.height, 80) * scale)
        let cacheKey = "\(sha256Hex(url))_\(pixelMax)"

        if let mem = memoryCache.object(forKey: cacheKey as NSString) {
            return mem
        }

        let diskURL = diskDirectory.appendingPathComponent(sha256Hex(url) + ".img")
        if FileManager.default.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL),
           let downsampled = Self.downsample(data: data, maxDimensionInPixels: pixelMax) {
            let cost = Int(downsampled.size.width * downsampled.size.height * 4)
            memoryCache.setObject(downsampled, forKey: cacheKey as NSString, cost: cost)
            return downsampled
        }

        if Task.isCancelled { return nil }

        var request = URLRequest(url: requestURL, timeoutInterval: 12)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent"
            )
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return nil
            }
            try? data.write(to: diskURL, options: .atomic)
            if let downsampled = Self.downsample(data: data, maxDimensionInPixels: pixelMax) {
                let cost = Int(downsampled.size.width * downsampled.size.height * 4)
                memoryCache.setObject(downsampled, forKey: cacheKey as NSString, cost: cost)
                return downsampled
            }
        } catch {
            return nil
        }
        return nil
    }

    nonisolated static func downsample(data: Data, maxDimensionInPixels: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxDimensionInPixels)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func diskUsageBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for u in urls {
            if let sz = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    private func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 纯色占位 + 降采样封面视图（不使用模糊占位以节省 GPU）
struct CoverImageView: View, Equatable {
    let url: String
    let title: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var headers: [String: String] = [:]
    var onImageLoaded: ((UIImage) -> Void)? = nil

    static func == (lhs: CoverImageView, rhs: CoverImageView) -> Bool {
        lhs.url == rhs.url && lhs.title == rhs.title && lhs.width == rhs.width && lhs.height == rhs.height
    }

    @State private var loadedImage: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DSColor.placeholder(for: title.isEmpty ? url : title))

            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "headphones")
                        .font(.system(size: min(width, height) * 0.28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(String(title.prefix(4)))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityLabel(Text(title.isEmpty ? "书籍封面" : "\(title)封面"))
        .task(id: url) {
            guard !url.isEmpty else {
                loadedImage = nil
                return
            }
            if let img = await CoverImagePipeline.shared.loadImage(
                url: url,
                headers: headers,
                targetPointSize: CGSize(width: width, height: height)
            ) {
                loadedImage = img
                onImageLoaded?(img)
            }
        }
    }
}
