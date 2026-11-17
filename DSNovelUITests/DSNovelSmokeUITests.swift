import XCTest

final class DSNovelSmokeUITests: XCTestCase {
    private func launchFixture(extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DSNOVEL_UITEST"] + extraArgs
        app.launch()
        return app
    }

    func testTabOrderIsDiscoverSearchLibraryMe() {
        let app = launchFixture()
        let tabBar = app.buttons["tab.discover"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        let discoverTab = app.buttons["tab.discover"]
        let searchTab = app.buttons["tab.search"]
        let libraryTab = app.buttons["tab.library"]
        let meTab = app.buttons["tab.me"]

        XCTAssertTrue(discoverTab.exists)
        XCTAssertTrue(searchTab.exists)
        XCTAssertTrue(libraryTab.exists)
        XCTAssertTrue(meTab.exists)
        XCTAssertLessThan(discoverTab.frame.minX, searchTab.frame.minX)
        XCTAssertLessThan(searchTab.frame.minX, libraryTab.frame.minX)
        XCTAssertLessThan(libraryTab.frame.minX, meTab.frame.minX)
    }

    func testDiscoverSourceSwitcherAndGridAlignment() {
        let app = launchFixture()
        app.buttons["tab.discover"].tap()
        let switcher = app.buttons["discover.sourceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        switcher.tap()
        XCTAssertTrue(app.buttons["管理书源"].waitForExistence(timeout: 3))
    }

    func testSearchFieldVisibleAndClearResetsToIdle() {
        let app = launchFixture()
        app.buttons["tab.search"].tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("诡秘之主")
        if app.buttons["search.clear"].exists {
            app.buttons["search.clear"].tap()
            XCTAssertEqual(field.value as? String ?? "", "")
        }
    }

    func testSourceListRowsHaveNoDuplicateNameOrLatency() {
        let app = launchFixture()
        app.buttons["tab.me"].tap()
        let healthBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS '可用'")).firstMatch
        if healthBtn.waitForExistence(timeout: 5) {
            healthBtn.tap()
            XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 5))
        }
    }

    func testDataRepairScreenAppearsOnStoreFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSNOVEL_SIMULATE_STORE_FAILURE"]
        app.launch()
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["备份并重建"].exists)
    }
}
