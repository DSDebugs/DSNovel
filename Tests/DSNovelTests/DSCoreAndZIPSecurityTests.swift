import DSCore
import Foundation
import XCTest

final class DSCoreAndZIPSecurityTests: XCTestCase {
    func testCryptoHashesAndHTMLDecode() {
        XCTAssertEqual(DSCrypto.md5Hex("hello"), "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(DSCrypto.sha256Hex("hello"), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(DSCrypto.base64Decode(DSCrypto.base64Encode("DSNovel v3 有声书")), "DSNovel v3 有声书")
        XCTAssertEqual(DSCrypto.htmlDecode("A &amp; B &lt;tag&gt; &#65; &#x42;"), "A & B <tag> A B")
        XCTAssertEqual(DSCrypto.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testPlaybackStateBufferingPausePreventsAutoplay() {
        var state = PlaybackState.buffering(generation: 7, shouldPlayWhenReady: true)
        state = state.applyingPauseOrInterrupt()
        XCTAssertEqual(state, .buffering(generation: 7, shouldPlayWhenReady: false))

        // 随后 readyToPlay 到达时，绝不意外外放，必须停在 paused
        let afterReady = state.applyingReadyToPlay(for: 7)
        XCTAssertEqual(afterReady, .paused(generation: 7))
        XCTAssertFalse(afterReady.isPlaying)
    }

    func testPlaybackStateStaleGenerationIgnored() {
        let state = PlaybackState.buffering(generation: 10, shouldPlayWhenReady: true)
        let stale = state.applyingReadyToPlay(for: 9)
        XCTAssertEqual(stale, state)
        let current = state.applyingReadyToPlay(for: 10)
        XCTAssertEqual(current, .playing(generation: 10))
    }

    func testDownloadStateMachineAndRetryBackoff() {
        XCTAssertTrue(DownloadState.queued.canTransition(to: .resolving))
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .completed))
        XCTAssertFalse(DownloadState.completed.canTransition(to: .downloading))
        XCTAssertFalse(DownloadState.completed.canTransition(to: .failed))

        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 0, httpStatus: 500), 2.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 1, httpStatus: 500), 6.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 0, httpStatus: 429), 4.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 1, httpStatus: 503), 12.0)
        XCTAssertNil(DownloadRetryPolicy.delaySeconds(retryCount: 3, httpStatus: 500))

        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 401))
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 403))
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 410))
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 500))
    }

    func testZIPReaderRejectsCorruptAndFuzzedPayloads() {
        let reader = ZIPArchiveReader()
        let fuzzInputs: [Data] = [
            Data(),
            Data("not a zip".utf8),
            Data(repeating: 0x50, count: 64),
            Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0xFF, count: 30))
        ]
        for payload in fuzzInputs {
            XCTAssertThrowsError(try reader.readAll(from: payload))
        }
    }

    func testZIPReaderRejectsPathTraversalAndCRCMismatch() throws {
        let reader = ZIPArchiveReader()
        let badPathZip = Self.makeStoredZip(entries: [("../evil.js", Data("alert(1)".utf8), nil)])
        XCTAssertThrowsError(try reader.readAll(from: badPathZip)) { err in
            guard case ZIPArchiveError.invalidPath = err else {
                return XCTFail("Expected invalidPath, got \(err)")
            }
        }

        let badCRCZip = Self.makeStoredZip(entries: [("good.js", Data("var x = 1;".utf8), 0xDEAD_BEEF)])
        XCTAssertThrowsError(try reader.readAll(from: badCRCZip)) { err in
            guard case ZIPArchiveError.crcMismatch = err else {
                return XCTFail("Expected crcMismatch, got \(err)")
            }
        }

        let validZip = Self.makeStoredZip(entries: [("manifest.json", Data(#"{"name":"ok"}"#.utf8), nil)])
        let parsed = try reader.readAll(from: validZip)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.path, "manifest.json")
    }

    func testDiagnosticSanitizerRedactsCredentials() {
        let raw = "GET /api Cookie: 1&_token=secret123; Authorization: Bearer abcdef token=xyz999"
        let clean = DSDiagnosticLogStore.sanitize(raw)
        XCTAssertFalse(clean.contains("secret123"))
        XCTAssertFalse(clean.contains("abcdef"))
        XCTAssertFalse(clean.contains("xyz999"))
        XCTAssertTrue(clean.contains("[REDACTED]"))
    }

    // 构造最小合法 Stored ZIP 供白盒边界测试
    private static func makeStoredZip(entries: [(name: String, data: Data, overrideCRC: UInt32?)]) -> Data {
        var archive = Data()
        var centralDir = Data()

        func appendU16(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }
        func appendU32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }

        for entry in entries {
            let localOffset = UInt32(archive.count)
            let nameData = Data(entry.name.utf8)
            let crc = entry.overrideCRC ?? DSCrypto.crc32(entry.data)
            let size = UInt32(entry.data.count)

            appendU32(&archive, 0x0403_4B50)
            appendU16(&archive, 20)
            appendU16(&archive, 0)
            appendU16(&archive, 0)
            appendU16(&archive, 0)
            appendU16(&archive, 0)
            appendU32(&archive, crc)
            appendU32(&archive, size)
            appendU32(&archive, size)
            appendU16(&archive, UInt16(nameData.count))
            appendU16(&archive, 0)
            archive.append(nameData)
            archive.append(entry.data)

            appendU32(&centralDir, 0x0201_4B50)
            appendU16(&centralDir, 20)
            appendU16(&centralDir, 20)
            appendU16(&centralDir, 0)
            appendU16(&centralDir, 0)
            appendU16(&centralDir, 0)
            appendU16(&centralDir, 0)
            appendU32(&centralDir, crc)
            appendU32(&centralDir, size)
            appendU32(&centralDir, size)
            appendU16(&centralDir, UInt16(nameData.count))
            appendU16(&centralDir, 0)
            appendU16(&centralDir, 0)
            appendU16(&centralDir, 0)
            appendU16(&centralDir, 0)
            appendU32(&centralDir, 0)
            appendU32(&centralDir, localOffset)
            centralDir.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        archive.append(centralDir)

        appendU32(&archive, 0x0605_4B50)
        appendU16(&archive, 0)
        appendU16(&archive, 0)
        appendU16(&archive, UInt16(entries.count))
        appendU16(&archive, UInt16(entries.count))
        appendU32(&archive, UInt32(centralDir.count))
        appendU32(&archive, cdOffset)
        appendU16(&archive, 0)
        return archive
    }
}
