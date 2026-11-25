import XCTest

final class DSNovelV3SmokeUITests: XCTestCase {
    @MainActor
    func testOnboardingFlowAndCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET", "DSNOVEL_UITEST_SHOW_ONBOARDING"]
        app.launch()

        let welcomeTitle = app.staticTexts["欢迎使用 DSNovel v3"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5), "开启引导参数后应展示欢迎标题")

        let onboardingButton = app.buttons["onboarding_start_button"]
        XCTAssertTrue(onboardingButton.waitForExistence(timeout: 5), "引导页应展示开始听书按钮")
        onboardingButton.tap()

        let discoverTab = app.buttons["tab_discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 5), "完成引导后应进入主界面并展示发现 Tab")
        XCTAssertTrue(
            app.otherElements["discover_root"].waitForExistence(timeout: 5)
                || app.scrollViews["discover_root"].waitForExistence(timeout: 2),
            "完成引导后 discover_root 应可见"
        )
    }

    @MainActor
    func testPortraitLaunchAndTabNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let discoverTab = app.buttons["tab_discover"]
        let libraryTab = app.buttons["tab_library"]
        let meTab = app.buttons["tab_me"]

        // 1. 首页 Tab（融合发现 + 四态聚合搜索）
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 5), "应直接进入主界面并展示首页 Tab 按钮")
        discoverTab.tap()
        XCTAssertTrue(
            app.otherElements["discover_root"].waitForExistence(timeout: 5)
                || app.scrollViews["discover_root"].waitForExistence(timeout: 2),
            "切换至首页后 discover_root 应存在"
        )

        // 2. 首页原地融合搜索交互（点击搜索框进入搜索态、输入触发实时联想、取消返回浏览态）
        let searchFieldByID = app.textFields["discover.searchField"]
        let searchFieldByPrompt = app.textFields["搜索书名、作者或演播"]
        let searchField = searchFieldByID.waitForExistence(timeout: 5) ? searchFieldByID : searchFieldByPrompt
        XCTAssertTrue(searchField.exists, "首页应展示融合搜索输入框")
        searchField.tap()
        XCTAssertTrue(
            app.otherElements["search_root"].waitForExistence(timeout: 5)
                || app.scrollViews["search_root"].waitForExistence(timeout: 2),
            "聚焦搜索框后应原地展开融合搜索视图"
        )
        searchField.typeText("三体")
        XCTAssertEqual(searchField.value as? String, "三体", "搜索框应正确响应文本输入")
        let cancelBtn = app.buttons["discover.searchCancel"].exists ? app.buttons["discover.searchCancel"] : app.buttons["取消"]
        XCTAssertTrue(cancelBtn.exists, "搜索框聚焦输入后应展示取消按钮")
        cancelBtn.tap()

        // 3. 书籍 Tab
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 3), "应展示书籍 Tab 按钮")
        libraryTab.tap()
        XCTAssertTrue(
            app.otherElements["library_root"].waitForExistence(timeout: 5)
                || app.scrollViews["library_root"].waitForExistence(timeout: 2),
            "切换至书架页后 library_root 应存在"
        )

        // 4. 我的 Tab -> 存储管理 -> 下载管理入口（外层不再显示下载管理与脱敏诊断日志）
        XCTAssertTrue(meTab.waitForExistence(timeout: 3), "应展示我的 Tab 按钮")
        meTab.tap()
        XCTAssertTrue(
            app.otherElements["me_root"].waitForExistence(timeout: 5)
                || app.tables["me_root"].waitForExistence(timeout: 2)
                || app.collectionViews["me_root"].waitForExistence(timeout: 2),
            "切换至我的页后 me_root 应存在"
        )
        XCTAssertTrue(
            app.staticTexts["书源管理"].waitForExistence(timeout: 3),
            "我的页应展示书源管理入口"
        )
        XCTAssertFalse(
            app.staticTexts["脱敏诊断日志"].exists || app.staticTexts["下载管理"].exists,
            "我的页外层不应再展示脱敏诊断日志或下载管理入口"
        )
        let storageEntry = app.buttons["me_storage_entry"].firstMatch
        let storageLabel = app.staticTexts["存储管理"].firstMatch
        for _ in 0..<3 {
            if (storageEntry.exists && storageEntry.isHittable) || (storageLabel.exists && storageLabel.isHittable) {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(
            storageEntry.waitForExistence(timeout: 4) || storageLabel.waitForExistence(timeout: 2),
            "我的页应展示存储管理入口"
        )
        if storageEntry.exists {
            storageEntry.tap()
        } else {
            storageLabel.tap()
        }
        XCTAssertTrue(
            app.navigationBars["存储管理"].waitForExistence(timeout: 5),
            "点击存储管理入口后应进入存储管理页面"
        )
        let downloadsEntry = app.buttons["storage_downloads_entry"].firstMatch
        let downloadsLabel = app.staticTexts["下载管理"].firstMatch
        XCTAssertTrue(
            downloadsEntry.waitForExistence(timeout: 4) || downloadsLabel.waitForExistence(timeout: 2),
            "存储管理页内应展示下载管理入口"
        )
        if downloadsEntry.exists {
            downloadsEntry.tap()
        } else {
            downloadsLabel.tap()
        }
        XCTAssertTrue(
            app.navigationBars["下载管理"].waitForExistence(timeout: 5)
                && app.staticTexts["存储概览"].waitForExistence(timeout: 3),
            "点击存储管理中的下载管理入口后应进入下载管理页面并展示存储概览卡片"
        )
    }

    @MainActor
    func testAboutVersionTripleTapUnlocksBuiltinParserEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let meTab = app.buttons["tab_me"]
        XCTAssertTrue(meTab.waitForExistence(timeout: 5), "应展示我的 Tab 按钮")
        meTab.tap()
        XCTAssertTrue(
            app.otherElements["me_root"].waitForExistence(timeout: 5)
                || app.tables["me_root"].waitForExistence(timeout: 2)
                || app.collectionViews["me_root"].waitForExistence(timeout: 2),
            "切换至我的页后 me_root 应存在"
        )

        // 解锁前我的页不应展示内置音频解析器或音频解析入口
        XCTAssertFalse(
            app.staticTexts["内置音频解析器"].exists || app.staticTexts["音频解析"].exists,
            "我的页不应显示内置音频解析器或音频解析入口"
        )

        // 进入关于 DSNovel 页面（v2.8 我的页内容较长，关于分组位于底部，先向上滑屏露出入口）
        let aboutByID = app.buttons["me_about_entry"].firstMatch
        let aboutByLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "关于 DSNovel")).firstMatch
        let aboutText = app.staticTexts["关于 DSNovel"].firstMatch
        for _ in 0..<4 {
            if (aboutByID.exists && aboutByID.isHittable)
                || (aboutByLabel.exists && aboutByLabel.isHittable)
                || (aboutText.exists && aboutText.isHittable) {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(
            aboutByID.waitForExistence(timeout: 4)
                || aboutByLabel.waitForExistence(timeout: 2)
                || aboutText.waitForExistence(timeout: 2),
            "我的页应展示关于 DSNovel 入口"
        )
        if aboutByID.exists {
            aboutByID.tap()
        } else if aboutByLabel.exists {
            aboutByLabel.tap()
        } else {
            aboutText.tap()
        }
        XCTAssertTrue(
            app.navigationBars["关于 DSNovel"].waitForExistence(timeout: 5),
            "点击关于入口后应进入关于 DSNovel 页面"
        )

        // 1.2 秒内连续三击版本号按钮（about_version_label）
        let versionButton = app.buttons["about_version_label"].firstMatch
        XCTAssertTrue(versionButton.waitForExistence(timeout: 5), "关于页应展示 about_version_label 版本号按钮")
        versionButton.tap(withNumberOfTaps: 3, numberOfTouches: 1)

        // 等待顶部解锁成功提示横幅出现（确保异步激活与 settings.builtinParserUnlocked = true 完成，且排除失败提示）
        let unlockedBanner = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "音频解析", "失败")
        ).firstMatch
        XCTAssertTrue(unlockedBanner.waitForExistence(timeout: 6), "三连击版本号后应提示已开启音频解析入口且不包含失败字样")

        // 返回我的页，验证我的页不展示音频解析入口，并进入书源管理 -> 喜马拉雅验证唯一入口
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 3), "关于页应展示返回按钮")
        backButton.tap()

        XCTAssertFalse(
            app.buttons["me_builtin_parser_entry"].exists || app.staticTexts["内置音频解析器"].exists,
            "我的页不应展示内置音频解析器入口"
        )

        // 向上滚回顶部并进入书源管理
        for _ in 0..<3 {
            if app.staticTexts["书源管理"].isHittable { break }
            app.swipeDown()
        }
        let sourcesEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书源管理")).firstMatch
        XCTAssertTrue(sourcesEntry.waitForExistence(timeout: 4), "我的页应展示书源管理入口")
        sourcesEntry.tap()
        XCTAssertTrue(app.navigationBars["书源管理"].waitForExistence(timeout: 5), "应进入书源管理页面")

        XCTAssertFalse(
            app.staticTexts["内置音频解析器"].exists,
            "书源管理列表页不应展示内置音频解析器入口"
        )

        let xmlyRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "喜马拉雅")).firstMatch
        XCTAssertTrue(xmlyRow.waitForExistence(timeout: 5), "书源管理页应展示喜马拉雅书源")
        xmlyRow.tap()

        let parserByID = app.buttons["ximalaya_audio_parser_entry"].firstMatch
        let parserText = app.staticTexts["音频解析"].firstMatch
        XCTAssertTrue(
            parserByID.waitForExistence(timeout: 5) || parserText.waitForExistence(timeout: 2),
            "三连击解锁后喜马拉雅书源详情页应展示唯一音频解析入口"
        )
    }

    @MainActor
    func testMiniPlayerOpensBorderlessPlayerAndSpeedSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["DSNOVEL_UITEST", "DSNOVEL_UITEST_RESET"]
        app.launch()

        let miniPlayer = app.buttons["miniplayer.root"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "主界面底部胶囊应展示迷你播放器入口")
        miniPlayer.tap()

        let dismissButton = app.buttons["收起播放器"].firstMatch
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5), "点击迷你播放器后应展开全屏播放器并展示收起按钮")

        let speedButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "播放倍速")).firstMatch
        XCTAssertTrue(speedButton.waitForExistence(timeout: 4), "全屏播放器底部无框栏应展示倍速按钮")
        speedButton.tap()

        XCTAssertTrue(
            app.staticTexts["常用倍速"].waitForExistence(timeout: 5),
            "点击倍速按钮后应展开统一暗色卡片风格的倍速调节弹窗"
        )
    }
}
