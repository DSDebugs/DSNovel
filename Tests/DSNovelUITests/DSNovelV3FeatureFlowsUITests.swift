import XCTest

/// 离线黑盒核心功能链路 UI 测试（覆盖睡眠定时夜间/摇一摇选项、更多设置与音效/书签入口、书源一键检测与已失效筛选、播放偏好智能暂停回退）
final class DSNovelV3FeatureFlowsUITests: XCTestCase {
    @MainActor
    func testSleepTimerSheetNightAutoSleepAndShakeOptions() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let miniPlayer = app.buttons["miniplayer.root"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "主界面底部胶囊应展示迷你播放器入口")
        miniPlayer.tap()

        let sleepButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "睡眠定时")).firstMatch
        XCTAssertTrue(sleepButton.waitForExistence(timeout: 5), "全屏播放器应展示睡眠定时按钮")
        sleepButton.tap()

        XCTAssertTrue(
            app.staticTexts["睡眠定时"].waitForExistence(timeout: 5),
            "点击定时按钮后应弹出睡眠定时面板"
        )

        let nightAutoLabel = app.staticTexts["夜间自动定时"].firstMatch
        for _ in 0..<3 where !(nightAutoLabel.exists && nightAutoLabel.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(
            nightAutoLabel.waitForExistence(timeout: 4),
            "睡眠定时面板底部应展示夜间自动定时开关"
        )
    }

    @MainActor
    func testPlayerMoreSheetAudioEffectsAndBookmarkEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let miniPlayer = app.buttons["miniplayer.root"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "应展示迷你播放器入口")
        miniPlayer.tap()

        let moreButton = app.buttons["更多播放设置"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5), "全屏播放器顶栏应展示更多播放设置按钮")
        moreButton.tap()

        let effectsEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "音效增强")).firstMatch
        XCTAssertTrue(
            effectsEntry.waitForExistence(timeout: 5) || app.staticTexts["音效增强"].waitForExistence(timeout: 2),
            "更多播放设置应展示音效增强磁贴"
        )
        XCTAssertTrue(
            app.staticTexts["时间戳书签"].waitForExistence(timeout: 4),
            "更多播放设置应展示时间戳书签磁贴"
        )

        if effectsEntry.exists {
            effectsEntry.tap()
        } else {
            app.staticTexts["音效增强"].firstMatch.tap()
        }
        XCTAssertTrue(
            app.staticTexts["均衡器与音效"].waitForExistence(timeout: 5),
            "点击音效增强磁贴后应进入均衡器与音效面板"
        )
    }

    @MainActor
    func testSourceManagementHealthCheckButtonAndInvalidChip() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let meTab = app.buttons["tab_me"]
        XCTAssertTrue(meTab.waitForExistence(timeout: 5), "应展示我的 Tab 按钮")
        meTab.tap()

        let sourcesEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书源管理")).firstMatch
        XCTAssertTrue(sourcesEntry.waitForExistence(timeout: 5), "我的页应展示书源管理入口")
        sourcesEntry.tap()

        XCTAssertTrue(app.navigationBars["书源管理"].waitForExistence(timeout: 5), "应进入书源管理页面")

        let healthCheckBtn = app.buttons["source_list_health_check_button"].firstMatch
        let healthCheckFallback = app.buttons["一键检测全部书源"].firstMatch
        XCTAssertTrue(
            healthCheckBtn.waitForExistence(timeout: 4) || healthCheckFallback.waitForExistence(timeout: 2),
            "书源管理顶栏应展示一键检测按钮"
        )

        let invalidChip = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "已失效")).firstMatch
        XCTAssertTrue(invalidChip.waitForExistence(timeout: 4), "书源管理筛选栏应展示已失效分类标签")
        invalidChip.tap()

        let resetFilterButton = app.buttons["查看全部"].firstMatch
        if resetFilterButton.waitForExistence(timeout: 4) {
            resetFilterButton.tap()
        }
    }

    @MainActor
    func testPlaybackPreferencesSmartRewindControls() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let meTab = app.buttons["tab_me"]
        XCTAssertTrue(meTab.waitForExistence(timeout: 5), "应展示我的 Tab 按钮")
        meTab.tap()

        let prefsByID = app.buttons["me_playback_prefs_entry"].firstMatch
        let prefsFallback = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "更多播放偏好")).firstMatch
        let prefsText = app.staticTexts["更多播放偏好"].firstMatch
        XCTAssertTrue(
            prefsByID.waitForExistence(timeout: 4)
                || prefsFallback.waitForExistence(timeout: 2)
                || prefsText.waitForExistence(timeout: 2),
            "我的页应展示更多播放偏好入口"
        )
        if prefsByID.exists {
            prefsByID.tap()
        } else if prefsFallback.exists {
            prefsFallback.tap()
        } else {
            prefsText.tap()
        }

        XCTAssertTrue(
            app.navigationBars["播放偏好"].waitForExistence(timeout: 5),
            "点击更多播放偏好后应进入播放偏好页面"
        )

        let smartRewindTitle = app.staticTexts["智能暂停回退"].firstMatch
        for _ in 0..<3 where !(smartRewindTitle.exists && smartRewindTitle.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(
            smartRewindTitle.waitForExistence(timeout: 4),
            "播放偏好页应展示智能暂停回退设置分区"
        )
    }
}
