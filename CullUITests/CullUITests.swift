import XCTest

/// Requires media in the simulator library (`xcrun simctl addmedia`) and photo
/// access granted (`xcrun simctl privacy <udid> grant photos com.example.Cull`);
/// falls back to tapping the system alert if access isn't pre-granted.
final class CullUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-UITestInMemoryStore"]
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "フルアクセスを許可", "Allow Access to All Photos", "すべての写真へのアクセスを許可"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
    }

    @MainActor
    private func startCulling() throws -> (card: XCUIElement, progress: XCUIElement) {
        launch()
        let request = app.buttons["requestAccessButton"]
        if request.waitForExistence(timeout: 2) {
            request.tap()
            app.tap() // let the interruption monitor handle the alert
        }
        let start = app.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: start)
        waitForExpectations(timeout: 10)
        start.tap()

        let card = app.descendants(matching: .any)["mediaCard"]
        let progress = app.descendants(matching: .any)["progress"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        return (card, progress)
    }

    @MainActor
    private func remaining(_ progress: XCUIElement) -> Int {
        Int(progress.value as? String ?? "") ?? -1
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "value == %@", value)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    func testPinchZoomDisablesSwipesAndInfo() throws {
        let (card, progress) = try startCulling()
        let initial = remaining(progress)
        XCTAssertGreaterThan(initial, 1, "seed at least two assets with simctl addmedia")
        XCTAssertEqual(card.value as? String, "fit")

        card.pinch(withScale: 3, velocity: 2)
        waitFor(card, value: "zoomed")

        // While zoomed, horizontal swipes pan the image and swipe-up must not open info.
        card.swipeLeft()
        card.swipeRight()
        card.swipeUp()
        XCTAssertEqual(remaining(progress), initial, "swipe must not cull while zoomed")
        XCTAssertFalse(app.descendants(matching: .any)["infoSheet"].waitForExistence(timeout: 1.5), "swipe-up must not open info while zoomed")
        XCTAssertEqual(card.value as? String, "zoomed")

        // Double-tap back to fit; swiping works again.
        card.doubleTap()
        waitFor(card, value: "fit")
        card.swipeLeft()
        waitFor(progress, value: "\(initial - 1)")

        // Undo restores it.
        app.buttons["undoButton"].tap()
        waitFor(progress, value: "\(initial)")
    }

    @MainActor
    func testSwipeRightMovesToTrashAndRestore() throws {
        let (card, progress) = try startCulling()
        let initial = remaining(progress)

        card.swipeRight()
        waitFor(progress, value: "\(initial - 1)")

        app.buttons["trashButton"].tap()
        let cell = app.buttons["trashCell"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.tap()
        app.buttons["restoreButton"].tap()
        XCTAssertFalse(cell.waitForExistence(timeout: 1))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(progress, value: "\(initial)")
    }

    @MainActor
    func testSwipeUpOpensInfo() throws {
        let (card, _) = try startCulling()
        card.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["infoSheet"].waitForExistence(timeout: 5))
    }
}
