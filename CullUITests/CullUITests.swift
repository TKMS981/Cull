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
    private func launch(extraArguments: [String] = [], pinSortOrder: Bool = true) {
        app = XCUIApplication()
        // The argument domain overrides the persisted sort order, so a test that changes
        // it can't leak into the others (which expect the default, newest first).
        let sort = pinSortOrder ? ["-sortOrder", "newest"] : []
        app.launchArguments = ["-UITestInMemoryStore"] + sort + extraArguments
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
            // Rows below the fold aren't materialised until scrolled to.
            let button = app.buttons["attribute.\(attribute)"]
            for _ in 0..<5 where !(button.exists && button.isHittable) { app.collectionViews.firstMatch.swipeUp() }
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
    func testShortOrVerticalDragsDoNotCull() throws {
        let (card, progress) = try startCulling()
        let initial = remaining(progress)
        let center = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Slow, short sideways drag (~20% of the card) springs back.
        center.press(forDuration: 0.2, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        // Mostly-vertical drag with some sideways drift locks vertical: no keep / trash,
        // and too short (and slow) to skip.
        center.press(forDuration: 0.2, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        // A short slow downward drag (under the skip distance) does nothing.
        let downStart = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        downStart.press(forDuration: 0.1, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)

        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(remaining(progress), initial, "short or vertical drags must not decide")
        XCTAssertFalse(app.descendants(matching: .any)["infoSheet"].exists, "downward drags must not open info")
        XCTAssertFalse(app.staticTexts["skipTally"].exists, "short downward drags must not skip")
    }

    /// Regression: fast back-to-back swipes used to leave a card spinning up the screen.
    /// After a burst of flicks every decision lands once, and the card on top sits
    /// upright in the middle of the deck.
    @MainActor
    func testRapidConsecutiveSwipesKeepTheDeckSteady() throws {
        let (card, progress) = try startCulling()
        let initial = remaining(progress)
        XCTAssertGreaterThan(initial, 4, "seed at least five assets")
        let rest = card.frame

        card.swipeLeft(velocity: .fast)
        card.swipeRight(velocity: .fast)
        card.swipeLeft(velocity: .fast)
        card.swipeRight(velocity: .fast)
        waitFor(progress, value: "\(initial - 4)")
        Thread.sleep(forTimeInterval: 0.6)   // let the thrown cards finish flying

        let settled = card.frame
        XCTAssertEqual(settled.midX, rest.midX, accuracy: 4, "top card is centred")
        XCTAssertEqual(settled.midY, rest.midY, accuracy: 4, "top card hasn't drifted up or down")
        XCTAssertEqual(settled.width, rest.width, accuracy: 4, "top card is upright (a tilt widens its frame)")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "mediaCard").count, 1)

        for _ in 0..<4 { app.buttons["undoButton"].tap() }
        waitFor(progress, value: "\(initial)")
    }

    /// Skip (button or swipe down) passes over an item for this session only: no keep,
    /// no trash, undoable, and it's still unsorted afterwards.
    @MainActor
    func testSkipPassesOverWithoutSaving() throws {
        let (card, progress) = try startCulling()
        let initial = remaining(progress)
        XCTAssertGreaterThan(initial, 2)

        app.buttons["skipButton"].tap()
        waitFor(progress, value: "\(initial - 1)")
        card.swipeDown()
        waitFor(progress, value: "\(initial - 2)")
        let tally = app.staticTexts["skipTally"]
        XCTAssertTrue(tally.waitForExistence(timeout: 2))
        XCTAssertTrue(tally.label.contains("2"), tally.label)
        XCTAssertEqual(app.buttons["trashButton"].value as? String, "0")

        app.buttons["undoButton"].tap()
        waitFor(progress, value: "\(initial - 1)")

        // Nothing was saved: back on the setup screen every item is still unsorted.
        app.buttons["BackButton"].tap()
        let start = app.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS %@", " \(initial) "), evaluatedWith: start)
        waitForExpectations(timeout: 5)
    }

    /// A playing video shows elapsed / total time and a seek bar. Dragging along the bar
    /// sideways scrubs the video and never keeps / trashes the card or moves it.
    @MainActor
    func testVideoSeekBarScrubsWithoutSwiping() throws {
        let (card, progress) = try startCulling(attribute: "video")
        let initial = remaining(progress)
        let bar = app.descendants(matching: .any)["videoSeekBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "seed a video with Scripts/seed_simulator.sh")
        let rest = card.frame

        // Right (trash direction) then left (keep direction), each far past the swipe threshold.
        let left = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        let right = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        left.press(forDuration: 0.15, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0.1)
        XCTAssertNotEqual(bar.value as? String ?? "", "", "shows the time")
        right.press(forDuration: 0.15, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0.1)

        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(remaining(progress), initial, "scrubbing must not keep or trash")
        XCTAssertEqual(card.frame.midX, rest.midX, accuracy: 4, "card stays put")
        XCTAssertEqual(app.buttons["trashButton"].value as? String, "0")

        // The card still swipes normally afterwards.
        card.swipeLeft()
        waitFor(progress, value: "\(initial - 1)")
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

    /// "Largest first" measures sizes off the main actor and then starts a normal session
    /// over the same items as the date orders.
    @MainActor
    func testLargestFirstSortStartsSession() throws {
        launch(pinSortOrder: false)
        let start = app.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 10)

        let picker = app.buttons["sortPicker"]
        for _ in 0..<4 where !picker.isHittable { app.collectionViews.firstMatch.swipeUp() }
        picker.tap()
        let largest = app.buttons.matching(NSPredicate(format: "label IN %@", ["Largest First", "容量が大きい順"])).firstMatch
        XCTAssertTrue(largest.waitForExistence(timeout: 5))
        largest.tap()
        // The menu closes and the row shows the chosen order.
        let shown = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Largest First", "容量が大きい順"])).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Newest First"].exists)

        start.tap()
        let card = app.descendants(matching: .any)["mediaCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let progress = app.descendants(matching: .any)["progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(remaining(progress), 0)
    }

    /// Kept items show in a grid; selecting one and un-keeping it puts it back in the unsorted pool.
    @MainActor
    func testKeptListUnkeepAndSendToTrash() throws {
        let (_, progress) = try startCulling()
        let initial = remaining(progress)
        XCTAssertGreaterThan(initial, 2)
        app.buttons["keepButton"].tap()
        waitFor(progress, value: "\(initial - 1)")
        app.buttons["keepButton"].tap()
        waitFor(progress, value: "\(initial - 2)")
        app.buttons["BackButton"].tap()

        let keptList = app.buttons["keptListButton"]
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !keptList.isHittable { app.collectionViews.firstMatch.swipeUp() }
        keptList.tap()

        let cells = app.buttons.matching(identifier: "keptCell")
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: cells)
        waitForExpectations(timeout: 10)

        app.buttons["keptSelectButton"].tap()
        XCTAssertTrue(app.buttons["unkeepButton"].waitForExistence(timeout: 5))
        cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["unkeepButton"].tap()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: cells)
        waitForExpectations(timeout: 5)

        cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["keptToTrashButton"].tap()
        expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: cells)
        waitForExpectations(timeout: 5)

        // One went back to unsorted, one to Cull's trash.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let start = app.buttons["startButton"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", " \(initial - 1) "), evaluatedWith: start)
        waitForExpectations(timeout: 5)
        XCTAssertTrue((app.buttons["setupTrashButton"].value as? String ?? "").hasPrefix("1"))
    }

    /// Resetting by attribute only un-keeps matching items.
    @MainActor
    func testResetKeptByAttribute() throws {
        let (_, progress) = try startCulling(attribute: "livePhoto")
        let total = remaining(progress)
        XCTAssertGreaterThanOrEqual(total, 1)
        app.buttons["keepButton"].tap()
        waitFor(progress, value: "\(total - 1)")
        app.buttons["BackButton"].tap()

        let reset = app.buttons["resetKeptButton"]
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !reset.isHittable { app.collectionViews.firstMatch.swipeUp() }
        reset.tap()

        let segment = app.segmentedControls["resetScopePicker"].buttons.element(boundBy: 1)
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        segment.tap()
        let confirm = app.buttons["confirmResetKeptButton"]

        // Videos only: the kept Live Photo doesn't match.
        app.buttons["resetAttribute.video"].tap()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)

        // Live Photos: it does.
        app.buttons["resetAttribute.video"].tap()
        app.buttons["resetAttribute.livePhoto"].tap()
        expectation(for: NSPredicate(format: "isEnabled == true AND label CONTAINS '1'"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        confirm.tap()

        XCTAssertFalse(confirm.waitForExistence(timeout: 2))
        XCTAssertFalse(reset.isEnabled, "nothing kept any more")
    }

    /// Quick-start presets set the filter in one tap and clear it on a second tap.
    @MainActor
    func testQuickStartPresetsApplyAndClear() throws {
        launch()
        let start = app.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let allLabel = start.label

        let live = app.buttons["preset.livePhotos"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        live.tap()
        XCTAssertTrue(live.isSelected)
        XCTAssertTrue(app.buttons["attribute.livePhoto"].isSelected)
        let narrowed = NSPredicate(format: "label != %@", allLabel)
        expectation(for: narrowed, evaluatedWith: start)
        waitForExpectations(timeout: 5)

        live.tap()   // second tap clears
        XCTAssertFalse(live.isSelected)
        XCTAssertFalse(app.buttons["attribute.livePhoto"].isSelected)
        expectation(for: NSPredicate(format: "label == %@", allLabel), evaluatedWith: start)
        waitForExpectations(timeout: 5)

        app.buttons["preset.thisMonth"].tap()
        XCTAssertTrue(app.buttons["preset.thisMonth"].isSelected)
        XCTAssertFalse(live.isSelected)
        XCTAssertEqual(app.switches["dateRangeToggle"].firstMatch.value as? String, "1")
    }

    // MARK: Phase B

    /// The storage screen measures the library and a category row starts culling just
    /// those items, biggest first.
    @MainActor
    func testStorageAnalysisLeadsIntoCulling() throws {
        try openFromSetup("storageButton")
        let total = app.descendants(matching: .any)["storageTotal"]
        XCTAssertTrue(total.waitForExistence(timeout: 30), "the scan finishes and shows a total")
        XCTAssertTrue(app.buttons.matching(identifier: "storageLargeItem").firstMatch.waitForExistence(timeout: 5))

        let videos = app.buttons["storageCategory.video"]
        XCTAssertTrue(videos.waitForExistence(timeout: 5), "seed includes a video")
        videos.tap()
        let card = app.descendants(matching: .any)["mediaCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let progress = app.descendants(matching: .any)["progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(remaining(progress), 1)
    }

    /// A scan of recent photos finds the seeded near-duplicate pair; applying the
    /// suggestion sends one to Cull's trash and keeps the other.
    @MainActor
    func testSimilarPhotosFindsGroupAndSendsExtraToTrash() throws {
        try openFromSetup("similarButton")
        let scan = app.buttons["similarScanButton"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: scan)
        waitForExpectations(timeout: 10)
        scan.tap()

        let group = app.buttons.matching(identifier: "similarGroup").firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30), "seed includes a near-duplicate pair")
        group.tap()

        let tiles = app.buttons.matching(identifier: "similarTile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(tiles.count, 2)
        // Tapping flips a mark; tapping again flips it back.
        let first = tiles.element(boundBy: 0)
        let before = first.value as? String
        first.tap()
        expectation(for: NSPredicate(format: "value != %@", before ?? ""), evaluatedWith: first)
        waitForExpectations(timeout: 5)
        first.tap()
        expectation(for: NSPredicate(format: "value == %@", before ?? ""), evaluatedWith: first)
        waitForExpectations(timeout: 5)

        app.buttons["similarApplyButton"].tap()
        // Back to the setup screen: one item is in Cull's trash now.
        let start = app.buttons["startButton"]
        for _ in 0..<3 where !start.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = start.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let trash = app.buttons["setupTrashButton"]
        expectation(for: NSPredicate(format: "value BEGINSWITH '1'"), evaluatedWith: trash)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func openFromSetup(_ identifier: String) throws {
        launch()
        let request = app.buttons["requestAccessButton"]
        if request.waitForExistence(timeout: 2) {
            request.tap()
            app.tap()
        }
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<4 where !button.isHittable { app.collectionViews.firstMatch.swipeUp() }
        button.tap()
    }
}
