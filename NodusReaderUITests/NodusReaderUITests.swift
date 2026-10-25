// SPDX-License-Identifier: AGPL-3.0-only
import XCTest

final class NodusReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPhoneScreens() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60),
                      "The sample library did not finish importing")

        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test captures the iPhone layout")

        snap("iPhone-01-Home")

        tapTab("Library", in: app)
        XCTAssertTrue(app.staticTexts["Library"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-02-Library")

        let moby = app.staticTexts["Moby-Dick"].firstMatch
        XCTAssertTrue(moby.waitForExistence(timeout: 10))
        moby.tap()
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))
        snap("iPhone-03-Reader")

        app.buttons["Appearance and typography"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].firstMatch.waitForExistence(timeout: 8))
        snap("iPhone-04-Appearance")
        app.buttons["Done"].tap()
        app.buttons["Back to library"].tap()

        tapTab("Collections", in: app)
        XCTAssertTrue(app.staticTexts["Collections"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-05-Collections")
        app.staticTexts["History"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["In History"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-06-Collection")

        tapTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-07-Settings")

        app.staticTexts["Reading & Typography"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["PREVIEW"].firstMatch.waitForExistence(timeout: 8))
        snap("iPhone-08-Typography")
        app.navigationBars.buttons.firstMatch.tap()

        app.staticTexts["Voices & Models"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Voices"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        snap("iPhone-09-Voices")
        let models = app.buttons["Models"].firstMatch
        if models.waitForExistence(timeout: 3) {
            models.tap()
        } else {
            app.segmentedControls.buttons["Models"].firstMatch.tap()
        }
        sleep(1)
        snap("iPhone-10-Models")

        tapTab("Search", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("Ishmael")
        sleep(1)
        snap("iPhone-11-Search")
    }

    func testPadScreens() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60),
                      "The sample library did not finish importing")

        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width < 700, "This test captures the iPad layout")

        snap("iPad-01-Library")

        app.staticTexts["Home"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Reading now"].firstMatch.waitForExistence(timeout: 10))
        snap("iPad-02-Home")

        app.staticTexts["All Books"].firstMatch.tap()
        let moby = app.staticTexts["Moby-Dick"].firstMatch
        XCTAssertTrue(moby.waitForExistence(timeout: 10))
        moby.tap()
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))
        snap("iPad-03-Reader")
        app.buttons["Back to library"].tap()

        app.staticTexts["History"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["In History"].firstMatch.waitForExistence(timeout: 10))
        snap("iPad-04-Collection")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 10))
        snap("iPad-05-Settings")
        app.buttons["Done"].tap()
    }

    func testListenStartsNarration() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        app.buttons["Listen"].tap()
        let mode = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "FROM CHAPTER")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 25))
        sleep(3)
        snap("iPhone-12-Player")

        app.buttons["Close player"].tap()
        let miniPlayer = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open player'")
        ).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 8))
        sleep(1)
        snap("iPhone-14-MiniPlayer")
    }

    func testReaderWordTapStartsReadAndListen() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        app.buttons["Read"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))

        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 8))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        let capsule = app.staticTexts["READ & LISTEN"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 25))
        sleep(3)
        snap("iPhone-13-ReadAndListen")
    }

    func testPagedReaderTurnsPagesAndBookmarks() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        app.buttons["Read"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))
        let firstPage = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 15))

        app.swipeLeft()
        let secondPage = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Page 2 of'")).firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: 15))

        if app.buttons["Remove bookmark from this page"].waitForExistence(timeout: 2) {
            // The simulator keeps the sample library between runs and this page
            // may already carry a bookmark from an earlier test.
        } else {
            let addBookmark = app.buttons["Bookmark this page"]
            XCTAssertTrue(addBookmark.waitForExistence(timeout: 5))
            addBookmark.tap()
        }
        app.buttons["Contents, bookmarks and notes"].tap()
        let bookmarksTab = app.buttons["Bookmarks"].firstMatch
        if bookmarksTab.waitForExistence(timeout: 3) {
            bookmarksTab.tap()
        } else {
            app.segmentedControls.buttons["Bookmarks"].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["Page 2"].firstMatch.waitForExistence(timeout: 8))
        snap("iPhone-15-Bookmarks")
    }

    func testNeuralVoiceNarration() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        tapTab("Settings", in: app)
        app.staticTexts["Voices & Models"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Voices"].firstMatch.waitForExistence(timeout: 10))
        app.segmentedControls.buttons["Models"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Kokoro 82M"].waitForExistence(timeout: 10))

        let useModel = app.buttons["Use this model"].firstMatch
        if useModel.waitForExistence(timeout: 5) {
            useModel.tap()
        } else if !app.staticTexts["Voice engine selected"].waitForExistence(timeout: 3) {
            throw XCTSkip("No neural model is installed in this simulator; install Phonon from Models to run this test.")
        }

        app.segmentedControls.buttons["Voices"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Phonon 31M"].firstMatch.waitForExistence(timeout: 8))
        let systemVoice = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'System · English'")
        ).firstMatch
        XCTAssertFalse(systemVoice.waitForExistence(timeout: 2),
                       "The voice list still shows voices from a non-selected engine")

        tapTab("Home", in: app)
        let listen = app.buttons["Listen"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()

        let pause = app.buttons["Pause narration"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 180),
                      "Neural narration never started")
        XCTAssertTrue(app.staticTexts["Phonon"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-18-NeuralNarration")

        let progressed = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Sentence 3 '")
        ).firstMatch
        XCTAssertTrue(progressed.waitForExistence(timeout: 90),
                      "Phonon audio never advanced past the second sentence")
        sleep(2)
        snap("iPhone-19-NeuralProgress")
    }

    func testVoicePickerStartsWithBookLanguage() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        tapTab("Library", in: app)
        let spanishBook = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Don Quijote de la Mancha'")
        ).firstMatch
        XCTAssertTrue(spanishBook.waitForExistence(timeout: 10))
        spanishBook.tap()

        let page = app.textViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()

        let openPlayer = app.buttons["Open player"].firstMatch
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 30))
        openPlayer.tap()

        XCTAssertTrue(app.staticTexts["System"].firstMatch.waitForExistence(timeout: 10),
                      "A Spanish book should start with a Spanish system voice")
        let voiceControl = app.buttons["Voice for this book"].firstMatch
        XCTAssertTrue(voiceControl.waitForExistence(timeout: 10))
        voiceControl.tap()

        let spanishSection = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Spanish'")
        ).firstMatch
        XCTAssertTrue(spanishSection.waitForExistence(timeout: 8),
                      "The voice picker did not start on the book's language")

        let englishNeural = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Phonon'")
        ).firstMatch
        XCTAssertFalse(englishNeural.waitForExistence(timeout: 2),
                       "English neural voices were shown before the Spanish book voices")
    }

    func testICloudAndStorage() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        tapTab("Settings", in: app)
        app.staticTexts["iCloud & Storage"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["iCloud"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sync with iCloud"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sync is off"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Troubleshooting"].waitForExistence(timeout: 5))
        snap("iPhone-20-ICloudStorage")
    }

    func testPDFIntelligentReading() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        let pdf = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                    "Experiments in Plant Hybridization")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        pdf.tap()

        let intelligent = app.segmentedControls.buttons["Intelligent Reading"].firstMatch
        XCTAssertTrue(intelligent.waitForExistence(timeout: 15))
        intelligent.tap()

        let pageMarker = app.buttons.matching(NSPredicate(format: "label == 'Page 1'")).firstMatch
        XCTAssertTrue(pageMarker.waitForExistence(timeout: 60))
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 20))
        snap("iPhone-16-PDFReflow")

        app.buttons["Original page panel"].tap()
        XCTAssertTrue(app.staticTexts["Original page"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-17-PDFSource")
    }

    // MARK: - Helpers

    private func launch(resetReadingState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NodusSampleLibrary"]
        if resetReadingState {
            app.launchArguments.append("-NodusResetReadingState")
        }
        app.launch()
        return app
    }

    private func tapTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 3) {
            tab.tap()
            return
        }
        let button = app.buttons[name]
        if button.waitForExistence(timeout: 3) {
            button.tap()
            return
        }
        XCTFail("Tab \(name) was not found")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
