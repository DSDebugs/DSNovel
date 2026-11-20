import XCTest
@testable import DSNovel

/// `QualityPolicy`（统一音质档位策略层）单元测试
///
/// 背景：「内置解析改造」把音质从「挂在 AudioQualityTier 上的单一码换算（已删除）」
/// 改为「按**当前链**分别换算码」，映射全部集中到 `QualityPolicy`（唯一映射入口）。
///
/// 覆盖五组口径：
///  1. 面板可见档位（解析器参与解析时为 5 档，否则为全局 4 档，顺序固定）
///  2. 两条链 × 5 档位的码映射矩阵（书源链 `M4A_xx` / 解析器链语义码）
///  3. 原生支持与回落规则（`isNative` / `nearestSupported` / `didFallback`，并列向上）
///  4. 多码率能力判定（`sourceHasMultipleBitrates`）
///  5. 系统托管配置键（`managedParserConfigKeys`，界面永不渲染）
///  6. 解析器声明的能力（`parserDeclaresLossless`）
final class QualityPolicyTests: XCTestCase {

    // MARK: - 1. 可见档位

    /// 解析器参与解析 → 4 档全局 + 1 档「无损 · 最高音质」，顺序固定
    func testVisibleTiersWithParserAvailable() {
        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: true),
                       [.auto, .dataSaver, .standard, .high, .losslessHQ])
        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: true).count, 5)
        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: true).last, AudioQualityTier.losslessHQ,
                       "无损档应排在最后（追加在既有 4 档之后）")
    }

    /// 解析器不参与 → 退回 `AudioQualityTier.visibleTiers`（4 档），且不含旧值 `lossless`
    func testVisibleTiersWithoutParserFallsBackToGlobalFourTiers() {
        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: false), AudioQualityTier.visibleTiers)
        XCTAssertEqual(QualityPolicy.visibleTiers(parserAvailable: false),
                       [.auto, .dataSaver, .standard, .high])
        XCTAssertEqual(AudioQualityTier.visibleTiers.count, 4)
        XCTAssertFalse(AudioQualityTier.visibleTiers.contains(.lossless))
        XCTAssertFalse(AudioQualityTier.visibleTiers.contains(.losslessHQ))
        // 前 4 档与全局档位表完全一致（只在末尾追加无损档）
        XCTAssertEqual(Array(QualityPolicy.visibleTiers(parserAvailable: true).dropLast()),
                       AudioQualityTier.visibleTiers)
    }

    // MARK: - 2. 档位 → 链码映射

    /// 书源链：只认 `M4A_24 / M4A_64 / M4A_128`（与内置包 common.js 的 priorityMap 对齐）
    func testCodeForBookSourceChain() {
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: false), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .dataSaver, chain: .bookSource, isOnWiFi: true), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .dataSaver, chain: .bookSource, isOnWiFi: false), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .standard, chain: .bookSource, isOnWiFi: true), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .standard, chain: .bookSource, isOnWiFi: false), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .high, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .high, chain: .bookSource, isOnWiFi: false), "M4A_128")
        // 书源链不原生支持无损 → 先回落 `.high`，再取高清码（与网络类型无关）
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .bookSource, isOnWiFi: false), "M4A_128")
    }

    /// 解析器链：使用脚本 v1.2 的语义档位码（`auto / saver / standard / high / lossless`）
    func testCodeForBuiltinParserChain() {
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: true), "high")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: false), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .dataSaver, chain: .builtinParser, isOnWiFi: true), "saver")
        XCTAssertEqual(QualityPolicy.code(for: .dataSaver, chain: .builtinParser, isOnWiFi: false), "saver")
        XCTAssertEqual(QualityPolicy.code(for: .standard, chain: .builtinParser, isOnWiFi: true), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .standard, chain: .builtinParser, isOnWiFi: false), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .high, chain: .builtinParser, isOnWiFi: true), "high")
        XCTAssertEqual(QualityPolicy.code(for: .high, chain: .builtinParser, isOnWiFi: false), "high")
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .builtinParser, isOnWiFi: true), "lossless")
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .builtinParser, isOnWiFi: false), "lossless")
    }

    /// 参数化矩阵：5 档位 × 2 条链（Wi-Fi 下，共 10 条映射）
    func testMappingMatrixAllTiersBothChainsOnWiFi() {
        let expected: [(tier: AudioQualityTier, bookCode: String, parserCode: String)] = [
            (.auto, "M4A_128", "high"),
            (.dataSaver, "M4A_24", "saver"),
            (.standard, "M4A_64", "standard"),
            (.high, "M4A_128", "high"),
            (.losslessHQ, "M4A_128", "lossless")
        ]
        for row in expected {
            XCTAssertEqual(
                QualityPolicy.code(for: row.tier, chain: .bookSource, isOnWiFi: true),
                row.bookCode,
                "书源链 \(row.tier.rawValue) 的码不符"
            )
            XCTAssertEqual(
                QualityPolicy.code(for: row.tier, chain: .builtinParser, isOnWiFi: true),
                row.parserCode,
                "解析器链 \(row.tier.rawValue) 的码不符"
            )
        }
        // 解析器链的语义码不得混入书源链的 `M4A_xx` 词汇（两链词汇互不通用）
        for row in expected {
            XCTAssertFalse(
                QualityPolicy.code(for: row.tier, chain: .builtinParser, isOnWiFi: true).hasPrefix("M4A_"),
                "解析器链仍产出书源链的码：\(row.tier.rawValue)"
            )
        }
    }

    /// 旧存档值 `.lossless` 在两链上都等价于 `.high`（折叠发生在映射之前）
    func testLegacyLosslessTierMapsLikeHighOnBothChains() {
        for isOnWiFi in [true, false] {
            XCTAssertEqual(QualityPolicy.code(for: .lossless, chain: .bookSource, isOnWiFi: isOnWiFi),
                           QualityPolicy.code(for: .high, chain: .bookSource, isOnWiFi: isOnWiFi))
            XCTAssertEqual(QualityPolicy.code(for: .lossless, chain: .builtinParser, isOnWiFi: isOnWiFi),
                           QualityPolicy.code(for: .high, chain: .builtinParser, isOnWiFi: isOnWiFi))
        }
        XCTAssertEqual(QualityPolicy.code(for: .lossless, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .lossless, chain: .builtinParser, isOnWiFi: true), "high")
    }

    // MARK: - 3. 原生支持与回落

    func testIsNativePerChain() {
        for tier in [AudioQualityTier.auto, .dataSaver, .standard, .high] {
            XCTAssertTrue(QualityPolicy.isNative(tier, chain: .bookSource), "书源链应原生支持 \(tier.rawValue)")
            XCTAssertTrue(QualityPolicy.isNative(tier, chain: .builtinParser), "解析器链应原生支持 \(tier.rawValue)")
        }
        XCTAssertFalse(QualityPolicy.isNative(.losslessHQ, chain: .bookSource),
                       "无损档只有解析器链原生支持")
        XCTAssertTrue(QualityPolicy.isNative(.losslessHQ, chain: .builtinParser))
        // 旧值先折叠成 .high 再判定
        XCTAssertTrue(QualityPolicy.isNative(.lossless, chain: .bookSource))
        XCTAssertTrue(QualityPolicy.isNative(.lossless, chain: .builtinParser))
    }

    /// 书源链选「无损」→ 取最接近的高清；解析器链选「无损」→ 不回落
    func testNearestSupportedOnlyFallsBackOnBookSourceChain() {
        XCTAssertEqual(QualityPolicy.nearestSupported(.losslessHQ, chain: .bookSource), .high)
        XCTAssertEqual(QualityPolicy.nearestSupported(.losslessHQ, chain: .builtinParser), .losslessHQ)
        XCTAssertEqual(QualityPolicy.nearestSupported(.high, chain: .bookSource), .high)
        XCTAssertEqual(QualityPolicy.nearestSupported(.dataSaver, chain: .builtinParser), .dataSaver)
        XCTAssertEqual(QualityPolicy.nearestSupported(.lossless, chain: .bookSource), .high)
    }

    func testDidFallbackOnlyForLosslessHQOnBookSourceChain() {
        XCTAssertTrue(QualityPolicy.didFallback(.losslessHQ, chain: .bookSource))
        XCTAssertFalse(QualityPolicy.didFallback(.losslessHQ, chain: .builtinParser))
        for tier in AudioQualityTier.visibleTiers {
            XCTAssertFalse(QualityPolicy.didFallback(tier, chain: .bookSource),
                           "\(tier.rawValue) 不应在书源链回落")
            XCTAssertFalse(QualityPolicy.didFallback(tier, chain: .builtinParser),
                           "\(tier.rawValue) 不应在解析器链回落")
        }
        // 旧值 lossless 折叠为 .high，本身不算回落
        XCTAssertFalse(QualityPolicy.didFallback(.lossless, chain: .bookSource))
        XCTAssertFalse(QualityPolicy.didFallback(.lossless, chain: .builtinParser))
    }

    // MARK: - 4. 多码率能力判定

    func testSourceHasMultipleBitrates() {
        XCTAssertTrue(QualityPolicy.sourceHasMultipleBitrates(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64"),
                      "喜马拉雅书源应具备原生多码率能力")
        XCTAssertFalse(QualityPolicy.sourceHasMultipleBitrates(sourceID: "other_source"))
        XCTAssertFalse(QualityPolicy.sourceHasMultipleBitrates(sourceID: ""))
        XCTAssertEqual(QualityPolicy.multiBitrateSourceIDs, ["6e2b9c4d8a1f4d37b5c0e73a9f1d2b64"],
                       "能力表当前只应包含喜马拉雅一个书源 ID")
    }

    // MARK: - 5. 系统托管配置键

    /// 这 5 个键由 App / 脚本内部管理，解析器界面必须永不渲染（B5 + 2.2/2.3/2.5 精简要求）
    func testManagedParserConfigKeysExactSet() {
        XCTAssertEqual(QualityPolicy.managedParserConfigKeys,
                       ["quality", "cookieSource", "allowRemoteCookie", "remoteCookieURL", "linkTTL"])
        XCTAssertEqual(QualityPolicy.managedParserConfigKeys.count, 5)
        for key in ["quality", "cookieSource", "allowRemoteCookie", "remoteCookieURL", "linkTTL"] {
            XCTAssertTrue(QualityPolicy.managedParserConfigKeys.contains(key), "缺少系统托管键：\(key)")
        }
    }

    // MARK: - 6. 解析器声明的能力（脚本 `registerBuiltinParser({ qualities: [...] })`）

    /// `parserDeclaresLossless`：将来「是否显示无损档」改由解析器声明驱动；
    /// 老脚本未声明（空集合）时必须为 false，调用方才能回落到书源能力判定。
    func testParserDeclaresLossless() {
        XCTAssertTrue(QualityPolicy.parserDeclaresLossless(["auto", "saver", "standard", "high", "lossless"]),
                      "脚本声明了 5 档语义能力 → 应认为其支持无损")
        XCTAssertTrue(QualityPolicy.parserDeclaresLossless(["lossless"]))
        XCTAssertFalse(QualityPolicy.parserDeclaresLossless(["auto", "saver", "standard", "high"]),
                       "未声明 lossless 的老脚本应返回 false")
        XCTAssertFalse(QualityPolicy.parserDeclaresLossless([]))
        XCTAssertFalse(QualityPolicy.parserDeclaresLossless(["flac"]),
                       "只认脚本声明口径的 'lossless'，不认码率名")
    }

    // MARK: - 7. A-4：按声明集合驱动可见档位、切档重载判定与设置页旧偏好兜底

    func testA4VisibleTiersFromDeclaredQualitiesSet() {
        XCTAssertEqual(
            QualityPolicy.visibleTiers(declaredQualities: ["auto", "saver", "standard", "high", "lossless"]),
            [.auto, .dataSaver, .standard, .high, .losslessHQ]
        )
        XCTAssertEqual(
            QualityPolicy.visibleTiers(declaredQualities: ["auto", "saver", "standard", "high"]),
            [.auto, .dataSaver, .standard, .high]
        )
        XCTAssertEqual(
            QualityPolicy.visibleTiers(declaredQualities: []),
            [.auto, .dataSaver, .standard, .high]
        )

        // 切档重载判定矩阵
        XCTAssertTrue(
            QualityPolicy.canReloadForTierChange(
                parserQualities: ["high", "lossless"],
                builtinParserResolved: true,
                isLocalOffline: false
            )
        )
        XCTAssertFalse(
            QualityPolicy.canReloadForTierChange(
                parserQualities: ["high", "lossless"],
                builtinParserResolved: true,
                isLocalOffline: true
            ),
            "本地离线音频切档不得重载在线流"
        )
        XCTAssertFalse(
            QualityPolicy.canReloadForTierChange(
                parserQualities: ["high", "lossless"],
                builtinParserResolved: false,
                isLocalOffline: false
            ),
            "当前章节未走内置解析时不得由解析器能力触发重载"
        )
        XCTAssertFalse(
            QualityPolicy.canReloadForTierChange(
                parserQualities: [],
                builtinParserResolved: true,
                isLocalOffline: false
            ),
            "解析器未声明能力集合时不得盲目触发重载"
        )
    }

    @MainActor
    func testA4SettingsPickerKeepsLegacyLosslessHQTag() {
        let kept = PlaybackPrefsView.pickerTiers(losslessAvailable: false, currentTier: .losslessHQ)
        XCTAssertEqual(
            kept,
            [.auto, .dataSaver, .standard, .high, .losslessHQ],
            "已选 losslessHQ 但当前无无损解析器时，必须保留 tag 避免 Picker 空白或改写偏好"
        )

        let narrowed = PlaybackPrefsView.pickerTiers(losslessAvailable: false, currentTier: .high)
        XCTAssertEqual(narrowed, [.auto, .dataSaver, .standard, .high])

        let withParser = PlaybackPrefsView.pickerTiers(losslessAvailable: true, currentTier: .losslessHQ)
        XCTAssertEqual(withParser, [.auto, .dataSaver, .standard, .high, .losslessHQ])
        XCTAssertEqual(withParser.filter { $0 == .losslessHQ }.count, 1)
    }
}
