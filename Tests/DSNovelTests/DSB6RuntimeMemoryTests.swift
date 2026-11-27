@testable import DSNovel
import AVFoundation
import DSCore
import DSDesignSystem
import DSPlayback
import Foundation
import UIKit
import XCTest

/// 第四轮 8 项运行时内存与边界优化（b6）定向回归测试套件（10 项，总单测数达 266 项）
final class DSB6RuntimeMemoryTests: XCTestCase {
    // SYS4-01: 480px 封面缩略图下采样验证（2000x2000 压缩至 <=480px）
    func testSYS4_01_CoverPipelineDownsamplesLargeImageToMax480px() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1200))
        let largeImg = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
        }
        guard let pngData = largeImg.pngData() else {
            return XCTFail("Failed to encode test PNG")
        }
        let decoded = CoverImagePipeline.validateAndDecodeImage(data: pngData, contentType: "image/png")
        XCTAssertNotNil(decoded)
        XCTAssertLessThanOrEqual(max(decoded?.size.width ?? 9999, decoded?.size.height ?? 9999), 480)
    }

    // SYS4-02: ZIP 书源提取严格遵守 manifest.json["scripts"] 顺序
    func testSYS4_02_ExtractOrderedScriptsRespectsManifestOrder() throws {
        let manifest = #"{"name":"Test","version":"1.0","scripts":["common.js","site.js"]}"#
        // 故意在 ZIP 目录中将 site.js 放在 common.js 之前
        let zip = Self.makeStoredZip(entries: [
            ("site.js", Data("var SITE = COMMON + 1;".utf8)),
            ("common.js", Data("var COMMON = 10;".utf8)),
            ("manifest.json", Data(manifest.utf8))
        ])
        let combined = try BundledSourceSeeder.extractOrderedScripts(from: zip)
        let commonRange = combined.range(of: "var COMMON = 10;")
        let siteRange = combined.range(of: "var SITE = COMMON + 1;")
        XCTAssertNotNil(commonRange)
        XCTAssertNotNil(siteRange)
        XCTAssertLessThan(commonRange!.lowerBound, siteRange!.lowerBound)
    }

    // SYS4-02: 无 manifest.json 时自动将 common.js 置顶
    func testSYS4_02_ExtractOrderedScriptsPinsCommonJSFirstWithoutManifest() throws {
        let zip = Self.makeStoredZip(entries: [
            ("a_site.js", Data("var A = 1;".utf8)),
            ("common.js", Data("var COMMON = 0;".utf8))
        ])
        let combined = try BundledSourceSeeder.extractOrderedScripts(from: zip)
        let commonRange = combined.range(of: "var COMMON = 0;")
        let aRange = combined.range(of: "var A = 1;")
        XCTAssertNotNil(commonRange)
        XCTAssertNotNil(aRange)
        XCTAssertLessThan(commonRange!.lowerBound, aRange!.lowerBound)
    }

    // SYS4-04: 按音质档位映射前向缓冲时长
    @MainActor
    func testSYS4_04_ForwardBufferDurationByQualityTier() {
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .saver), 15)
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .standard), 30)
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .high), 60)
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .auto, isOnWiFi: false), 20)
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .auto), 60)
    }

    // SYS4-05: AudioTapDSP 防抖更新不丢最终值，且防抖窗口过后完整参数快照生效
    @MainActor
    func testSYS4_05_AudioTapDSPDebouncedCustomBandsRetainsFinalValue() async {
        let dsp = AudioTapDSP()
        let player = AVPlayer()
        dsp.customBands = [1, 0, 0, 0, 0]
        dsp.customBands = [3, 1, 0, 0, 0]
        dsp.customBands = [5, 2, -1, 0, 1]
        dsp.stereoBalance = 0.4
        dsp.volumeBoostEnabled = true
        dsp.applyFadeVolume(to: player, factor: 0.75)
        let deadline = ContinuousClock.now + .seconds(1)
        while dsp.currentParameters().bandGainsDB != [5, 2, -1, 0, 1] && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let params = dsp.currentParameters()
        XCTAssertEqual(params.bandGainsDB, [5, 2, -1, 0, 1])
        XCTAssertEqual(params.stereoBalance, 0.4, accuracy: 0.001)
        XCTAssertTrue(params.volumeBoostEnabled)
        XCTAssertEqual(params.fadeGain, 0.75, accuracy: 0.001)
        XCTAssertEqual(player.volume, 1.0, accuracy: 0.001)
    }

    // 额外 5 项回归校验
    func testDSScrubberFormatTimeLargeHours() {
        XCTAssertEqual(DSScrubber.formatTime(36_000), "10:00:00")
    }

    func testDSScrubberFormatTimeSubSecondRoundsDown() {
        XCTAssertEqual(DSScrubber.formatTime(59.9), "00:59")
    }

    func testAudioEQPresetAllCasesDistinctTitles() {
        let titles = Set(AudioEQPreset.allCases.map(\.title))
        XCTAssertEqual(titles.count, AudioEQPreset.allCases.count)
    }

    func testAudioDSPParametersFadeGainUpperClamp() {
        let p = AudioDSPParameters(fadeGain: 2.5)
        XCTAssertEqual(p.fadeGain, 1.0)
    }

    func testAudioDSPParametersStereoBalanceLowerClamp() {
        let p = AudioDSPParameters(stereoBalance: -3.0)
        XCTAssertEqual(p.stereoBalance, -1.0)
    }

    private static func makeStoredZip(entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDir = Data()
        func u16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
        }
        for e in entries {
            let offset = UInt32(archive.count)
            let name = Data(e.name.utf8)
            let crc = DSCrypto.crc32(e.data)
            let sz = UInt32(e.data.count)
            u32(&archive, 0x0403_4B50); u16(&archive, 20); u16(&archive, 0); u16(&archive, 0)
            u16(&archive, 0); u16(&archive, 0); u32(&archive, crc); u32(&archive, sz); u32(&archive, sz)
            u16(&archive, UInt16(name.count)); u16(&archive, 0); archive.append(name); archive.append(e.data)

            u32(&centralDir, 0x0201_4B50); u16(&centralDir, 20); u16(&centralDir, 20); u16(&centralDir, 0)
            u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0); u32(&centralDir, crc)
            u32(&centralDir, sz); u32(&centralDir, sz); u16(&centralDir, UInt16(name.count))
            u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0)
            u32(&centralDir, 0); u32(&centralDir, offset); centralDir.append(name)
        }
        let cdOffset = UInt32(archive.count)
        archive.append(centralDir)
        u32(&archive, 0x0605_4B50); u16(&archive, 0); u16(&archive, 0)
        u16(&archive, UInt16(entries.count)); u16(&archive, UInt16(entries.count))
        u32(&archive, UInt32(centralDir.count)); u32(&archive, cdOffset); u16(&archive, 0)
        return archive
    }
}
