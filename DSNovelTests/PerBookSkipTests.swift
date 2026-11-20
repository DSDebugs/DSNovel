import XCTest
import SwiftData
@testable import DSNovel

final class PerBookSkipTests: XCTestCase {

    func testBookSkipConfigStatesClampingAndTogglePrefill() {
        let unset = BookSkipConfig.unset
        XCTAssertEqual(unset.state, .unset)
        XCTAssertEqual(unset.effectiveIntroSec, 0)
        XCTAssertEqual(unset.effectiveOutroSec, 0)
        XCTAssertEqual(unset.summaryText, "未设置")

        // 首次从未设置开启时预填 15s / 10s
        let enabledFirst = unset.toggled(to: true)
        XCTAssertEqual(enabledFirst.state, .on)
        XCTAssertEqual(enabledFirst.effectiveIntroSec, 15)
        XCTAssertEqual(enabledFirst.effectiveOutroSec, 10)
        XCTAssertEqual(enabledFirst.summaryText, "片头 15 秒 · 片尾 10 秒")

        // 关闭后保留时长，再次开启一键恢复
        let turnedOff = enabledFirst.toggled(to: false)
        XCTAssertEqual(turnedOff.state, .off)
        XCTAssertEqual(turnedOff.effectiveIntroSec, 0)
        XCTAssertEqual(turnedOff.effectiveOutroSec, 0)
        XCTAssertEqual(turnedOff.introSec, 15)
        XCTAssertEqual(turnedOff.outroSec, 10)
        XCTAssertEqual(turnedOff.summaryText, "已关闭")

        let reEnabled = turnedOff.toggled(to: true)
        XCTAssertEqual(reEnabled.state, .on)
        XCTAssertEqual(reEnabled.effectiveIntroSec, 15)
        XCTAssertEqual(reEnabled.effectiveOutroSec, 10)

        // 非法状态（开启但两项均为 0）自动规范化为未设置
        let invalid = BookSkipConfig(enabled: true, introSec: 0, outroSec: 0).normalized
        XCTAssertEqual(invalid, .unset)

        // 越界值夹取到 0...180
        let clamped = BookSkipConfig(enabled: true, introSec: -10, outroSec: 999)
        XCTAssertEqual(clamped.introSec, 0)
        XCTAssertEqual(clamped.outroSec, 180)
        XCTAssertEqual(clamped.summaryText, "片尾 180 秒")
    }

    func testStartPositionAndOutroTriggerRules() {
        let cfg = BookSkipConfig(enabled: true, introSec: 30, outroSec: 15)

        // 1. 有续播进度优先保留进度
        XCTAssertEqual(BookSkipConfig.startPositionSec(initialPositionMs: 45_000, duration: 300, config: cfg), 45.0, accuracy: 0.01)

        // 2. 新章按片头起播
        XCTAssertEqual(BookSkipConfig.startPositionSec(initialPositionMs: 0, duration: 300, config: cfg), 30.0, accuracy: 0.01)

        // 3. 短章保护：intro >= duration - 5 时不跳过
        XCTAssertEqual(BookSkipConfig.startPositionSec(initialPositionMs: 0, duration: 32, config: cfg), 0.0, accuracy: 0.01)

        // 4. 关闭时不跳过
        XCTAssertEqual(BookSkipConfig.startPositionSec(initialPositionMs: 0, duration: 300, config: cfg.toggled(to: false)), 0.0, accuracy: 0.01)

        // 5. 片尾触发：正常触发、单次触发保护、手动抑制、短章保护
        XCTAssertTrue(BookSkipConfig.shouldTriggerOutroSkip(positionSec: 285, durationSec: 300, config: cfg, hasTriggered: false, isSuppressed: false))
        XCTAssertFalse(BookSkipConfig.shouldTriggerOutroSkip(positionSec: 280, durationSec: 300, config: cfg, hasTriggered: false, isSuppressed: false))
        XCTAssertFalse(BookSkipConfig.shouldTriggerOutroSkip(positionSec: 286, durationSec: 300, config: cfg, hasTriggered: true, isSuppressed: false))
        XCTAssertFalse(BookSkipConfig.shouldTriggerOutroSkip(positionSec: 286, durationSec: 300, config: cfg, hasTriggered: false, isSuppressed: true))
        XCTAssertFalse(BookSkipConfig.shouldTriggerOutroSkip(positionSec: 40, durationSec: 50, config: cfg, hasTriggered: false, isSuppressed: false))
    }

    @MainActor
    func testPerBookSkipMigrationIdempotentAndFailureSafe() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let suiteName = "DSNovelSkipMigTest_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(20, forKey: PerBookSkipMigration.legacyIntroKey)
        defaults.set(10, forKey: PerBookSkipMigration.legacyOutroKey)

        let b1 = Book(id: "s::1", sourceID: "s", bookURL: "1", title: "有跳过书", skipIntroSec: 30, skipOutroSec: 0)
        let b2 = Book(id: "s::2", sourceID: "s", bookURL: "2", title: "零跳过书", skipIntroSec: 0, skipOutroSec: 0)
        ctx.insert(b1)
        ctx.insert(b2)
        try ctx.save()

        // 1. 保存失败时不写完成标记，允许下次重试
        struct DummySaveError: Error {}
        let failed = PerBookSkipMigration.runIfNeeded(context: ctx, defaults: defaults) { _ in
            throw DummySaveError()
        }
        XCTAssertFalse(failed)
        XCTAssertFalse(defaults.bool(forKey: PerBookSkipMigration.completedKey))

        // 2. 正常迁移：保留原有数值并按 >0 设置 skipEnabled，清理遗留键并生成一次提示
        let ran = PerBookSkipMigration.runIfNeeded(context: ctx, defaults: defaults)
        XCTAssertTrue(ran)
        XCTAssertTrue(b1.skipEnabled)
        XCTAssertEqual(b1.skipIntroSec, 30)
        XCTAssertFalse(b2.skipEnabled)
        XCTAssertEqual(b2.skipIntroSec, 0)
        XCTAssertNil(defaults.object(forKey: PerBookSkipMigration.legacyIntroKey))
        XCTAssertNil(defaults.object(forKey: PerBookSkipMigration.legacyOutroKey))
        XCTAssertNotNil(PerBookSkipMigration.consumePendingNoticeIfNeeded(defaults: defaults))
        XCTAssertNil(PerBookSkipMigration.consumePendingNoticeIfNeeded(defaults: defaults))

        // 3. 再次运行幂等
        let ranAgain = PerBookSkipMigration.runIfNeeded(context: ctx, defaults: defaults)
        XCTAssertFalse(ranAgain)
    }

    @MainActor
    func testPlayerEnginePerBookSkipUpsertAndIsolation() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let engine = PlayerEngine()
        engine.useFakeBackend = true
        engine.modelContext = ctx

        let bookA = BookRef(sourceID: "s1", bookURL: "uA", title: "书 A")
        let bookB = BookRef(sourceID: "s1", bookURL: "uB", title: "书 B")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/1", durationSec: 600)

        engine.startPlayback(book: bookA, chapters: [ch], startChapter: ch)
        XCTAssertEqual(engine.bookSkip, .unset)

        // 更新书 A 并验证持久落库（即使最初无 Book 行也会 upsert）
        XCTAssertTrue(engine.updateBookSkip(BookSkipConfig(enabled: true, introSec: 25, outroSec: 15)))
        XCTAssertEqual(engine.bookSkip.effectiveIntroSec, 25)

        // 切到书 B：应为未设置，不受书 A 影响
        engine.startPlayback(book: bookB, chapters: [ch], startChapter: ch)
        XCTAssertEqual(engine.bookSkip, .unset)

        // 切回书 A：应恢复 25/15
        engine.startPlayback(book: bookA, chapters: [ch], startChapter: ch)
        XCTAssertEqual(engine.bookSkip.effectiveIntroSec, 25)
        XCTAssertEqual(engine.bookSkip.effectiveOutroSec, 15)
    }

    func testAuthorInfoAndDynamicVersion() {
        XCTAssertEqual(AuthorInfo.name, "DS")
        XCTAssertEqual(AuthorInfo.initials, "DS")
        XCTAssertEqual(AuthorInfo.role, "设计与开发")
        XCTAssertFalse(AuthorInfo.appVersionDisplay.isEmpty)
    }
}
