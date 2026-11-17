import XCTest
import SwiftUI
import UIKit
@testable import DSNovel

final class DesignSystemTests: XCTestCase {

    // MARK: - T1-01 & T6-02 颜色令牌与对比度 (≥ 4.5:1)

    func testColorTokenValuesAndContrastRatios() {
        let lightContrast = DSColorTokenSpec.RGB.contrastRatio(
            DSColorTokenSpec.accentLight,
            DSColorTokenSpec.onAccentLight
        )
        let darkContrast = DSColorTokenSpec.RGB.contrastRatio(
            DSColorTokenSpec.accentDark,
            DSColorTokenSpec.onAccentDark
        )
        let nightDimContrast = DSColorTokenSpec.RGB.contrastRatio(
            DSColorTokenSpec.accentNightDim,
            DSColorTokenSpec.onAccentDark
        )

        XCTAssertGreaterThanOrEqual(lightContrast, 4.5, "浅色模式强调色对比度应 ≥ 4.5")
        XCTAssertGreaterThanOrEqual(darkContrast, 4.5, "深色模式强调色对比度应 ≥ 4.5")
        XCTAssertGreaterThanOrEqual(nightDimContrast, 4.5, "夜间降亮模式强调色对比度应 ≥ 4.5")

        let normalDarkBase = DSColorTokenSpec.resolveSurfaceBase(isDark: true, nightDim: false)
        let dimDarkBase = DSColorTokenSpec.resolveSurfaceBase(isDark: true, nightDim: true)
        XCTAssertLessThan(dimDarkBase.relativeLuminance, normalDarkBase.relativeLuminance)
    }

    // MARK: - T1-02 Motion.resolve 分支测试

    func testMotionResolveBranches() {
        let normal = Motion.resolve(Motion.snappy, reduce: false)
        let reduced = Motion.resolve(Motion.snappy, reduce: true)
        XCTAssertEqual(normal, Motion.snappy)
        XCTAssertEqual(reduced, .easeOut(duration: 0.15))
    }

    // MARK: - T1-03 & T5-12 触感去重与总开关测试

    func testHapticPolicyDeduplicationAndSwitch() {
        let policy = DSHapticPolicy()
        policy.reset()

        // 关闭开关时全部不触发
        for kind in DSHapticKind.allCases {
            XCTAssertFalse(policy.shouldTrigger(kind, hapticsEnabled: false, now: 100.0))
        }

        // 错误触感 3 秒内去重
        XCTAssertTrue(policy.shouldTrigger(.error, hapticsEnabled: true, now: 100.0))
        XCTAssertFalse(policy.shouldTrigger(.error, hapticsEnabled: true, now: 101.5))
        XCTAssertTrue(policy.shouldTrigger(.error, hapticsEnabled: true, now: 103.1))

        // 进度条整分钟刻度 150ms 间隔去重
        XCTAssertTrue(policy.shouldTrigger(.scrubberMinuteTick, hapticsEnabled: true, now: 200.0))
        XCTAssertFalse(policy.shouldTrigger(.scrubberMinuteTick, hapticsEnabled: true, now: 200.05))
        XCTAssertTrue(policy.shouldTrigger(.scrubberMinuteTick, hapticsEnabled: true, now: 200.20))
    }

    // MARK: - T1-04 封面主色提取：红、蓝、纯白、纯黑、灰度、单像素图

    private func makeSolidImage(color: UIColor, size: CGSize = CGSize(width: 16, height: 16)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testCoverAmbientColorExtractionAllCases() {
        let redImg = makeSolidImage(color: .red)
        let blueImg = makeSolidImage(color: .blue)
        let whiteImg = makeSolidImage(color: .white)
        let blackImg = makeSolidImage(color: .black)
        let grayImg = makeSolidImage(color: .gray)
        let onePxImg = makeSolidImage(color: .orange, size: CGSize(width: 1, height: 1))

        for (idx, img) in [redImg, blueImg, whiteImg, blackImg, grayImg, onePxImg].enumerated() {
            let res = CoverAmbientColor.extract(from: img, cacheKey: "test_color_\(idx)")
            XCTAssertLessThanOrEqual(res.brightness, 0.45, "主色必须压低亮度以保证白字对比度")
            XCTAssertGreaterThanOrEqual(res.brightness, 0.10, "纯黑或极端图也必须返回可用深色基底")
        }
    }

    func testDSCoverBadgePriorityLimitTwo() {
        let badges: [DSCoverBadge] = [.vip, .updated, .downloaded, .progress(0.5)]
        let topTwo = DSCover.topTwoBadges(badges)
        XCTAssertEqual(topTwo, [.progress(0.5), .downloaded])
    }

    // MARK: - T1-07 DSStateView 文案 ≤ 30 字、错误映射、骨架屏延迟与停留

    func testDSStateCopyLengthAndErrorMapping() {
        let allStates: [DSStateKind] = [
            .loading,
            .empty,
            .error(detail: "timeout"),
            .needLogin(sourceName: "博看有声"),
            .needVerify,
            .vipChapter,
            .offline,
            .noSource
        ]
        for st in allStates {
            XCTAssertLessThanOrEqual(st.message.count, 30, "状态说明必须 ≤ 30 字: \(st.message)")
        }

        XCTAssertEqual(UserFacingError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(UserFacingError.from(PluginError.needLogin(sourceID: "s1", loginURL: "")), .needLogin(sourceName: "当前书源"))
        XCTAssertEqual(UserFacingError.from(PluginError.needVerify(sourceID: "s1", verifyURL: "")), .needVerify)
        XCTAssertEqual(UserFacingError.from(PluginError.vipRequired(sourceID: "s1")), .vipChapter)
    }

    func testSkeletonVisibilityDelayAndMinimumStay() {
        // 加载未满 200ms 不显示
        XCTAssertFalse(DSSkeletonVisibilityPolicy.shouldShow(elapsedLoadingMs: 120, isStillLoading: true, shownAtMs: nil))
        // 加载达 200ms 显示
        XCTAssertTrue(DSSkeletonVisibilityPolicy.shouldShow(elapsedLoadingMs: 220, isStillLoading: true, shownAtMs: 200))
        // 刚显示 150ms 即加载完成，仍需保持到满 400ms
        XCTAssertTrue(DSSkeletonVisibilityPolicy.shouldShow(elapsedLoadingMs: 350, isStillLoading: false, shownAtMs: 200))
        // 已满 400ms 后消失
        XCTAssertFalse(DSSkeletonVisibilityPolicy.shouldShow(elapsedLoadingMs: 650, isStillLoading: false, shownAtMs: 200))
    }

    // MARK: - T1-08 BannerCenter 撤销/提交互斥、去重与错误优先级

    @MainActor
    func testBannerCenterUndoAndCommitExclusivity() {
        let center = BannerCenter.shared
        center.resetForTesting()

        var undoCount = 0
        var commitCount = 0

        // 1. 点击撤销：只调用 onUndo，到期不再调用 onCommit
        center.showUndo("移出书架 1", now: 100, scheduleAutoDismiss: false) {
            undoCount += 1
        } onCommit: {
            commitCount += 1
        }
        let firstID = center.currentBanner?.id
        center.triggerUndo()
        if let firstID { center.expireIfMatching(id: firstID) }
        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(commitCount, 0)

        // 2. 被新消息替换：立即触发上一条的 onCommit
        center.showUndo("移出书架 2", now: 110, scheduleAutoDismiss: false) {
            undoCount += 1
        } onCommit: {
            commitCount += 1
        }
        center.show("新提示", kind: .info, now: 111, scheduleAutoDismiss: false)
        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(commitCount, 1)

        // 3. 进入后台：立即触发 onCommit
        center.showUndo("移出书架 3", now: 120, scheduleAutoDismiss: false) {
            undoCount += 1
        } onCommit: {
            commitCount += 1
        }
        center.handleDidEnterBackground()
        XCTAssertEqual(commitCount, 2)

        // 4. 错误优先：当前为 error 时，普通 info 不覆盖
        center.show("严重错误", kind: .error, now: 130, scheduleAutoDismiss: false)
        center.show("普通信息", kind: .info, now: 131, scheduleAutoDismiss: false)
        XCTAssertEqual(center.currentBanner?.message, "严重错误")

        center.resetForTesting()
    }

    // MARK: - T1-09 & T5-03 & T5-13 DSScrubber 与播放器动效决策函数

    func testScrubberFineDragAndMinuteTick() {
        let normalTarget = DSScrubberLogic.mapDragDelta(
            startSeconds: 100,
            deltaRatio: 0.2,
            durationSeconds: 1000,
            isFineScrubbing: false
        )
        let fineTarget = DSScrubberLogic.mapDragDelta(
            startSeconds: 100,
            deltaRatio: 0.2,
            durationSeconds: 1000,
            isFineScrubbing: true
        )
        XCTAssertEqual(normalTarget, 300, accuracy: 0.01)
        XCTAssertEqual(fineTarget, 150, accuracy: 0.01)

        XCTAssertFalse(DSScrubberLogic.crossedWholeMinute(from: 10, to: 59))
        XCTAssertTrue(DSScrubberLogic.crossedWholeMinute(from: 59, to: 61))
    }

    func testPlayerAmbientFallbackAndCoverScale() {
        XCTAssertTrue(PlayerAmbientFallbackPolicy.shouldUseStaticGradient(isLowPowerMode: true, reduceMotion: false))
        XCTAssertTrue(PlayerAmbientFallbackPolicy.shouldUseStaticGradient(isLowPowerMode: false, reduceMotion: true))
        XCTAssertFalse(PlayerAmbientFallbackPolicy.shouldUseStaticGradient(isLowPowerMode: false, reduceMotion: false))

        XCTAssertEqual(PlayerAmbientFallbackPolicy.coverScale(for: .playing, isPressed: false, reduceMotion: false), 1.0)
        XCTAssertEqual(PlayerAmbientFallbackPolicy.coverScale(for: .paused, isPressed: false, reduceMotion: false), 0.86)
        XCTAssertEqual(PlayerAmbientFallbackPolicy.coverScale(for: .paused, isPressed: false, reduceMotion: true), 1.0)
    }
}
