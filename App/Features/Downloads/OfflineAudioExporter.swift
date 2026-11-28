import DSCore
import Foundation

/// 离线音频导出输入项
struct OfflineAudioExportItem: Sendable, Equatable {
    let sourceURL: URL
    let chapterIndex: Int
    let chapterTitle: String
}

/// 离线音频导出暂存批次结果
struct OfflineAudioExportBatch: Sendable, Equatable {
    let sessionDir: URL
    let folderURL: URL
    let fileURLs: [URL]
    let exportedCount: Int
    let skippedCount: Int
}

/// 离线音频导出错误
enum OfflineAudioExportError: Error, LocalizedError, Equatable, Sendable {
    case noValidFiles
    case outOfSpace
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noValidFiles:
            return "所选章节的本地音频文件不存在或已损坏"
        case .outOfSpace:
            return "设备存储空间不足，无法准备导出文件"
        case .failed(let message):
            return message
        }
    }
}

/// 离线音频导出引擎（APFS CoW 零拷贝隔离 + Magic Bytes 真实格式嗅探 + 跨平台安全命名）
enum OfflineAudioExporter {
    static let stagingDirectoryName = "ExportStaging"
    static let shareSheetSoftLimit = 20
    private static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg"]

    static var defaultStagingRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    }

    /// 读取音频文件头前 12 字节嗅探真实编码格式，避免兜底后缀与实际格式不一致导致外部播放器无法识别
    static func detectAudioExtension(at url: URL) -> String {
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            if let data = try? fh.read(upToCount: 12), !data.isEmpty {
                let bytes = [UInt8](data)
                if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
                    return "mp3" // ID3
                }
                if bytes.count >= 2, bytes[0] == 0xFF,
                   (bytes[1] == 0xFB || bytes[1] == 0xF3 || bytes[1] == 0xF2) {
                    return "mp3" // MPEG frame sync
                }
                if bytes.count >= 8,
                   bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
                    return "m4a" // ISO BMFF ftyp
                }
                if bytes.count >= 4,
                   bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
                    return "flac" // fLaC
                }
                if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] == 0xF1 || bytes[1] == 0xF9) {
                    return "aac" // ADTS AAC
                }
                if bytes.count >= 4,
                   bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
                    return "wav" // RIFF
                }
                if bytes.count >= 4,
                   bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
                    return "ogg" // OggS
                }
            }
        }
        let ext = url.pathExtension.lowercased()
        if supportedExtensions.contains(ext) {
            return ext
        }
        return "m4a"
    }

    /// 跨平台安全清洗文件名组件（兼容 APFS / Windows / 车载 FAT32 / exFAT，按 UTF-8 字节安全截断）
    static func sanitizeComponent(_ raw: String, maxUTF8Bytes: Int = 180, fallback: String = "未命名") -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var cleanedScalars: [Character] = []
        cleanedScalars.reserveCapacity(raw.count)

        for ch in raw {
            if forbidden.contains(ch) || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                cleanedScalars.append(" ")
            } else {
                cleanedScalars.append(ch)
            }
        }

        let collapsed = String(cleanedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        guard !collapsed.isEmpty else { return fallback }

        let limit = Swift.max(16, maxUTF8Bytes)
        if collapsed.utf8.count <= limit {
            return collapsed
        }

        var truncated = ""
        var usedBytes = 0
        for ch in collapsed {
            let chBytes = String(ch).utf8.count
            if usedBytes + chBytes > limit { break }
            truncated.append(ch)
            usedBytes += chBytes
        }
        let final = truncated.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return final.isEmpty ? fallback : final
    }

    /// 生成 1-based 补零顺序文件名（单章分享可附带书名，文件夹批量导出省略重复书名）
    static func formattedFileStem(
        bookTitle: String,
        chapterIndex: Int,
        chapterTitle: String,
        padWidth: Int = 4,
        includeBookTitle: Bool = false
    ) -> String {
        let seq = Swift.max(1, chapterIndex + 1)
        let width = Swift.max(4, padWidth)
        let seqStr = String(format: "%0*d", width, seq)
        let stripped = BookTitleFormatter.stripBookPrefix(from: chapterTitle, bookTitle: bookTitle)
        let cleanChapter = sanitizeComponent(stripped, maxUTF8Bytes: 120, fallback: "第\(seq)章")

        if includeBookTitle {
            let cleanBook = sanitizeComponent(bookTitle, maxUTF8Bytes: 48, fallback: "")
            if !cleanBook.isEmpty {
                return sanitizeComponent("\(cleanBook)_\(seqStr)_\(cleanChapter)", maxUTF8Bytes: 180, fallback: "\(seqStr)_\(cleanChapter)")
            }
        }
        return sanitizeComponent("\(seqStr)_\(cleanChapter)", maxUTF8Bytes: 180, fallback: "\(seqStr)_第\(seq)章")
    }

    /// 大小写不敏感重名去重（兼容 APFS / FAT32 / exFAT）
    static func uniqueFileName(stem: String, ext: String, usedLowercasedNames: inout Set<String>) -> String {
        let safeExt = supportedExtensions.contains(ext.lowercased()) ? ext.lowercased() : "m4a"
        let base = "\(stem).\(safeExt)"
        if usedLowercasedNames.insert(base.lowercased()).inserted {
            return base
        }
        var suffix = 2
        while true {
            let candidate = "\(stem)_\(suffix).\(safeExt)"
            if usedLowercasedNames.insert(candidate.lowercased()).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    /// 准备导出暂存目录（强制正序 + 存在与非空校验 + APFS CoW copyItem 零拷贝隔离）
    static func prepareExport(
        bookTitle: String,
        items: [OfflineAudioExportItem],
        includeBookTitleInFileName: Bool,
        stagingRoot: URL? = nil
    ) throws -> OfflineAudioExportBatch {
        let fm = FileManager.default
        let root = stagingRoot ?? defaultStagingRootURL
        cleanupStaleStagingDirectories(in: root, maxAge: 3600)

        let sorted = items.sorted { lhs, rhs in
            if lhs.chapterIndex != rhs.chapterIndex {
                return lhs.chapterIndex < rhs.chapterIndex
            }
            return lhs.chapterTitle < rhs.chapterTitle
        }

        let maxSeq = Swift.max(1, (sorted.last?.chapterIndex ?? 0) + 1)
        let padWidth = Swift.max(4, String(maxSeq).count)

        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeBookFolder = sanitizeComponent(bookTitle, maxUTF8Bytes: 80, fallback: "离线音频")
        let folderURL = sessionDir.appendingPathComponent(safeBookFolder, isDirectory: true)

        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            if isOutOfSpaceError(error) { throw OfflineAudioExportError.outOfSpace }
            throw OfflineAudioExportError.failed("无法创建导出临时目录：\(error.localizedDescription)")
        }

        var usedNames = Set<String>()
        var exportedURLs: [URL] = []
        var skippedCount = 0

        for item in sorted {
            guard isValidNonEmptyFile(at: item.sourceURL, fm: fm) else {
                skippedCount += 1
                continue
            }
            let ext = detectAudioExtension(at: item.sourceURL)
            let stem = formattedFileStem(
                bookTitle: bookTitle,
                chapterIndex: item.chapterIndex,
                chapterTitle: item.chapterTitle,
                padWidth: padWidth,
                includeBookTitle: includeBookTitleInFileName
            )
            let fileName = uniqueFileName(stem: stem, ext: ext, usedLowercasedNames: &usedNames)
            let destURL = folderURL.appendingPathComponent(fileName)

            do {
                try fm.copyItem(at: item.sourceURL, to: destURL)
                exportedURLs.append(destURL)
            } catch {
                try? fm.removeItem(at: sessionDir)
                if isOutOfSpaceError(error) { throw OfflineAudioExportError.outOfSpace }
                throw OfflineAudioExportError.failed("准备导出文件失败：\(error.localizedDescription)")
            }
        }

        guard !exportedURLs.isEmpty else {
            try? fm.removeItem(at: sessionDir)
            throw OfflineAudioExportError.noValidFiles
        }

        return OfflineAudioExportBatch(
            sessionDir: sessionDir,
            folderURL: folderURL,
            fileURLs: exportedURLs,
            exportedCount: exportedURLs.count,
            skippedCount: skippedCount
        )
    }

    /// 清理超过指定存活期的导出临时目录（冷启动或下次导出时自动回收，避免抢删后台传输中的文件）
    static func cleanupStaleStagingDirectories(in root: URL? = nil, maxAge: TimeInterval = 3600) {
        let fm = FileManager.default
        let targetRoot = root ?? defaultStagingRootURL
        guard let children = try? fm.contentsOfDirectory(
            at: targetRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Swift.max(0, maxAge))
        for child in children {
            if maxAge <= 0 {
                try? fm.removeItem(at: child)
                continue
            }
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: child)
            }
        }
    }

    /// 用户主动取消导出时立即清理当次会话目录
    static func removeSessionDirectory(_ sessionDir: URL) {
        try? FileManager.default.removeItem(at: sessionDir)
    }

    private static func isValidNonEmptyFile(at url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size > 0
    }

    private static func isOutOfSpaceError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpaceError(underlying)
        }
        return false
    }
}
