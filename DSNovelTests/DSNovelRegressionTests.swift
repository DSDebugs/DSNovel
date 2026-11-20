import XCTest
@testable import DSNovel

/// 针对三个已反馈 Bug 的回归测试（本地文件导入 / 选章加载 / 新书进度时间）
final class DSNovelRegressionTests: XCTestCase {

    // MARK: - 辅助：手工构造 Store(无压缩) ZIP

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func makeStoredZip(entries: [(name: String, data: Data)], flags: UInt16 = 0, method: UInt16 = 0) -> Data {
        var body = [UInt8]()
        var central = [UInt8]()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let offset = UInt32(body.count)
            body += [0x50, 0x4B, 0x03, 0x04] + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
            body += le32(0) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count))
            body += le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + Array(entry.data)

            central += [0x50, 0x4B, 0x01, 0x02] + le16(20) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
            central += le32(0) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count))
            central += le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
            central += nameBytes
        }
        let cdOffset = UInt32(body.count)
        var eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0)
        eocd += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        eocd += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        return Data(body + central + eocd)
    }

    // MARK: - Bug 1：本地文件导入

    /// 带 UTF-8 BOM 的单个 .js 书源脚本必须能被识别并解析出书源
    func testImportSingleJSWithUTF8BOM() async throws {
        let script = """
        registerSource({ id: 'bom_src', name: 'BOM 测试源', url: 'https://example.com',
          search: function (kw, page) { return { books: [] }; } });
        """
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(script.utf8))
        let preview = try await PluginRuntime.shared.prepareImportPreview(from: data)
        XCTAssertEqual(preview.sources.map(\.id), ["bom_src"])
    }

    /// GB18030 编码的 .js 书源脚本（国内常见）同样可导入
    func testDecodeScriptTextGB18030() {
        let text = "registerSource({ id: 'gb', name: '中文书源' });"
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = text.data(using: String.Encoding(rawValue: gb))!
        XCTAssertNil(String(data: data, encoding: .utf8))          // 纯 UTF-8 解码会失败
        XCTAssertEqual(PluginRuntime.decodeScriptText(data), text) // 新解码器可还原
    }

    /// ZIP 内容位于子目录（macOS「压缩文件夹」的常见结构）时，manifest.json / 脚本仍能被找到
    func testZIPWithSubfolderIsFlattened() throws {
        let zip = makeStoredZip(entries: [
            (name: "pkg/", data: Data()),
            (name: "pkg/manifest.json", data: Data("{}".utf8)),
            (name: "pkg/source.js", data: Data("var a=1;".utf8)),
            (name: "__MACOSX/pkg/._source.js", data: Data([0, 1, 2]))
        ])
        let files = try ZIPArchiveReader.extractAll(from: zip)
        XCTAssertEqual(Set(files.keys), ["manifest.json", "source.js"])
        XCTAssertEqual(files["source.js"], Data("var a=1;".utf8))
    }

    /// 加密 / 不支持的压缩方式必须给出明确报错，而不是静默忽略后提示「没有找到脚本」
    func testZIPEncryptedAndUnsupportedMethodThrowReadableError() {
        let encrypted = makeStoredZip(entries: [(name: "a.js", data: Data("x".utf8))], flags: 0x1)
        XCTAssertThrowsError(try ZIPArchiveReader.extractAll(from: encrypted))

        let lzma = makeStoredZip(entries: [(name: "a.js", data: Data("x".utf8))], method: 14)
        XCTAssertThrowsError(try ZIPArchiveReader.extractAll(from: lzma))
    }

    // MARK: - Bug 3：章节时长归一化

    func testChapterDurationNormalization() {
        func ch(_ d: Int?) -> ChapterDTO { ChapterDTO(index: 0, title: "t", url: "u", durationSec: d) }
        XCTAssertEqual(ch(1800).normalizedDurationSec, 1800)          // 正常秒
        XCTAssertEqual(ch(1_800_000).normalizedDurationSec, 1800)     // 毫秒折算为秒
        XCTAssertNil(ch(0).normalizedDurationSec)
        XCTAssertNil(ch(-5).normalizedDurationSec)
        XCTAssertNil(ch(nil).normalizedDurationSec)
        XCTAssertNil(ch(Int.max).normalizedDurationSec)               // 离谱值视为未知
        XCTAssertEqual(ch(1_800_000).hintDurationSec, 1800)
        XCTAssertEqual(ch(nil).hintDurationSec, 0)
    }

    /// 进度时间文本：极端/异常输入不得产生乱码
    func testPlaybackClockFormatting() {
        XCTAssertEqual(PlaybackClock.formatSeconds(-3), "00:00")
        XCTAssertEqual(PlaybackClock.formatSeconds(.nan), "00:00")
        XCTAssertEqual(PlaybackClock.formatSeconds(65), "01:05")
        XCTAssertEqual(PlaybackClock.formatSeconds(3725), "1:02:05")
    }

    // MARK: - Bug 2：章节目录缓存

    func testChapterCacheRoundTripAndAge() {
        let bookID = "regression::\(UUID().uuidString)"
        let chapters = (0..<3000).map { ChapterDTO(index: $0, title: "第\($0)集", url: "https://e.com/\($0)", durationSec: 600) }
        ChapterCacheStore.saveChapters(chapters, for: bookID)
        XCTAssertEqual(ChapterCacheStore.loadChapters(for: bookID)?.count, 3000)
        let age = ChapterCacheStore.cacheAge(for: bookID)
        XCTAssertNotNil(age)
        XCTAssertLessThan(age ?? 999, 60)
        XCTAssertNil(ChapterCacheStore.cacheAge(for: "regression::missing"))
    }
}
