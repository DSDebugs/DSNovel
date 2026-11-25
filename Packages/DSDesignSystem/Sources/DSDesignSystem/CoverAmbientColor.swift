import SwiftUI
import UIKit

/// 线程安全封面环境色缓存（Swift 6 严格并发零告警）
private final class CoverAmbientColorCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CoverAmbientColor.HSBResult] = [:]
    private let maxEntries = 256

    func value(for key: String) -> CoverAmbientColor.HSBResult? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func store(_ value: CoverAmbientColor.HSBResult, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= maxEntries, storage[key] == nil {
            storage.removeAll(keepingCapacity: true)
        }
        storage[key] = value
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// 封面主色提取器（1:1 复刻 v2.8：32×32 RGB 采样 + 12 色相桶众数 + 饱和度/明度钳制 + 线程安全缓存）
public enum CoverAmbientColor {
    public struct HSBResult: Equatable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public var brightness: Double {
            max(r, max(g, b))
        }
    }

    private static let cache = CoverAmbientColorCache()
    private static let fallbackRGB = HSBResult(r: 0.24, g: 0.14, b: 0.10)

    public static func clearCache() {
        cache.removeAll()
    }

    public static func extract(from image: UIImage, cacheKey: String? = nil) -> HSBResult {
        if let key = cacheKey, !key.isEmpty, let cached = cache.value(for: key) {
            return cached
        }
        guard let cgImage = image.cgImage else {
            return fallbackRGB
        }

        let sampleSide = 32
        var raw = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &raw,
            width: sampleSide,
            height: sampleSide,
            bitsPerComponent: 8,
            bytesPerRow: sampleSide * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return fallbackRGB
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))

        var buckets = Array(repeating: (count: 0, rSum: 0.0, gSum: 0.0, bSum: 0.0), count: 12)
        var grayCount = 0

        for idx in stride(from: 0, to: raw.count, by: 4) {
            let r = Double(raw[idx]) / 255.0
            let g = Double(raw[idx + 1]) / 255.0
            let b = Double(raw[idx + 2]) / 255.0
            let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
            if s < 0.12 || v < 0.08 || v > 0.96 {
                grayCount += 1
            } else {
                let bucket = min(11, max(0, Int(h * 12.0)))
                buckets[bucket].count += 1
                buckets[bucket].rSum += r
                buckets[bucket].gSum += g
                buckets[bucket].bSum += b
            }
        }

        let bestBucket = buckets.max(by: { $0.count < $1.count })
        let baseR: Double
        let baseG: Double
        let baseB: Double
        if let winner = bestBucket, winner.count > 0 {
            baseR = winner.rSum / Double(winner.count)
            baseG = winner.gSum / Double(winner.count)
            baseB = winner.bSum / Double(winner.count)
        } else if grayCount > 0 {
            return fallbackRGB
        } else {
            return fallbackRGB
        }

        let (h, s, v) = rgbToHSV(r: baseR, g: baseG, b: baseB)
        let dampedS = min(max(s * 0.65, 0.22), 0.58)
        let dampedV = min(max(v * 0.42, 0.16), 0.36)
        let finalUIColor = UIColor(
            hue: CGFloat(h),
            saturation: CGFloat(dampedS),
            brightness: CGFloat(dampedV),
            alpha: 1.0
        )

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        finalUIColor.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        let result = HSBResult(r: Double(fr), g: Double(fg), b: Double(fb))
        if let key = cacheKey, !key.isEmpty {
            cache.store(result, for: key)
        }
        return result
    }

    public static func color(from image: UIImage, cacheKey: String? = nil) -> Color {
        let res = extract(from: image, cacheKey: cacheKey)
        return Color(red: res.r, green: res.g, blue: res.b)
    }

    @inline(__always)
    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal
        let v = maxVal
        let s = maxVal > 0.0 ? (delta / maxVal) : 0.0
        var h = 0.0
        if delta > 0.0 {
            if maxVal == r {
                h = (g - b) / delta
                if h < 0.0 { h += 6.0 }
            } else if maxVal == g {
                h = ((b - r) / delta) + 2.0
            } else {
                h = ((r - g) / delta) + 4.0
            }
            h /= 6.0
        }
        return (h, s, v)
    }
}
