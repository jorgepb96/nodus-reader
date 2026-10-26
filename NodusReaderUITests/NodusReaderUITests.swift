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

        // "Aa" opens the appearance popover.
        app.buttons["Appearance and typography"].tap()
        XCTAssertTrue(app.switches["This book only"].firstMatch.waitForExistence(timeout: 8))
        snap("iPhone-04-Appearance")
        dismissPopover(in: app)
        app.buttons["Back to library"].tap()

        // Collections live in Library as folders.
        XCTAssertTrue(app.staticTexts["Collections"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-05-Collections")
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'History'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        history.tap()
        XCTAssertTrue(app.staticTexts["In History"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Search this collection"].firstMatch.exists)
        snap("iPhone-06-Collection")
        app.navigationBars.buttons.firstMatch.tap()

        tapTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 10))
        snap("iPhone-07-Settings")

        app.staticTexts["Reading & Typography"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Line spacing"].firstMatch.waitForExistence(timeout: 8))
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

        // Search lives in Library (no separate Search tab).
        tapTab("Library", in: app)
        let field = app.textFields["Search library"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("Ishmael")
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 8))
        snap("iPhone-11-Search")
        XCTAssertFalse(app.tabBars.buttons["Collections"].exists)
        XCTAssertFalse(app.tabBars.buttons["Search"].exists)
    }

    func testPadScreens() throws {
        let app = launch(resetReadingState: true)
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

    /// App Store screenshots of the sample library in English or Spanish, on
    /// whichever simulator runs it (6.9" iPhone, 13" iPad). Opt in with
    /// `TEST_RUNNER_NODUS_APPSTORE_LANG=en` or `es`; the images are attached to
    /// the test result as "AppStore-…".
    func testAppStoreScreenshots() throws {
        guard let language = ProcessInfo.processInfo.environment["NODUS_APPSTORE_LANG"] else {
            throw XCTSkip("Set TEST_RUNNER_NODUS_APPSTORE_LANG to en or es")
        }
        let spanish = language == "es"
        func label(_ english: String, _ spanishText: String) -> String { spanish ? spanishText : english }
        let app = XCUIApplication()
        app.launchArguments = ["-NodusSampleLibrary", "-NodusResetReadingState",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", spanish ? "es_ES" : "en_US",
                               "-nodus.narration.preciseWordTiming", "NO"]
        app.launch()
        let isPad = app.windows.firstMatch.frame.width >= 700
        let device = isPad ? "iPad" : "iPhone"
        func shot(_ name: String) {
            sleep(2)
            snap("AppStore-\(device)-\(language)-\(name)")
        }

        // The Spanish listing reads a Spanish book: opening it makes it the
        // book to continue on Home.
        if spanish {
            if isPad {
                XCTAssertTrue(app.staticTexts["Todos los libros"].firstMatch.waitForExistence(timeout: 60))
                app.staticTexts["Todos los libros"].firstMatch.tap()
            } else {
                XCTAssertTrue(app.buttons["Leer"].firstMatch.waitForExistence(timeout: 60))
                tapTab("Biblioteca", in: app)
            }
            let quijote = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don Quijote de la Mancha'"))
                .firstMatch
            XCTAssertTrue(quijote.waitForExistence(timeout: 10))
            quijote.tap()
            XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 20))
            app.buttons["Volver a la biblioteca"].firstMatch.tap()
            if !isPad { tapTab("Inicio", in: app) }
        }

        // Home and library.
        if isPad {
            let home = app.staticTexts[label("Home", "Inicio")].firstMatch
            XCTAssertTrue(home.waitForExistence(timeout: 60))
            sleep(4)
            if !spanish { shot("02-Library") }
            home.tap()
        }
        let read = app.buttons[label("Read", "Leer")].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 60))
        sleep(3)
        shot("01-Home")
        if isPad, spanish {
            app.staticTexts["Todos los libros"].firstMatch.tap()
            app.swipeDown()
            app.swipeDown()
            shot("02-Library")
            app.staticTexts["Inicio"].firstMatch.tap()
        }
        if !isPad {
            tapTab(label("Library", "Biblioteca"), in: app)
            // Back at the top after opening a book from the list.
            app.swipeDown()
            app.swipeDown()
            shot("02-Library")
            tapTab(label("Home", "Inicio"), in: app)
        }

        // Reading, search, Read & Listen and the player.
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        let page = app.textViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        shot("03-Reader")

        app.buttons[label("Search in book", "Buscar en el libro")].firstMatch.tap()
        let field = app.textFields["ReaderSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(spanish ? "hidalgo" : "whenever")
        let counter = app.staticTexts["ReaderSearchCounter"]
        let found = expectation(for: NSPredicate(format: "label CONTAINS %@", label(" of ", " de ")),
                                evaluatedWith: counter)
        wait(for: [found], timeout: 15)
        // The keyboard's first-use tip, then the Search key hides the keyboard.
        let tip = app.buttons[label("Continue", "Continuar")].firstMatch
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        field.typeText("\n")
        shot("04-Search")
        app.buttons[label("Done", "OK")].firstMatch.tap()

        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(app.staticTexts[label("READ & LISTEN", "LEER Y ESCUCHAR")].waitForExistence(timeout: 25))
        sleep(3)
        shot("05-ReadAndListen")
        let openPlayer = app.buttons[label("Open player", "Abrir reproductor")].firstMatch
        if openPlayer.waitForExistence(timeout: 5) {
            openPlayer.tap()
            shot("06-Player")
            app.buttons[label("Close player", "Cerrar reproductor")].firstMatch.tap()
        }
        app.buttons[label("Back to library", "Volver a la biblioteca")].firstMatch.tap()

        // A PDF in Intelligent Reading.
        if isPad {
            app.staticTexts[label("All Books", "Todos los libros")].firstMatch.tap()
        } else {
            tapTab(label("Library", "Biblioteca"), in: app)
        }
        let pdf = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                   "Experiments in Plant Hybridization")).firstMatch
        if !pdf.waitForExistence(timeout: 5) {
            app.swipeUp()
        }
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        pdf.tap()
        let intelligent = app.segmentedControls.buttons[label("Intelligent Reading", "Lectura inteligente")].firstMatch
        XCTAssertTrue(intelligent.waitForExistence(timeout: 15))
        intelligent.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 60))
        shot("07-PDF")
        app.buttons[label("Back to library", "Volver a la biblioteca")].firstMatch.tap()

        // Settings: themes, voices, iCloud.
        if isPad {
            app.buttons[label("Settings", "Ajustes")].firstMatch.tap()
        } else {
            tapTab(label("Settings", "Ajustes"), in: app)
        }
        XCTAssertTrue(app.staticTexts[label("Voices & Models", "Voces y modelos")].firstMatch
            .waitForExistence(timeout: 10))
        shot("08-Settings")
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

    func testReaderSearchStepsThroughMatches() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        app.buttons["Read"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))
        let page = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15))

        app.buttons["Search in book"].tap()
        let field = app.textFields["ReaderSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Three times in the sample's first chapter.
        field.typeText("whenever")

        let counter = app.staticTexts["ReaderSearchCounter"]
        func waitForCounter(_ format: String, _ argument: String) {
            let matched = expectation(for: NSPredicate(format: format, argument), evaluatedWith: counter)
            wait(for: [matched], timeout: 15)
        }
        waitForCounter("label BEGINSWITH %@", "1 of ")
        let total = counter.label.components(separatedBy: " of ").last ?? ""
        XCTAssertGreaterThanOrEqual(Int(total) ?? 0, 3)

        app.buttons["Next match"].tap()
        waitForCounter("label BEGINSWITH %@", "2 of ")
        app.buttons["Previous match"].tap()
        waitForCounter("label BEGINSWITH %@", "1 of ")
        // Before the first match comes the last one.
        app.buttons["Previous match"].tap()
        waitForCounter("label == %@", "\(total) of \(total)")
        snap("iPhone-21-ReaderSearch")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Search in book"].waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
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
        // The player names the voice's model ("Phonon 31M").
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Phonon'"))
            .firstMatch.waitForExistence(timeout: 10))
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

        // The model filter sits next to the language filter.
        let modelFilter = app.buttons["Filter by Model"].firstMatch
        XCTAssertTrue(modelFilter.waitForExistence(timeout: 5))
        modelFilter.tap()
        let systemOnly = app.buttons["System"].firstMatch
        XCTAssertTrue(systemOnly.waitForExistence(timeout: 5))
        systemOnly.tap()
        XCTAssertEqual(app.buttons["Filter by Model"].firstMatch.value as? String, "System")
        XCTAssertTrue(spanishSection.waitForExistence(timeout: 5))
    }

    func testICloudAndStorage() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 700, "This test runs on iPhone")

        tapTab("Settings", in: app)
        let storage = app.staticTexts["iCloud & Storage"].firstMatch
        XCTAssertTrue(storage.waitForExistence(timeout: 10))
        storage.tap()
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

        // The panel's arrows turn the reflow too, and the panel follows it.
        let pageCounter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 / '")).firstMatch
        XCTAssertTrue(pageCounter.waitForExistence(timeout: 5))
        app.buttons["Next page"].firstMatch.tap()
        let secondPage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 / '")).firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        let readerPage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of'")).firstMatch
        XCTAssertTrue(readerPage.waitForExistence(timeout: 5), "The reflow did not move to page 2")

        // Tapping a word of the reflowed text starts Read & Listen.
        let visibleText = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first { $0.isHittable })
        visibleText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["READ & LISTEN"].waitForExistence(timeout: 25),
                      "Read & Listen did not start from Intelligent Reading")
    }

    func testPDFReflowHighlightAndNote() throws {
        let app = launch(resetReadingState: true)
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Page 1'")).firstMatch
            .waitForExistence(timeout: 60))

        // Select a word in a reflowed paragraph and highlight it.
        let paragraphs = app.textViews
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
        let target = paragraphs.count > 1 ? paragraphs.element(boundBy: 1) : paragraphs.firstMatch
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1.2)
        let highlight = app.menuItems["Highlight"].firstMatch.exists
            ? app.menuItems["Highlight"].firstMatch : app.buttons["Highlight"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 8), "The selection menu offers Highlight")
        highlight.tap()
        let yellow = app.menuItems["Yellow"].firstMatch.waitForExistence(timeout: 3)
            ? app.menuItems["Yellow"].firstMatch : app.buttons["Yellow"].firstMatch
        XCTAssertTrue(yellow.waitForExistence(timeout: 5))
        yellow.tap()

        XCTAssertTrue(app.navigationBars["Add Highlight"].waitForExistence(timeout: 8))
        // The sheet's note field, not a reflow paragraph behind the sheet.
        let noteEditor = app.textViews["annotationNoteEditor"].firstMatch
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 5))
        noteEditor.tap()
        noteEditor.typeText("Mendel's ratio")
        app.buttons["Save"].firstMatch.tap()
        sleep(1)
        snap("iPhone-24-PDFHighlight")

        // The note is listed by page in the contents sheet.
        app.buttons["Contents, bookmarks and notes"].tap()
        XCTAssertTrue(app.staticTexts["Highlights and notes"].firstMatch.waitForExistence(timeout: 8)
                      || app.otherElements["Highlights and notes"].firstMatch.exists)
        let noteRow = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Page '")).firstMatch
        XCTAssertTrue(noteRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Mendel's ratio"].firstMatch.waitForExistence(timeout: 3))
        snap("iPhone-25-PDFNotes")
    }

    func testReaderAppearancePopoverAndContinuousScroll() throws {
        let app = launch(resetReadingState: true)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 60))
        let isPad = app.windows.firstMatch.frame.width >= 700

        if isPad {
            // iPad opens on the library grid; Home has no Read button.
            app.staticTexts["All Books"].firstMatch.tap()
            let moby = app.staticTexts["Moby-Dick"].firstMatch
            XCTAssertTrue(moby.waitForExistence(timeout: 10))
            moby.tap()
        } else {
            app.buttons["Read"].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(pageLabel(in: app, beginningWith: "Page 1 of").waitForExistence(timeout: 15))

        // The "Aa" button opens a popover, not a full-screen sheet.
        openAppearance(in: app)
        XCTAssertTrue(app.switches["This book only"].firstMatch.waitForExistence(timeout: 5))
        let sepia = app.buttons["Sepia theme"].firstMatch
        XCTAssertTrue(sepia.waitForExistence(timeout: 5))
        sepia.tap()
        snap(isPad ? "iPad-06-AppearancePopover" : "iPhone-21-AppearancePopover")

        if isPad {
            // The sample book fits on about one iPad screen; larger text gives
            // the continuous column something to scroll through.
            let larger = app.buttons["Larger text"].firstMatch
            XCTAssertTrue(larger.waitForExistence(timeout: 5))
            for _ in 0..<12 where larger.isEnabled { larger.tap() }
        }

        // Continuous vertical scroll.
        chooseFlow("Scroll down", in: app)
        dismissPopover(in: app)
        XCTAssertTrue(app.staticTexts["Loomings"].firstMatch.waitForExistence(timeout: 15))
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        XCTAssertTrue(pageLabel(in: app, notBeginningWith: "Page 1 of").waitForExistence(timeout: 10),
                      "Scrolling down should advance the reading position")
        snap(isPad ? "iPad-07-ScrollVertical" : "iPhone-22-ScrollVertical")

        // Continuous horizontal strip of columns.
        openAppearance(in: app)
        chooseFlow("Scroll across", in: app)
        dismissPopover(in: app)
        app.swipeLeft(velocity: .fast)
        app.swipeLeft(velocity: .fast)
        XCTAssertTrue(pageLabel(in: app, notBeginningWith: "Page 1 of").waitForExistence(timeout: 10))
        snap(isPad ? "iPad-08-ScrollHorizontal" : "iPhone-23-ScrollHorizontal")

        // Restore the shared defaults for the other tests.
        openAppearance(in: app)
        chooseFlow("Paged", in: app)
        app.buttons["Dark theme"].firstMatch.tap()
        dismissPopover(in: app)
    }

    // MARK: - Helpers

    private func pageLabel(in app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func pageLabel(in app: XCUIApplication, notBeginningWith prefix: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(
            format: "label BEGINSWITH 'Page ' AND label CONTAINS ' of ' AND NOT (label BEGINSWITH %@)", prefix
        )).firstMatch
    }

    private func openAppearance(in app: XCUIApplication) {
        let button = app.buttons["Appearance and typography"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        button.tap()
    }

    private func chooseFlow(_ label: String, in app: XCUIApplication) {
        let segment = app.buttons[label].firstMatch
        if segment.waitForExistence(timeout: 3) {
            segment.tap()
            return
        }
        let fallback = label == "Paged" ? app.buttons["Paged"].firstMatch
            : (label == "Scroll down" ? app.buttons["Continuous vertical scroll"].firstMatch
                                      : app.buttons["Continuous horizontal scroll"].firstMatch)
        XCTAssertTrue(fallback.waitForExistence(timeout: 3), "Reading mode \(label) was not found")
        fallback.tap()
    }

    private func dismissPopover(in app: XCUIApplication) {
        let region = app.otherElements["PopoverDismissRegion"].firstMatch
        if region.waitForExistence(timeout: 2) {
            region.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        }
        XCTAssertFalse(app.switches["This book only"].firstMatch.waitForExistence(timeout: 1))
    }

    private func launch(resetReadingState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // The tests read English labels; the app follows the device language
        // (Spanish or English), so pin it to English whatever the simulator uses.
        app.launchArguments = ["-NodusSampleLibrary", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Word timing from speech recognition may first download the system's
        // speech model; the tests use the estimate unless asked to check that
        // narration still starts with it on (TEST_RUNNER_NODUS_PRECISE_TIMING=1).
        if ProcessInfo.processInfo.environment["NODUS_PRECISE_TIMING"] != "1" {
            app.launchArguments += ["-nodus.narration.preciseWordTiming", "NO"]
        }
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
