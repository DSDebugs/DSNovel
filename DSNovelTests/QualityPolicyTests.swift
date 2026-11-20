import XCTest
@testable import DSNovel

/// `QualityPolicy`（4 档统一音质策略层）单元测试
///
/// 覆盖口径：
///  1. 可见档位与默认档位（固定 4 档：智能自适应 / 标准 / 高清 / 超清，默认 `.hd`）
///  2. 两条链 × 4 档位的链码映射矩阵（Wi-Fi / 蜂窝）
///  3. 纯 4 档模型（`auto` / `std` / `hd` / `uhd`，默认 `.hd`，无旧档位兼容）
///  4. 单书独立覆写 + 全局默认合并解析（`effectiveTier(bookOverrideRaw:globalDefault:)`）
///  5. 独立码率核算分桶边界（35k/36k/71k/72k）与换算/体积兜底
///  6. 多码率能力判定、切档重载判定与系统托管配置键
final class QualityPolicyTests: XCTestCase {

    // MARK: - 1. 可见档位与默认档位

    func testVisibleTiersAndDefaultTier() {
        let expected: [AudioQualityTier] = [.auto, .std, .hd, .uhd]
        XCTAssertEqual(AudioQualityTier.visibleTiers, expected)
        XCTAssertEqual(AudioQualityTier.visibleTiers.count, 4)
        XCTAssertEqual(AudioQualityTier.defaultTier, .hd)

        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: true), expected)
        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: false), expected)
        XCTAssertEqual(QualityPolicy.visibleTiers(declaredQualities: ["auto", "saver", "standard", "high", "lossless"]), expected)
        XCTAssertEqual(QualityPolicy.visibleTiers(declaredQualities: []), expected)

    }

    // MARK: - 2. 4 档链码映射矩阵

    func testCodeForBookSourceChain() {
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: false), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .std, chain: .bookSource, isOnWiFi: true), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .std, chain: .bookSource, isOnWiFi: false), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .hd, chain: .bookSource, isOnWiFi: true), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .hd, chain: .bookSource, isOnWiFi: false), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .bookSource, isOnWiFi: false), "M4A_128")
    }

    func testCodeForBuiltinParserChain() {
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: true), "high")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: false), "saver")
        XCTAssertEqual(QualityPolicy.code(for: .std, chain: .builtinParser, isOnWiFi: true), "saver")
        XCTAssertEqual(QualityPolicy.code(for: .std, chain: .builtinParser, isOnWiFi: false), "saver")
        XCTAssertEqual(QualityPolicy.code(for: .hd, chain: .builtinParser, isOnWiFi: true), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .hd, chain: .builtinParser, isOnWiFi: false), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .builtinParser, isOnWiFi: true), "high")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .builtinParser, isOnWiFi: false), "high")
    }

    func testMappingMatrixAllVisibleTiersBothChains() {
        let wifiMatrix: [(tier: AudioQualityTier, bookCode: String, parserCode: String)] = [
            (.auto, "M4A_128", "high"),
            (.std, "M4A_24", "saver"),
            (.hd, "M4A_64", "standard"),
            (.uhd, "M4A_128", "high")
        ]
        for row in wifiMatrix {
            XCTAssertEqual(QualityPolicy.code(for: row.tier, chain: .bookSource, isOnWiFi: true), row.bookCode)
            XCTAssertEqual(QualityPolicy.code(for: row.tier, chain: .builtinParser, isOnWiFi: true), row.parserCode)
            XCTAssertFalse(QualityPolicy.code(for: row.tier, chain: .builtinParser, isOnWiFi: true).hasPrefix("M4A_"))
        }

        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: false), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: false), "saver")
    }

    // MARK: - 3. 纯 4 档模型校验（拒绝已移除的旧档位 rawValue）

    func testLegacyTierRawValuesRejected() {
        for legacyRaw in ["saver", "standard", "high", "lossless", "ultra"] {
            XCTAssertNil(AudioQualityTier(rawValue: legacyRaw))
        }
    }

    // MARK: - 4. 单书覆写 + 全局默认合并解析

    func testEffectiveTierWithBookOverrideAndGlobalDefault() {
        // 未覆写（nil 或空串）→ 跟随全局默认
        XCTAssertEqual(QualityPolicy.effectiveTier(bookOverrideRaw: nil, globalDefault: .hd), .hd)
        XCTAssertEqual(QualityPolicy.effectiveTier(bookOverrideRaw: "", globalDefault: .auto), .auto)
        XCTAssertEqual(QualityPolicy.effectiveTier(bookOverrideRaw: "invalid_raw", globalDefault: .uhd), .uhd)

        // 全局默认为旧值时也自动归一

        // 单书有效覆写优先于全局默认（含旧值迁移）
        XCTAssertEqual(QualityPolicy.effectiveTier(bookOverrideRaw: "std", globalDefault: .uhd), .std)
        XCTAssertEqual(QualityPolicy.effectiveTier(bookOverrideRaw: "uhd", globalDefault: .hd), .uhd)
    }

    // MARK: - 5. 独立码率核算分桶边界与换算

    func testBitrateTierLabelBoundariesAndFormatting() {
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 24), "标准")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 35), "标准")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 36), "高清")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 48), "高清")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 71), "高清")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 72), "超清")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 96), "超清")
        XCTAssertEqual(AudioQualityTier.tierLabel(forBitrateKbps: 128), "超清")

        // 直接展示真实核算码率，不再强制量化
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 0), "")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: -10), "")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 35), "标准·35k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 36), "高清·36k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 71), "高清·71k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 72), "超清·72k")

        // bytes / durationSec 核算
        XCTAssertNil(AudioQualityTier.computedBitrateKbps(bytes: 0, durationSec: 120))
        XCTAssertNil(AudioQualityTier.computedBitrateKbps(bytes: 1_000_000, durationSec: 1.0))
        // 600_000 bytes * 8 / 100s / 1000 = 48 kbps
        XCTAssertEqual(AudioQualityTier.computedBitrateKbps(bytes: 600_000, durationSec: 100.0), 48)
        // 1_200_000 bytes * 8 / 100s / 1000 = 96 kbps
        XCTAssertEqual(AudioQualityTier.computedBitrateKbps(bytes: 1_200_000, durationSec: 100.0), 96)

        // 体积兜底
        XCTAssertEqual(AudioQualityTier.formattedSizeFallback(bytes: 0), "")
        XCTAssertFalse(AudioQualityTier.formattedSizeFallback(bytes: 3_500_000).isEmpty)
    }

    // MARK: - 6. 原生支持、多码率与切档重载判定

    func testIsNativeAndNoFallbackForVisibleTiers() {
        for tier in AudioQualityTier.visibleTiers {
            XCTAssertTrue(QualityPolicy.isNative(tier, chain: .bookSource))
            XCTAssertTrue(QualityPolicy.isNative(tier, chain: .builtinParser))
            XCTAssertEqual(QualityPolicy.nearestSupported(tier, chain: .bookSource), tier)
            XCTAssertEqual(QualityPolicy.nearestSupported(tier, chain: .builtinParser), tier)
            XCTAssertFalse(QualityPolicy.didFallback(tier, chain: .bookSource))
            XCTAssertFalse(QualityPolicy.didFallback(tier, chain: .builtinParser))
        }
    }

    func testSourceHasMultipleBitratesAndReloadPolicy() {
        let xmID = "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64"
        XCTAssertTrue(QualityPolicy.sourceHasMultipleBitrates(sourceID: xmID))
        XCTAssertFalse(QualityPolicy.sourceHasMultipleBitrates(sourceID: "other_source"))
        XCTAssertFalse(QualityPolicy.sourceHasMultipleBitrates(sourceID: ""))
        XCTAssertEqual(QualityPolicy.multiBitrateSourceIDs, [xmID])

        XCTAssertTrue(QualityPolicy.canReloadForTierChange(sourceID: xmID, isLocalOffline: false))
        XCTAssertFalse(QualityPolicy.canReloadForTierChange(sourceID: xmID, isLocalOffline: true))
        XCTAssertFalse(QualityPolicy.canReloadForTierChange(sourceID: "other_source", isLocalOffline: false))
        XCTAssertFalse(QualityPolicy.canReloadForTierChange(sourceID: "", isLocalOffline: false))
    }

    func testManagedParserConfigKeysExactSet() {
        XCTAssertEqual(
            QualityPolicy.managedParserConfigKeys,
            ["quality", "cookieSource", "allowRemoteCookie", "remoteCookieURL", "linkTTL"]
        )
        XCTAssertEqual(QualityPolicy.managedParserConfigKeys.count, 5)
    }
}
