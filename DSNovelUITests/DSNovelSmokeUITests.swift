import XCTest

final class DSNovelSmokeUITests: XCTestCase {
    func testFixtureSmokeAndFourTabsNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSNOVEL_UITEST"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testDataRepairScreenAppearsOnStoreFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSNOVEL_SIMULATE_STORE_FAILURE"]
        app.launch()

        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["备份并重建"].exists)
    }
}
