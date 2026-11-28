import Foundation

/// DownloadCoordinator 音频文件后缀推断、空间不足识别与文件头校验辅助（拆分保持单文件 ≤ 384 行）
extension DownloadCoordinator {
    static func inferredAudioExtension(url: URL, mimeType: String?) -> String {
        let lowerMime = mimeType?.lowercased() ?? ""
        if lowerMime.contains("mpeg") || lowerMime.contains("mp3") { return "mp3" }
        if lowerMime.contains("flac") { return "flac" }
        if lowerMime.contains("aac") { return "aac" }
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(ext) { return ext }
        return "m4a"
    }

    static func extractExtension(fromStagedURL url: URL) -> String? {
        let withoutStaged = url.deletingPathExtension()
        let candidate = withoutStaged.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(candidate) {
            return candidate
        }
        return nil
    }

    static func isOutOfSpaceError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpaceError(underlying)
        }
        return false
    }

    static func validateDownloadedAudioFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size >= 1024,
              let fh = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 64), !head.isEmpty else {
            return false
        }
        let prefix = String(decoding: head.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if prefix.hasPrefix("<!doctype")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("#extm3u")
            || prefix.hasPrefix("{")
            || prefix.hasPrefix("[")
            || prefix.hasPrefix("error")
            || prefix.hasPrefix("403 ")
            || prefix.hasPrefix("404 ") {
            return false
        }
        return true
    }

}
