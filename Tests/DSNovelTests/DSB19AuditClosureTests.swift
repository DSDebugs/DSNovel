@testable import DSCore
@testable import DSDesignSystem
@testable import DSPluginKit
import Foundation
import XCTest

/// b19 十轮迭代审计全量修复回归测试（覆盖 NEW-01 ~ NEW-06 与 DSCore 下沉 SSRF 复用）
final class DSB19AuditClosureTests: XCTestCase {

    // MARK: - NEW-04: 空字符串 url/downloadUrl 回退与布尔 header 序列化

    func testNew04_DecodeAudioStreamFallsBackWhenPrimaryURLIsBlank() throws {
        let json = #"{"url":"   ","playUrl":"https://audio.example.com/ch1.m4a","headers":{"X-Flag":true,"X-Count":2}}"#
        let stream = try SourceContractAdapter.decodeAudioStream(json, fallbackQuality: .standard)
        XCTAssertEqual(stream.url.absoluteString, "https://audio.example.com/ch1.m4a")
        XCTAssertEqual(stream.headers["X-Flag"], "true")
        XCTAssertEqual(stream.headers["X-Count"], "2")
    }

    // MARK: - NEW-05: ZIPArchiveReader 显式拦截加密条目位

    func testNew05_ZIPArchiveReaderRejectsEncryptedEntryFlag() {
        var zip = Data()
        // Local file header (30 bytes + 4-byte name "a.js")
        zip.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        zip.append(contentsOf: [0x14, 0x00]) // version
        zip.append(contentsOf: [0x01, 0x00]) // general purpose bit flag: bit 0 (encrypted)
        zip.append(contentsOf: [0x00, 0x00]) // method: stored
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // time/date
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // crc
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // comp size
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // uncomp size
        zip.append(contentsOf: [0x04, 0x00]) // name len
        zip.append(contentsOf: [0x00, 0x00]) // extra len
        zip.append(Data("a.js".utf8))

        let cdOffset = UInt32(zip.count)
        // Central directory header (46 bytes + 4-byte name "a.js")
        zip.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        zip.append(contentsOf: [0x14, 0x00, 0x14, 0x00])
        zip.append(contentsOf: [0x01, 0x00]) // encrypted bit 0 set
        zip.append(contentsOf: [0x00, 0x00]) // method: stored
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // local header offset = 0
        zip.append(Data("a.js".utf8))

        let cdSize = UInt32(zip.count) - cdOffset
        // EOCD (22 bytes)
        zip.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: [0x01, 0x00, 0x01, 0x00])
        withUnsafeBytes(of: cdSize.littleEndian) { zip.append(contentsOf: $0) }
        withUnsafeBytes(of: cdOffset.littleEndian) { zip.append(contentsOf: $0) }
        zip.append(contentsOf: [0x00, 0x00])

        let reader = ZIPArchiveReader()
        XCTAssertThrowsError(try reader.readAll(from: zip)) { error in
            guard case ZIPArchiveError.unsupportedCompression = error else {
                return XCTFail("Expected unsupportedCompression for encrypted ZIP entry, got \(error)")
            }
        }
    }

    // MARK: - NEW-06 & P3: DSCore 下沉 SSRF 校验器与 CoverImagePipeline 私网拦截

    func testNew06_SSRFValidatorBlocksPrivateAndAllowsPublicURLs() throws {
        XCTAssertTrue(DSSSRFValidator.isBlockedHost("127.0.0.1"))
        XCTAssertTrue(DSSSRFValidator.isBlockedHost("localhost."))
        XCTAssertTrue(DSSSRFValidator.isBlockedHost("192.168.1.10"))
        XCTAssertTrue(DSSSRFValidator.isBlockedHost("::ffff:10.0.0.1"))
        XCTAssertFalse(DSSSRFValidator.isBlockedHost("audio.xmcdn.com"))

        let publicURL = try XCTUnwrap(URL(string: "https://imagev2.xmcdn.com/cover.jpg"))
        let privateURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/secret.jpg"))
        XCTAssertTrue(DSSSRFValidator.isPublicHTTPURL(publicURL))
        XCTAssertFalse(DSSSRFValidator.isPublicHTTPURL(privateURL))
    }

    func testNew06_CoverImagePipelineRejectsPrivateIPCoverURL() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSB19CoverSSRF-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pipeline = CoverImagePipeline(diskDirectory: tempDir)

        let loopbackImage = await pipeline.image(for: "http://127.0.0.1/cover.png")
        let lanImage = await pipeline.image(for: "http://192.168.1.1/cover.png")
        XCTAssertNil(loopbackImage, "CoverImagePipeline 不应请求回环地址封面")
        XCTAssertNil(lanImage, "CoverImagePipeline 不应请求局域网私网封面")
    }
}
