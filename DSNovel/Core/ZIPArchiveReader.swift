import Foundation
import Compression

/// 零第三方依赖的最小 ZIP 中央目录解析器（支持 Store 与 Deflate 压缩格式，用于解压插件包）
/// 8-5：支持 0 字节 Deflate 条目、保留规范化安全相对路径（防重名覆盖与目录穿越）并补齐 IEEE 802.3 CRC-32 校验。
enum ZIPArchiveReader {
    /// R3-3：ZIP 炸弹安全硬上限
    static let maxEntries: Int = 128
    static let maxSingleFileBytes: Int = 8 * 1024 * 1024     // 8 MB
    static let maxTotalExtractedBytes: Int = 32 * 1024 * 1024 // 32 MB

    enum ZIPError: LocalizedError {
        case invalidArchive
        case decompressionFailed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "无效的 ZIP 插件压缩包"
            case .decompressionFailed(let name): return "解压文件失败: \(name)"
            case .unsupported(let reason): return "不支持的 ZIP 压缩包：\(reason)"
            }
        }
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            return c
        }
    }()

    /// 计算标准 IEEE 802.3 CRC-32 校验值
    static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw {
                let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ crc32Table[idx]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// 规范化 ZIP 条目相对路径：拦截 `..` 目录穿越与绝对路径，忽略目录项与 macOS 资源派生文件
    private static func normalizeSafeRelativePath(_ rawName: String) throws -> String? {
        let unified = rawName.replacingOccurrences(of: "\\", with: "/")
        if unified.isEmpty || unified.hasSuffix("/") {
            return nil
        }
        let segments = unified.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var cleaned: [String] = []
        cleaned.reserveCapacity(segments.count)
        for seg in segments {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                throw ZIPError.unsupported("压缩包包含非法路径（目录穿越）：\(rawName)")
            }
            if seg == "__MACOSX" {
                return nil
            }
            cleaned.append(seg)
        }
        guard let last = cleaned.last, !last.isEmpty else { return nil }
        if last.hasPrefix("._") || last == ".DS_Store" {
            return nil
        }
        return cleaned.joined(separator: "/")
    }

    static func extractAll(from zipData: Data) throws -> [String: Data] {
        guard zipData.count >= 22 else { throw ZIPError.invalidArchive }

        return try zipData.withUnsafeBytes { rawBuffer -> [String: Data] in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 22, let baseAddr = bytes.baseAddress else {
                throw ZIPError.invalidArchive
            }

            // 查找 End of Central Directory (0x06054b50)
            var eocdOffset = -1
            let minOffset = max(0, count - 65557)
            for i in stride(from: count - 22, through: minOffset, by: -1) {
                if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
                    eocdOffset = i
                    break
                }
            }
            guard eocdOffset >= 0 else { throw ZIPError.invalidArchive }

            let totalEntries = Int(readUInt16(bytes, eocdOffset + 10))
            let cdOffsetU32 = readUInt32(bytes, eocdOffset + 16)
            if totalEntries == 0xFFFF || cdOffsetU32 == 0xFFFF_FFFF {
                throw ZIPError.unsupported("ZIP64 格式，请用系统「文件」App 或常规压缩工具重新压缩")
            }
            if totalEntries > maxEntries {
                throw ZIPError.unsupported("压缩包条目数超过安全上限（\(totalEntries) > \(maxEntries)）")
            }
            let cdOffset = Int(cdOffsetU32)
            guard cdOffset >= 0, cdOffset + 46 <= count else { throw ZIPError.invalidArchive }

            var rawEntries: [(path: String, data: Data)] = []
            rawEntries.reserveCapacity(totalEntries)
            var totalExtractedBytes = 0
            var totalDeclaredBytes = 0
            var pos = cdOffset

            for _ in 0..<totalEntries {
                guard pos + 46 <= count,
                      bytes[pos] == 0x50, bytes[pos + 1] == 0x4B,
                      bytes[pos + 2] == 0x01, bytes[pos + 3] == 0x02 else {
                    break
                }
                let generalFlags = readUInt16(bytes, pos + 8)
                let compressionMethod = readUInt16(bytes, pos + 10)
                let expectedCRC = readUInt32(bytes, pos + 16)
                let compressedSize = Int(readUInt32(bytes, pos + 20))
                let uncompressedSize = Int(readUInt32(bytes, pos + 24))
                let nameLen = Int(readUInt16(bytes, pos + 28))
                let extraLen = Int(readUInt16(bytes, pos + 30))
                let commentLen = Int(readUInt16(bytes, pos + 32))
                let localHeaderOffset = Int(readUInt32(bytes, pos + 42))

                let nameStart = pos + 46
                guard nameStart + nameLen <= count else { break }
                let nameSlice = UnsafeBufferPointer(start: baseAddr.advanced(by: nameStart), count: nameLen)
                let rawName = String(decoding: nameSlice, as: UTF8.self)
                pos = nameStart + nameLen + extraLen + commentLen

                guard let safePath = try normalizeSafeRelativePath(rawName) else {
                    continue
                }

                guard localHeaderOffset >= 0,
                      localHeaderOffset + 30 <= count,
                      bytes[localHeaderOffset] == 0x50, bytes[localHeaderOffset + 1] == 0x4B,
                      bytes[localHeaderOffset + 2] == 0x03, bytes[localHeaderOffset + 3] == 0x04 else {
                    throw ZIPError.invalidArchive
                }
                let localNameLen = Int(readUInt16(bytes, localHeaderOffset + 26))
                let localExtraLen = Int(readUInt16(bytes, localHeaderOffset + 28))
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
                guard compressedSize >= 0, dataStart <= count - compressedSize else {
                    throw ZIPError.invalidArchive
                }

                if generalFlags & 0x1 != 0 {
                    throw ZIPError.unsupported("压缩包已加密，请先解除密码")
                }

                // 预校验声明体积（防止头字段直接宣告超大文件）
                if uncompressedSize > maxSingleFileBytes {
                    throw ZIPError.unsupported("单文件 \(safePath) 解压体积超过安全上限（> 8 MB）")
                }
                totalDeclaredBytes += uncompressedSize
                if totalDeclaredBytes > maxTotalExtractedBytes || totalExtractedBytes + uncompressedSize > maxTotalExtractedBytes {
                    throw ZIPError.unsupported("压缩包总解压体积超过安全上限（> 32 MB）")
                }

                let remainingBudget = maxTotalExtractedBytes - totalExtractedBytes
                let allowedForThisFile = min(maxSingleFileBytes, remainingBudget)

                let payload: Data
                if compressionMethod == 0 {
                    if compressedSize > allowedForThisFile {
                        throw ZIPError.unsupported("单文件 \(safePath) 体积超过安全上限")
                    }
                    payload = Data(bytes: baseAddr.advanced(by: dataStart), count: compressedSize)
                } else if compressionMethod == 8 {
                    payload = try inflateRawDeflate(
                        baseAddress: baseAddr.advanced(by: dataStart),
                        count: compressedSize,
                        expectedSize: uncompressedSize,
                        maxOutputBytes: allowedForThisFile,
                        entryName: safePath
                    )
                } else {
                    throw ZIPError.unsupported("文件 \(safePath) 使用了不支持的压缩方式(\(compressionMethod))，请改用「标准 ZIP/Deflate」重新压缩")
                }

                // M4：严格 CRC-32 完整性校验（仅空文件允许 CRC 为 0）
                if !(expectedCRC == 0 && payload.isEmpty) {
                    let actualCRC = crc32(of: payload)
                    if actualCRC != expectedCRC {
                        throw ZIPError.decompressionFailed("\(safePath)（CRC-32 校验失败）")
                    }
                }

                totalExtractedBytes += payload.count
                rawEntries.append((path: safePath, data: payload))
            }

            // 若全部有效条目共享唯一的顶层包装目录（如 macOS 压缩文件夹产生的 pkg/manifest.json），仅剥离这一层公共前缀，
            // 同时完整保留子目录相对路径，彻底避免不同子目录中重名文件互相覆盖。
            let commonRootPrefix: String? = {
                guard !rawEntries.isEmpty else { return nil }
                var root: String?
                for entry in rawEntries {
                    guard let slashIdx = entry.path.firstIndex(of: "/") else { return nil }
                    let first = String(entry.path[..<slashIdx])
                    if let existing = root {
                        if existing != first { return nil }
                    } else {
                        root = first
                    }
                }
                return root.map { $0 + "/" }
            }()

            var result: [String: Data] = [:]
            result.reserveCapacity(rawEntries.count)
            for entry in rawEntries {
                let finalPath: String
                if let prefix = commonRootPrefix, entry.path.hasPrefix(prefix) {
                    finalPath = String(entry.path.dropFirst(prefix.count))
                } else {
                    finalPath = entry.path
                }
                guard !finalPath.isEmpty else { continue }
                if result[finalPath] != nil {
                    throw ZIPError.unsupported("压缩包存在重复路径：\(finalPath)")
                }
                result[finalPath] = entry.data
            }
            return result
        }
    }

    private static func inflateRawDeflate(
        baseAddress: UnsafePointer<UInt8>,
        count: Int,
        expectedSize: Int,
        maxOutputBytes: Int,
        entryName: String
    ) throws -> Data {
        // 8-5：支持 0 字节 Deflate 条目（原始 Deflate 空流压缩后通常为 2 字节 0x03 0x00，decoded == 0 属于正常结果）
        if count == 0 || expectedSize == 0 {
            if count == 0 { return Data() }
            var probe = [UInt8](repeating: 0, count: 64)
            let decoded = compression_decode_buffer(&probe, probe.count, baseAddress, count, nil, COMPRESSION_ZLIB)
            if decoded == 0 {
                return Data()
            }
            if decoded > maxOutputBytes {
                throw ZIPError.unsupported("文件 \(entryName) 实际解压体积超过安全上限")
            }
            return Data(probe.prefix(decoded))
        }
        let hardBufferLimit = maxOutputBytes + 1
        var capacity = min(max(expectedSize + 512, 4096), hardBufferLimit)
        while true {
            var dst = [UInt8](repeating: 0, count: capacity)
            let decoded = compression_decode_buffer(&dst, capacity, baseAddress, count, nil, COMPRESSION_ZLIB)
            if decoded == 0 {
                throw ZIPError.decompressionFailed(entryName)
            }
            if decoded < capacity {
                if decoded > maxOutputBytes {
                    throw ZIPError.unsupported("文件 \(entryName) 实际解压体积超过安全上限")
                }
                return Data(dst.prefix(decoded))
            }
            // decoded == capacity 说明输出缓冲区已满，可能仍存在未输出字节
            if capacity >= hardBufferLimit {
                throw ZIPError.unsupported("文件 \(entryName) 实际解压体积超过安全上限")
            }
            capacity = min(capacity * 3, hardBufferLimit)
        }
    }

    private static func readUInt16(_ b: UnsafeBufferPointer<UInt8>, _ off: Int) -> UInt16 {
        UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }

    private static func readUInt32(_ b: UnsafeBufferPointer<UInt8>, _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
}
