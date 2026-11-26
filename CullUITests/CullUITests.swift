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
    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-UITestInMemoryStore"] + extraArguments
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
    private func startCulling(attribute: String? = nil, extraArguments: [String] = []) throws -> (card: XCUIElement, progress: XCUIElement) {
        launch(extraArguments: extraArguments)
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
        if let attribute {
            let button = app.buttons["attribute.\(attribute)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
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
        app.buttons["selectButton"].tap()   // a plain tap opens the preview instead
        XCTAssertTrue(app.buttons["restoreButton"].waitForExistence(timeout: 5))
        // In selection mode XCUITest reports the cell as not hittable (its a11y frame spans the
        // unclipped fill image), though a real tap at its centre works; tap the centre directly.
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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

    @MainActor
    func testKeepButtonsAndMultipleUndo() throws {
        let (_, progress) = try startCulling()
        let initial = remaining(progress)
        XCTAssertGreaterThan(initial, 2)

        app.buttons["keepButton"].tap()
        waitFor(progress, value: "\(initial - 1)")
        app.buttons["trashSwipeButton"].tap()
        waitFor(progress, value: "\(initial - 2)")
        XCTAssertEqual(app.buttons["trashButton"].value as? String, "1")

        app.buttons["undoButton"].tap()
        waitFor(progress, value: "\(initial - 1)")
        XCTAssertEqual(app.buttons["trashButton"].value as? String, "0")
        app.buttons["undoButton"].tap()
        waitFor(progress, value: "\(initial)")
        XCTAssertFalse(app.buttons["undoButton"].isEnabled)
    }

    /// The Live Photo card is announced as a Live Photo. (XCUITest's tree on iOS 27
    /// also lists `.accessibilityHidden` / `children: .ignore` descendants, so it can't
    /// prove what VoiceOver skips; that part is checked by hand with VoiceOver.)
    @MainActor
    func testLivePhotoCardAnnouncesKind() throws {
        let (card, _) = try startCulling(attribute: "livePhoto")
        XCTAssertEqual(card.label, "Live Photo")
        XCTAssertEqual(card.value as? String, "fit")
    }

    /// English plural variants: "1 kept item" (one) and "Sorted 2 items." (other).
    /// Needs at least two Live Photos in the library (`Scripts/seed_simulator.sh` adds one per run).
    @MainActor
    func testEnglishPluralForms() throws {
        let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let (_, progress) = try startCulling(attribute: "livePhoto", extraArguments: english)
        let total = remaining(progress)
        XCTAssertGreaterThanOrEqual(total, 2)

        app.buttons["keepButton"].tap()
        waitFor(progress, value: "\(total - 1)")
        for _ in 1..<total { app.buttons["keepButton"].tap() }
        XCTAssertTrue(app.staticTexts["Sorted \(total) items."].waitForExistence(timeout: 5))

        // Undo all but one keep, so exactly one item stays kept.
        // Undo lives in the top HUD, on the finished screen as well as mid-session.
        for _ in 1..<total {
            let undo = app.buttons["undoButton"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            undo.tap()
        }
        waitFor(progress, value: "\(total - 1)")
        app.buttons["BackButton"].tap()

        let reset = app.buttons["resetKeptButton"]
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: 5))
        for _ in 0..<3 where !reset.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        let message = "1 kept item will be shown again. Cull's trash is not affected."
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Finishing a session shows the summary with this run's tallies and the way to the trash.
    @MainActor
    func testSessionSummaryShowsTalliesAndLinksToTrash() throws {
        let (_, progress) = try startCulling(attribute: "livePhoto")
        let total = remaining(progress)
        XCTAssertGreaterThanOrEqual(total, 2)

        app.buttons["trashSwipeButton"].tap()
        waitFor(progress, value: "\(total - 1)")
        for _ in 1..<total { app.buttons["keepButton"].tap() }

        let summary = app.descendants(matching: .any)["sessionSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["summaryKept"].label.contains("\(total - 1)"))
        XCTAssertTrue(app.descendants(matching: .any)["summaryTrashed"].label.contains("1"))

        app.buttons["reviewTrashButton"].tap()
        XCTAssertTrue(app.buttons["trashCell"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let done = app.buttons["summaryDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: 5))
    }

    /// Trash shows the reclaimable size, and a cell opens a preview that can restore the item.
    @MainActor
    func testTrashSizeAndPreviewRestore() throws {
        let (card, progress) = try startCulling()
        let initial = remaining(progress)
        card.swipeRight()
        waitFor(progress, value: "\(initial - 1)")

        app.buttons["trashButton"].tap()
        let summary = app.descendants(matching: .any)["trashSizeSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let sized = NSPredicate(format: "label CONTAINS 'can be freed' AND NOT (label CONTAINS 'Zero')")
        expectation(for: sized, evaluatedWith: summary)
        waitForExpectations(timeout: 10)

        let cell = app.buttons["trashCell"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trashPreview"].waitForExistence(timeout: 5))
        app.buttons["previewRestoreButton"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["trashPreview"].waitForExistence(timeout: 2))
        XCTAssertFalse(cell.waitForExistence(timeout: 2))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(progress, value: "\(initial)")
    }
}
