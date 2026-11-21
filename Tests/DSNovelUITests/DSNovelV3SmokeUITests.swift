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
        let searchTab = app.buttons["tab_search"]
        let libraryTab = app.buttons["tab_library"]
        let meTab = app.buttons["tab_me"]

        // 1. 发现 Tab
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 5), "应直接进入主界面并展示发现 Tab 按钮")
        discoverTab.tap()
        XCTAssertTrue(
            app.otherElements["discover_root"].waitForExistence(timeout: 5)
                || app.scrollViews["discover_root"].waitForExistence(timeout: 2),
            "切换至发现页后 discover_root 应存在"
        )

        // 2. 搜索 Tab 与输入框交互
        XCTAssertTrue(searchTab.waitForExistence(timeout: 3), "应展示搜索 Tab 按钮")
        searchTab.tap()
        XCTAssertTrue(
            app.otherElements["search_root"].waitForExistence(timeout: 5)
                || app.scrollViews["search_root"].waitForExistence(timeout: 2),
            "切换至搜索页后 search_root 应存在"
        )
        let searchField = app.textFields["搜索书名、作者或演播"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "搜索页应展示搜索输入框")
        searchField.tap()
        searchField.typeText("三体")
        XCTAssertEqual(searchField.value as? String, "三体", "搜索框应正确响应文本输入")
        XCTAssertTrue(app.buttons["搜索"].exists, "搜索页应展示搜索按钮")

        // 3. 书籍 Tab
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 3), "应展示书籍 Tab 按钮")
        libraryTab.tap()
        XCTAssertTrue(
            app.otherElements["library_root"].waitForExistence(timeout: 5)
                || app.scrollViews["library_root"].waitForExistence(timeout: 2),
            "切换至书架页后 library_root 应存在"
        )

        // 4. 我的 Tab 与下载管理入口
        XCTAssertTrue(meTab.waitForExistence(timeout: 3), "应展示我的 Tab 按钮")
        meTab.tap()
        XCTAssertTrue(
            app.otherElements["me_root"].waitForExistence(timeout: 5)
                || app.tables["me_root"].waitForExistence(timeout: 2)
                || app.collectionViews["me_root"].waitForExistence(timeout: 2),
            "切换至我的页后 me_root 应存在"
        )
        let downloadsEntry = app.buttons["下载管理"].firstMatch
        let downloadsLabel = app.staticTexts["下载管理"].firstMatch
        XCTAssertTrue(
            downloadsEntry.waitForExistence(timeout: 5) || downloadsLabel.waitForExistence(timeout: 2),
            "我的页应展示下载管理入口"
        )
        XCTAssertTrue(
            app.staticTexts["书源管理"].waitForExistence(timeout: 3),
            "我的页应展示书源管理入口"
        )
        if downloadsEntry.exists {
            downloadsEntry.tap()
        } else {
            downloadsLabel.tap()
        }
        XCTAssertTrue(
            app.navigationBars["下载管理"].waitForExistence(timeout: 5)
                && app.segmentedControls.firstMatch.waitForExistence(timeout: 3),
            "点击下载管理入口后应进入下载管理页面并展示独有导航栏与分段控件"
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

        // 解锁前不应展示内置音频解析器入口
        XCTAssertFalse(
            app.staticTexts["内置音频解析器"].exists,
            "重置状态下我的页不应预先显示内置音频解析器入口"
        )

        // 进入关于 DSNovel 页面
        let aboutButton = app.buttons["关于 DSNovel"].firstMatch
        let aboutLabel = app.staticTexts["关于 DSNovel"].firstMatch
        XCTAssertTrue(
            aboutButton.waitForExistence(timeout: 5) || aboutLabel.waitForExistence(timeout: 2),
            "我的页应展示关于 DSNovel 入口"
        )
        if aboutButton.exists {
            aboutButton.tap()
        } else {
            aboutLabel.tap()
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
            NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "内置解析器", "失败")
        ).firstMatch
        XCTAssertTrue(unlockedBanner.waitForExistence(timeout: 6), "三连击版本号后应提示已解锁并加载内置解析器且不包含失败字样")

        // 返回我的页，验证内置音频解析器入口已解锁展示
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 3), "关于页应展示返回按钮")
        backButton.tap()

        let parserEntryButton = app.buttons["内置音频解析器"].firstMatch
        let parserEntryLabel = app.staticTexts["内置音频解析器"].firstMatch
        XCTAssertTrue(
            parserEntryButton.waitForExistence(timeout: 5) || parserEntryLabel.waitForExistence(timeout: 2),
            "三连击解锁后返回我的页应展示内置音频解析器入口"
        )
    }
}
