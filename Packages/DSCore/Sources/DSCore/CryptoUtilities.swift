import CommonCrypto
import CryptoKit
import Foundation
#if canImport(zlib)
import zlib
#endif

/// 零第三方依赖密码学、哈希、编解码与 CRC-32 工具集
public enum DSCrypto {
    /// 计算字符串 MD5（32 位小写十六进制，用于固定下载路径 md5(bookID)/md5(chapterID).ext）
    public static func md5Hex(_ input: String) -> String {
        md5Hex(Data(input.utf8))
    }

    public static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 计算 SHA-256（64 位小写十六进制）
    public static func sha256Hex(_ input: String) -> String {
        sha256Hex(Data(input.utf8))
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Base64 编解码（兼容缺省填充、内部空白换行与 URL-safe 变体）
    public static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    public static func base64DecodeToData(_ input: String) -> Data? {
        var normalized = input
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    public static func base64Decode(_ input: String) -> String {
        guard let data = base64DecodeToData(input) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// AES-ECB PKCS7 解密（兼容存量 ES5 书源调用 host.aesEcbDecrypt；AUD-42：记录首个合法解密结果含空明文兜底）
    public static func aesEcbDecrypt(base64OrHexData: String, key: String) -> String {
        var candidateKeys: [([UInt8], Int)] = []
        if (key.count == 32 || key.count == 48 || key.count == 64),
           let hexKeyData = dataFromHex(key),
           hexKeyData.count == key.count / 2 {
            candidateKeys.append((Array(hexKeyData), hexKeyData.count))
        }

        var utf8KeyBytes = Array(key.utf8)
        let targetKeySize: Int
        if utf8KeyBytes.count <= 16 {
            targetKeySize = kCCKeySizeAES128
        } else if utf8KeyBytes.count <= 24 {
            targetKeySize = kCCKeySizeAES192
        } else {
            targetKeySize = kCCKeySizeAES256
        }
        if utf8KeyBytes.count < targetKeySize {
            utf8KeyBytes.append(contentsOf: repeatElement(0, count: targetKeySize - utf8KeyBytes.count))
        } else if utf8KeyBytes.count > targetKeySize {
            utf8KeyBytes = Array(utf8KeyBytes.prefix(targetKeySize))
        }
        candidateKeys.append((utf8KeyBytes, targetKeySize))

        // P1-18 / P3-01：优先识别块对齐十六进制密文，解密失败自动回退 Base64
        var candidateCiphers: [Data] = []
        if let hex = dataFromHex(base64OrHexData),
           !hex.isEmpty,
           hex.count % kCCBlockSizeAES128 == 0 {
            candidateCiphers.append(hex)
        }
        if let decoded = base64DecodeToData(base64OrHexData), !decoded.isEmpty {
            candidateCiphers.append(decoded)
        }

        var firstValidFallback: String?
        for (keyBytes, keySize) in candidateKeys {
            for cipher in candidateCiphers {
                if let plain = decryptAESECB(cipher, keyBytes: keyBytes, keySize: keySize) {
                    if !plain.isEmpty {
                        return plain
                    }
                    if firstValidFallback == nil {
                        firstValidFallback = plain
                    }
                }
            }
        }
        return firstValidFallback ?? ""
    }

    private static func decryptAESECB(_ cipherData: Data, keyBytes: [UInt8], keySize: Int) -> String? {
        var outBuffer = [UInt8](repeating: 0, count: cipherData.count + kCCBlockSizeAES128)
        var outMoved: Int = 0
        let status: CCCryptorStatus = cipherData.withUnsafeBytes { inPtr in
            keyBytes.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyPtr.baseAddress,
                    keySize,
                    nil,
                    inPtr.baseAddress,
                    cipherData.count,
                    &outBuffer,
                    outBuffer.count,
                    &outMoved
                )
            }
        }
        guard status == kCCSuccess, outMoved >= 0 else { return nil }
        return String(bytes: outBuffer.prefix(outMoved), encoding: .utf8)
    }

    /// IEEE 802.3 CRC-32 校验（AUD-82：优先调用系统 zlib.crc32 硬件/C 加速）
    public static func crc32(_ data: Data) -> UInt32 {
        #if canImport(zlib)
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { rawBuf -> UInt32 in
            guard let base = rawBuf.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            var crc = zlib.crc32(0, nil, 0)
            var offset = 0
            let total = rawBuf.count
            let maxChunk = Int(UInt32.max)
            while offset < total {
                let chunk = min(maxChunk, total - offset)
                crc = zlib.crc32(crc, base.advanced(by: offset), uInt(chunk))
                offset += chunk
            }
            return UInt32(truncatingIfNeeded: crc)
        }
        #else
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32Table[idx]
        }
        return crc ^ 0xFFFF_FFFF
        #endif
    }

    #if !canImport(zlib)
    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
    #endif

    private static let htmlNamedEntityMap: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
        "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
        "hellip": "…", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "middot": "·",
        "emsp": "\u{2003}", "ensp": "\u{2002}", "copy": "©",
        "reg": "®", "trade": "™", "times": "×", "divide": "÷",
        "laquo": "«", "raquo": "»", "bull": "•"
    ]
    private static let htmlEntityRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z]+);"
    )

    /// 常见 HTML 实体解码（P1-17 / AUD-82：单遍扫描、过滤 NUL、越界/代理项数字实体保留原文并支持中文排版命名实体）
    public static func htmlDecode(_ input: String) -> String {
        guard input.contains("&"), let regex = htmlEntityRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var lastLoc = 0
        for m in matches {
            if m.range.location > lastLoc {
                out += ns.substring(with: NSRange(location: lastLoc, length: m.range.location - lastLoc))
            }
            let body = ns.substring(with: m.range(at: 1))
            if body.hasPrefix("#") {
                let numPart = body.dropFirst()
                let codeVal: UInt32?
                if numPart.hasPrefix("x") || numPart.hasPrefix("X") {
                    codeVal = UInt32(numPart.dropFirst(), radix: 16)
                } else {
                    codeVal = UInt32(numPart, radix: 10)
                }
                if let v = codeVal {
                    if v == 0 {
                        // 过滤 NUL 字符
                    } else if let scalar = UnicodeScalar(v) {
                        out.append(Character(scalar))
                    } else {
                        out += ns.substring(with: m.range)
                    }
                } else {
                    out += ns.substring(with: m.range)
                }
            } else if let rep = htmlNamedEntityMap[body.lowercased()] {
                out += rep
            } else {
                out += ns.substring(with: m.range)
            }
            lastLoc = m.range.location + m.range.length
        }
        if lastLoc < ns.length {
            out += ns.substring(with: NSRange(location: lastLoc, length: ns.length - lastLoc))
        }
        return out
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }
}
