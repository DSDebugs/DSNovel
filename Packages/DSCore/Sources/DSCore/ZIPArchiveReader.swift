import Compression
import Foundation

/// 严格 ZIP 解包错误（L-IOS-4：禁止静默 continue 跳过损坏或越界条目）
public enum ZIPArchiveError: Error, Sendable, Equatable, LocalizedError {
    case invalidArchive
    case entryLimitExceeded(Int)
    case entrySizeExceeded(String, Int)
    case totalSizeExceeded(Int)
    case invalidPath(String)
    case truncatedLocalHeader(String)
    case encryptedArchive
    case unsupportedCompression(UInt16)
    case decompressionFailed(String)
    case crcMismatch(entry: String, expected: UInt32, actual: UInt32)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "无效的 ZIP 压缩包"
        case .entryLimitExceeded(let maxCount): return "ZIP 条目数量超过上限（\(maxCount)）"
        case .entrySizeExceeded(let name, _): return "ZIP 条目体积超限：\(name)"
        case .totalSizeExceeded: return "ZIP 总解压体积超过上限（\(ZIPArchiveReader.maxTotalBytes / (1024 * 1024)) MB）"
        case .invalidPath(let name): return "ZIP 包含非法路径：\(name)"
        case .truncatedLocalHeader(let name): return "ZIP 本地文件头越界或损坏：\(name)"
        case .encryptedArchive: return "暂不支持加密的 ZIP 压缩包"
        case .unsupportedCompression(let method): return "不支持的 ZIP 压缩算法：\(method)"
        case .decompressionFailed(let name): return "ZIP 条目解压失败：\(name)"
        case .crcMismatch(let entry, _, _): return "ZIP 条目 CRC-32 校验失败：\(entry)"
        }
    }
}

/// 解包后的只读条目
public struct ZIPEntry: Sendable, Equatable {
    public let path: String
    public let data: Data
    public let crc32: UInt32

    public init(path: String, data: Data, crc32: UInt32) {
        self.path = path
        self.data = data
        self.crc32 = crc32
    }
}

/// 严格安全 ZIP 解析器（8 MB 单文件 / 32 MB 总解压 / 128 条上限 / 防路径穿越 / 强检本地头与非空 CRC-32）
public struct ZIPArchiveReader: Sendable {
    public static let maxEntryBytes: Int = 8 * 1024 * 1024
    public static let maxTotalBytes: Int = 32 * 1024 * 1024
    public static let maxEntries: Int = 128

    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let centralDirSignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    public init() {}

    public func readAll(from inputData: Data) throws -> [ZIPEntry] {
        let data = inputData.startIndex == 0 ? inputData : Data(inputData)
        guard data.count >= 22 else { throw ZIPArchiveError.invalidArchive }
        guard let eocdOffset = findEOCDOffset(in: data) else {
            throw ZIPArchiveError.invalidArchive
        }
        let totalEntries = Int(readUInt16(data, at: eocdOffset + 10))
        let centralDirSize = Int(readUInt32(data, at: eocdOffset + 12))
        let centralDirOffset = Int(readUInt32(data, at: eocdOffset + 16))

        guard totalEntries <= Self.maxEntries else {
            throw ZIPArchiveError.entryLimitExceeded(Self.maxEntries)
        }
        guard centralDirOffset >= 0,
              centralDirSize >= 0,
              centralDirOffset + centralDirSize <= data.count else {
            throw ZIPArchiveError.invalidArchive
        }

        var entries: [ZIPEntry] = []
        var seenPaths: Set<String> = []
        var cursor = centralDirOffset
        var totalDeclaredUncompressed = 0
        var totalActualUncompressed = 0

        for _ in 0..<totalEntries {
            guard cursor + 46 <= centralDirOffset + centralDirSize else {
                throw ZIPArchiveError.invalidArchive
            }
            guard readUInt32(data, at: cursor) == Self.centralDirSignature else {
                throw ZIPArchiveError.invalidArchive
            }
            let generalFlags = readUInt16(data, at: cursor + 8)
            let method = readUInt16(data, at: cursor + 10)
            guard (generalFlags & 0x0001) == 0 else {
                throw ZIPArchiveError.encryptedArchive
            }
            let expectedCRC = readUInt32(data, at: cursor + 16)
            let compressedSize = Int(readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int(readUInt32(data, at: cursor + 24))
            let nameLen = Int(readUInt16(data, at: cursor + 28))
            let extraLen = Int(readUInt16(data, at: cursor + 30))
            let commentLen = Int(readUInt16(data, at: cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, at: cursor + 42))

            let nameStart = cursor + 46
            let nextCursor = nameStart + nameLen + extraLen + commentLen
            guard nextCursor <= centralDirOffset + centralDirSize else {
                throw ZIPArchiveError.invalidArchive
            }
            guard let rawName = String(data: data[nameStart..<(nameStart + nameLen)], encoding: .utf8) else {
                throw ZIPArchiveError.invalidPath("<non-utf8>")
            }
            cursor = nextCursor

            // 规范化并校验路径（跳过尾随 / 或 \ 目录项，拒绝 . / .. / 空路径段及规范化后重复条目）
            let (normalizedPath, isDirectory) = try validatePath(rawName)
            if isDirectory { continue }
            let normalizedKey = normalizedPath.lowercased()
            guard seenPaths.insert(normalizedKey).inserted else {
                throw ZIPArchiveError.invalidPath("重复条目：\(normalizedPath)")
            }

            guard uncompressedSize <= Self.maxEntryBytes else {
                throw ZIPArchiveError.entrySizeExceeded(normalizedPath, uncompressedSize)
            }
            guard compressedSize <= Self.maxEntryBytes + 1024 else {
                throw ZIPArchiveError.entrySizeExceeded(normalizedPath, compressedSize)
            }
            totalDeclaredUncompressed += uncompressedSize
            guard totalDeclaredUncompressed <= Self.maxTotalBytes else {
                throw ZIPArchiveError.totalSizeExceeded(totalDeclaredUncompressed)
            }

            // 严检本地头边界（绝不 continue 静默跳过！）
            guard localHeaderOffset >= 0, localHeaderOffset + 30 <= data.count else {
                throw ZIPArchiveError.truncatedLocalHeader(normalizedPath)
            }
            guard readUInt32(data, at: localHeaderOffset) == Self.localHeaderSignature else {
                throw ZIPArchiveError.truncatedLocalHeader(normalizedPath)
            }
            let localNameLen = Int(readUInt16(data, at: localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(data, at: localHeaderOffset + 28))
            let payloadStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + compressedSize
            guard payloadStart >= 0, payloadEnd <= data.count else {
                throw ZIPArchiveError.truncatedLocalHeader(normalizedPath)
            }

            let compressedSlice = data[payloadStart..<payloadEnd]
            let remainingTotalBudget = max(0, Self.maxTotalBytes - totalActualUncompressed)
            let maxOutputBytes = min(Self.maxEntryBytes, remainingTotalBudget)
            let outputData: Data
            switch method {
            case 0:
                guard compressedSize == uncompressedSize else {
                    throw ZIPArchiveError.decompressionFailed(normalizedPath)
                }
                outputData = Data(compressedSlice)
            case 8:
                outputData = try inflateRaw(
                    compressedSlice,
                    expectedSize: uncompressedSize,
                    maxOutputBytes: maxOutputBytes,
                    entryName: normalizedPath
                )
                guard outputData.count == uncompressedSize else {
                    throw ZIPArchiveError.decompressionFailed(normalizedPath)
                }
            default:
                throw ZIPArchiveError.unsupportedCompression(method)
            }

            guard outputData.count <= Self.maxEntryBytes else {
                throw ZIPArchiveError.entrySizeExceeded(normalizedPath, outputData.count)
            }
            totalActualUncompressed += outputData.count
            guard totalActualUncompressed <= Self.maxTotalBytes else {
                throw ZIPArchiveError.totalSizeExceeded(totalActualUncompressed)
            }

            let actualCRC = DSCrypto.crc32(outputData)
            if !outputData.isEmpty || expectedCRC != 0 {
                guard actualCRC == expectedCRC else {
                    throw ZIPArchiveError.crcMismatch(entry: normalizedPath, expected: expectedCRC, actual: actualCRC)
                }
            }
            entries.append(ZIPEntry(path: normalizedPath, data: outputData, crc32: actualCRC))
        }
        return entries
    }

    private func validatePath(_ path: String) throws -> (normalized: String, isDirectory: Bool) {
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") || path.contains("\0") {
            throw ZIPArchiveError.invalidPath(path)
        }
        let isDirectory = path.hasSuffix("/") || path.hasSuffix("\\")
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let trimmed = isDirectory ? String(normalized.dropLast()) : normalized
        if trimmed.isEmpty {
            throw ZIPArchiveError.invalidPath(path)
        }
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." || segment == ".." {
                throw ZIPArchiveError.invalidPath(path)
            }
        }
        return (normalized, isDirectory)
    }

    private func findEOCDOffset(in data: Data) -> Int? {
        let minOffset = max(0, data.count - 65_557)
        var pos = data.count - 22
        while pos >= minOffset {
            if readUInt32(data, at: pos) == Self.eocdSignature {
                let commentLen = Int(readUInt16(data, at: pos + 20))
                if pos + 22 + commentLen == data.count {
                    return pos
                }
            }
            pos -= 1
        }
        return nil
    }

    private func inflateRaw(
        _ compressed: Data,
        expectedSize: Int,
        maxOutputBytes: Int,
        entryName: String
    ) throws -> Data {
        if compressed.isEmpty && expectedSize == 0 { return Data() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        var status = compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw ZIPArchiveError.decompressionFailed(entryName)
        }
        defer { compression_stream_destroy(streamPtr) }

        let chunkSize = 32 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        var output = Data()
        output.reserveCapacity(min(maxOutputBytes, max(expectedSize, 1024)))

        try compressed.withUnsafeBytes { rawSrc in
            guard let srcBase = rawSrc.bindMemory(to: UInt8.self).baseAddress else {
                throw ZIPArchiveError.decompressionFailed(entryName)
            }
            streamPtr.pointee.src_ptr = srcBase
            streamPtr.pointee.src_size = compressed.count

            repeat {
                let prevSrcSize = streamPtr.pointee.src_size
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = chunkSize
                status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = chunkSize - streamPtr.pointee.dst_size
                    if produced > 0 {
                        if output.count + produced > maxOutputBytes {
                            if output.count + produced > Self.maxEntryBytes {
                                throw ZIPArchiveError.entrySizeExceeded(entryName, output.count + produced)
                            } else {
                                throw ZIPArchiveError.totalSizeExceeded(Self.maxTotalBytes + 1)
                            }
                        }
                        output.append(dstBuffer, count: produced)
                    } else if status == COMPRESSION_STATUS_OK && streamPtr.pointee.src_size == prevSrcSize {
                        throw ZIPArchiveError.decompressionFailed(entryName)
                    }
                default:
                    throw ZIPArchiveError.decompressionFailed(entryName)
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
