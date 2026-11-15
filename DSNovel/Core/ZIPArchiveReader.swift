import Foundation
import Compression

/// 零第三方依赖的最小 ZIP 中央目录解析器（支持 Store 与 Deflate 压缩格式，用于解压插件包）
enum ZIPArchiveReader {
    enum ZIPError: LocalizedError {
        case invalidArchive
        case decompressionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "无效的 ZIP 插件压缩包"
            case .decompressionFailed(let name): return "解压文件失败: \(name)"
            }
        }
    }

    static func extractAll(from zipData: Data) throws -> [String: Data] {
        guard zipData.count >= 22 else { throw ZIPError.invalidArchive }
        let bytes = [UInt8](zipData)

        // 查找 End of Central Directory (0x06054b50)
        var eocdOffset = -1
        let minOffset = max(0, bytes.count - 65557)
        for i in stride(from: bytes.count - 22, through: minOffset, by: -1) {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { throw ZIPError.invalidArchive }

        let totalEntries = Int(readUInt16(bytes, eocdOffset + 10))
        let cdOffset = Int(readUInt32(bytes, eocdOffset + 16))
        guard cdOffset + 46 <= bytes.count else { throw ZIPError.invalidArchive }

        var result: [String: Data] = [:]
        var pos = cdOffset

        for _ in 0..<totalEntries {
            guard pos + 46 <= bytes.count,
                  bytes[pos] == 0x50, bytes[pos + 1] == 0x4B,
                  bytes[pos + 2] == 0x01, bytes[pos + 3] == 0x02 else {
                break
            }
            let compressionMethod = readUInt16(bytes, pos + 10)
            let compressedSize = Int(readUInt32(bytes, pos + 20))
            let uncompressedSize = Int(readUInt32(bytes, pos + 24))
            let nameLen = Int(readUInt16(bytes, pos + 28))
            let extraLen = Int(readUInt16(bytes, pos + 30))
            let commentLen = Int(readUInt16(bytes, pos + 32))
            let localHeaderOffset = Int(readUInt32(bytes, pos + 42))

            let nameStart = pos + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let rawName = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            pos = nameStart + nameLen + extraLen + commentLen

            // 忽略目录与 macOS 资源派生文件
            let cleanName = (rawName as NSString).lastPathComponent
            if rawName.hasSuffix("/") || cleanName.hasPrefix("._") || rawName.contains("__MACOSX") {
                continue
            }

            guard localHeaderOffset + 30 <= bytes.count,
                  bytes[localHeaderOffset] == 0x50, bytes[localHeaderOffset + 1] == 0x4B,
                  bytes[localHeaderOffset + 2] == 0x03, bytes[localHeaderOffset + 3] == 0x04 else {
                continue
            }
            let localNameLen = Int(readUInt16(bytes, localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(bytes, localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= bytes.count else { continue }

            let payload = Data(bytes[dataStart..<dataEnd])
            if compressionMethod == 0 {
                result[cleanName] = payload
            } else if compressionMethod == 8 {
                if let inflated = inflateRawDeflate(payload, expectedSize: max(uncompressedSize, 1024)) {
                    result[cleanName] = inflated
                } else {
                    throw ZIPError.decompressionFailed(cleanName)
                }
            }
        }
        return result
    }

    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) -> Data? {
        if data.isEmpty { return Data() }
        var capacity = max(expectedSize + 512, 4096)
        for _ in 0..<4 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let decoded = data.withUnsafeBytes { srcPtr -> Int in
                guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&dst, capacity, base, data.count, nil, COMPRESSION_ZLIB)
            }
            if decoded > 0 && decoded < capacity {
                return Data(dst.prefix(decoded))
            }
            capacity *= 3
        }
        return nil
    }

    private static func readUInt16(_ b: [UInt8], _ off: Int) -> UInt16 {
        UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }

    private static func readUInt32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
}
