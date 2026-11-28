import Foundation
import Testing
@testable import DSNovel

@Suite("离线音频导出闭环验证")
struct DSOfflineAudioExporterTests {
    @Test("Magic Bytes 真实格式嗅探优先于兜底后缀")
    func detectAudioExtensionByMagicBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSExportMagicTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let samples: [(name: String, bytes: [UInt8], expected: String)] = [
            ("a.m4a", [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00], "mp3"),
            ("b.bin", [0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00], "mp3"),
            ("c.bin", [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20], "m4a"),
            ("d.m4a", [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22], "flac"),
            ("e.m4a", [0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC, 0x00], "aac"),
            ("f.m4a", [0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00], "wav"),
            ("g.m4a", [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00], "ogg"),
            ("h.mp3", [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08], "mp3")
        ]

        for sample in samples {
            let fileURL = dir.appendingPathComponent(sample.name)
            try Data(sample.bytes).write(to: fileURL)
            #expect(OfflineAudioExporter.detectAudioExtension(at: fileURL) == sample.expected)
        }
    }

    @Test("跨平台非法字符清洗与 UTF-8 字节安全截断")
    func sanitizeCrossPlatformFileName() {
        let dirty = "凡人修仙传|杨洋主演:影视/原声*?\"<>\\... "
        let cleaned = OfflineAudioExporter.sanitizeComponent(dirty, maxUTF8Bytes: 180)
        #expect(!cleaned.contains("|"))
        #expect(!cleaned.contains(":"))
        #expect(!cleaned.contains("/"))
        #expect(!cleaned.contains("\\"))
        #expect(!cleaned.hasSuffix("."))

        let longCJK = String(repeating: "修仙", count: 80)
        let truncated = OfflineAudioExporter.sanitizeComponent(longCJK, maxUTF8Bytes: 60)
        #expect(truncated.utf8.count <= 60)
        #expect(!truncated.isEmpty)
    }

    @Test("正序导出、CoW 写隔离、跳过缺失文件与防重名")
    func prepareExportEndToEndClosure() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("DSExportE2E-\(UUID().uuidString)", isDirectory: true)
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let mp3Bytes = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x10, 0xAA, 0xBB])
        let m4aBytes = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])

        let f1 = srcDir.appendingPathComponent("ch75.m4a")
        let f2 = srcDir.appendingPathComponent("ch76.m4a")
        let missing = srcDir.appendingPathComponent("missing.m4a")
        try mp3Bytes.write(to: f1)
        try m4aBytes.write(to: f2)

        // 故意倒序传入，验证导出器强制按 chapterIndex 升序排列
        let batch = try OfflineAudioExporter.prepareExport(
            bookTitle: "凡人修仙传|杨洋主演",
            items: [
                OfflineAudioExportItem(sourceURL: f2, chapterIndex: 76, chapterTitle: "第77集 制符之道"),
                OfflineAudioExportItem(sourceURL: missing, chapterIndex: 77, chapterTitle: "第78集 缺失"),
                OfflineAudioExportItem(sourceURL: f1, chapterIndex: 75, chapterTitle: "第76集 燕家")
            ],
            includeBookTitleInFileName: false,
            stagingRoot: stagingDir
        )

        #expect(batch.exportedCount == 2)
        #expect(batch.skippedCount == 1)
        #expect(batch.fileURLs.count == 2)
        #expect(batch.fileURLs[0].lastPathComponent == "0076_第76集 燕家.mp3")
        #expect(batch.fileURLs[1].lastPathComponent == "0077_第77集 制符之道.m4a")

        // 验证 CoW 写时隔离：修改导出副本绝不污染原始离线文件
        try Data([0x00, 0x01]).write(to: batch.fileURLs[0])
        let originalData = try Data(contentsOf: f1)
        #expect(originalData == mp3Bytes)

        // 验证清理过期目录逻辑
        OfflineAudioExporter.cleanupStaleStagingDirectories(in: stagingDir, maxAge: 0)
        #expect(!fm.fileExists(atPath: batch.sessionDir.path))
    }

    @Test("全量文件缺失时抛出 noValidFiles 且不残留空目录")
    func prepareExportAllMissingThrowsAndCleansUp() throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("DSExportMissing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingDir) }

        #expect(throws: OfflineAudioExportError.noValidFiles) {
            _ = try OfflineAudioExporter.prepareExport(
                bookTitle: "测试书",
                items: [
                    OfflineAudioExportItem(
                        sourceURL: stagingDir.appendingPathComponent("none.m4a"),
                        chapterIndex: 0,
                        chapterTitle: "第1集"
                    )
                ],
                includeBookTitleInFileName: true,
                stagingRoot: stagingDir
            )
        }
        let leftover = (try? fm.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        #expect(leftover.isEmpty)
    }
}
