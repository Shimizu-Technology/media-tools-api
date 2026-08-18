import XCTest

final class MediaToolsUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testRecordScreenExposesAccessiblePrimaryActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-record"]
        app.launch()

        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["00:00"].exists)

        let upload = app.buttons["Upload Audio File"]
        XCTAssertTrue(upload.exists)
        if !upload.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(upload.isHittable)
    }

    func testLibrarySupportsTypedSelectionAndResponsiveActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search all media"].exists)
        XCTAssertTrue(app.buttons["All"].isHittable)
        XCTAssertTrue(app.buttons["PDFs"].isHittable)
        XCTAssertTrue(app.staticTexts["Weekly product review"].exists)
        XCTAssertTrue(app.staticTexts["Team planning session.m4a"].exists)

        app.buttons["Library actions"].tap()
        XCTAssertTrue(app.buttons["Select Items"].waitForExistence(timeout: 5))
        app.buttons["Select Items"].tap()

        let firstItem = app.buttons["Select Weekly product review"]
        XCTAssertTrue(firstItem.waitForExistence(timeout: 5))
        firstItem.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        XCTAssertTrue(app.buttons["Delete"].isHittable)
        XCTAssertTrue(app.buttons["Done"].isHittable)

        app.buttons["Done"].tap()
        let search = app.searchFields["Search all media"]
        search.tap()
        search.typeText("client")
        XCTAssertTrue(app.staticTexts["Client discovery notes.pdf"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Weekly product review"].exists)
    }
}
