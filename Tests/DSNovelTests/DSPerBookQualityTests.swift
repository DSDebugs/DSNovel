import DSCore
import DSStorage
import Foundation
import Testing
@testable import DSNovel

@Suite("DSPerBookQuality 喜马拉雅来源判定、单书音质记忆与码率映射测试")
struct DSPerBookQualityTests {
    @Test("AppSettingsStore 单书音质默认自适应且互不干扰")
    @MainActor
    func perBookQualityIsolation() {
        let suiteName = "dsnovel.test.perbookquality.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        #expect(store.quality(forBookID: "book-a") == .auto)
        #expect(store.quality(forBookID: "book-b") == .auto)

        store.setQuality(.standard, forBookID: "book-a")
        #expect(store.quality(forBookID: "book-a") == .standard)
        #expect(store.quality(forBookID: "book-b") == .auto)

        store.setQuality(.saver, forBookID: "book-b")
        #expect(store.quality(forBookID: "book-a") == .standard)
        #expect(store.quality(forBookID: "book-b") == .saver)

        // 重建实例验证持久化
        let reloaded = AppSettingsStore(defaults: defaults)
        #expect(reloaded.quality(forBookID: "book-a") == .standard)
        #expect(reloaded.quality(forBookID: "book-b") == .saver)

        // 切回自适应与全局清空
        reloaded.setQuality(.auto, forBookID: "book-a")
        #expect(reloaded.quality(forBookID: "book-a") == .auto)
        reloaded.clearBookQualities()
        #expect(reloaded.quality(forBookID: "book-b") == .auto)
    }

    @Test("AppContainer 仅对喜马拉雅来源书籍启用音质并按单书记忆解析")
    @MainActor
    func ximalayaOnlyGatingAndResolvedQuality() {
        let container = AppContainer(inMemoryOnly: true)
        let xmBook = BookSummaryDTO(
            id: "xm-1",
            sourceID: AppContainer.ximalayaSourceID,
            sourceName: "喜马拉雅",
            bookURL: "https://www.ximalaya.com/album/123",
            title: "青山"
        )
        let otherBook = BookSummaryDTO(
            id: "ty-1",
            sourceID: "a6d1c3f08b2e4759b8e0f4a27c915d36",
            sourceName: "听友听书",
            bookURL: "https://tingyou.fm/listening/album/1",
            title: "剑来"
        )

        #expect(container.isXimalayaBook(xmBook))
        #expect(!container.isXimalayaBook(otherBook))
        #expect(!container.isCurrentBookFromXimalaya)

        // 默认均为自适应
        #expect(container.resolvedQuality(for: xmBook) == .auto)
        #expect(container.resolvedQuality(for: otherBook) == .auto)

        // 调整喜马拉雅书籍音质后仅影响该书，非喜马拉雅仍返回 .auto
        container.settings.setQuality(.saver, forBookID: xmBook.id)
        container.settings.setQuality(.saver, forBookID: otherBook.id)
        #expect(container.resolvedQuality(for: xmBook) == .saver)
        #expect(container.resolvedQuality(for: otherBook) == .auto)
    }

    @Test("AudioQualityTier.fromBitrateKbps 边界阈值与全局无 k 后缀展示名")
    func bitrateMappingAndConciseBadges() {
        #expect(AudioQualityTier.fromBitrateKbps(-10) == .standard)
        #expect(AudioQualityTier.fromBitrateKbps(0) == .standard)
        #expect(AudioQualityTier.fromBitrateKbps(1) == .saver)
        #expect(AudioQualityTier.fromBitrateKbps(24) == .saver)
        #expect(AudioQualityTier.fromBitrateKbps(41) == .saver)
        #expect(AudioQualityTier.fromBitrateKbps(42) == .standard)
        #expect(AudioQualityTier.fromBitrateKbps(64) == .standard)
        #expect(AudioQualityTier.fromBitrateKbps(89) == .standard)
        #expect(AudioQualityTier.fromBitrateKbps(90) == .high)
        #expect(AudioQualityTier.fromBitrateKbps(128) == .high)

        for tier in AudioQualityTier.allCases {
            #expect(!tier.displayName.lowercased().contains("k"))
        }

        let stubURL = URL(fileURLWithPath: "/tmp/sample.m4a")
        let autoWithBitrate = AudioStreamDTO(url: stubURL, qualityTier: .auto, bitrateKbps: 128)
        let autoWithoutBitrate = AudioStreamDTO(url: stubURL, qualityTier: .auto, bitrateKbps: nil)
        let explicitHigh = AudioStreamDTO(url: stubURL, qualityTier: .high, bitrateKbps: 96)

        #expect(autoWithBitrate.displayBitrateBadge == "超清")
        #expect(autoWithoutBitrate.displayBitrateBadge == "自适应")
        #expect(explicitHigh.displayBitrateBadge == "超清")
    }
}
