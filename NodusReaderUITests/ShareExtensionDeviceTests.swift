// SPDX-License-Identifier: AGPL-3.0-only
import XCTest

/// The Share Extension on a signed device: shared from Safari, it opens, reaches
/// the App Group (an unsigned Simulator build cannot) and offers Import. It is
/// cancelled before importing, so nothing is added to the device's library.
/// Safari and the extension follow the device language (English or Spanish).
final class ShareExtensionDeviceTests: XCTestCase {
    private func element(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func note(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShareFromSafariReachesTheAppGroup() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The App Group needs a signed device build.")
        #else
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCUIDevice.shared.system.open(URL(string: "https://example.com")!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(element(safari, ["Example Domain"]).waitForExistence(timeout: 30))
        sleep(2)
        note(safari, "1-safari")

        var share = element(safari, ["Share", "Compartir"])
        if !share.waitForExistence(timeout: 3) {
            // A compact Safari keeps Share in the page menu beside the address.
            let menu = element(safari, ["Page Menu", "Menú de página", "Menú de la página", "More", "Más"])
            if menu.waitForExistence(timeout: 3) { menu.tap() }
            note(safari, "2-menu")
            share = element(safari, ["Share", "Compartir"])
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        sleep(2)
        note(safari, "3-sheet")

        // Apps sit in their own row (identifier shareCell) after the people
        // suggestions (peopleCell). Only that row is scrolled and only Nodus
        // Reader or the row's More is ever tapped.
        let apps = safari.cells.matching(identifier: "shareCell")
        XCTAssertTrue(apps.firstMatch.waitForExistence(timeout: 10))
        let nodus = apps.matching(NSPredicate(format: "label == %@", "Nodus Reader")).firstMatch
        let rowY = apps.firstMatch.frame.midY
        let origin = safari.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<6 where !(nodus.exists && nodus.isHittable) {
            origin.withOffset(CGVector(dx: 380, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: rowY)))
            sleep(1)
        }
        if !(nodus.exists && nodus.isHittable) {
            let more = apps.matching(NSPredicate(format: "label IN %@", ["More", "Más"])).firstMatch
            if more.exists { more.tap() }
            note(safari, "3b-more")
        }
        let anyNodus = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Nodus Reader")).firstMatch
        let target = nodus.exists ? nodus : anyNodus
        XCTAssertTrue(target.waitForExistence(timeout: 10), "Nodus Reader is offered in the share sheet")
        target.tap()

        let title = element(safari, ["Import to Nodus Reader", "Importar a Nodus Reader"])
        XCTAssertTrue(title.waitForExistence(timeout: 20), "The Share Extension opened")
        note(safari, "4-extension")
        let unavailable = safari.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "App Group")).firstMatch
        XCTAssertFalse(unavailable.exists, "The extension reached the App Group")
        let importButton = element(safari, ["Import", "Importar"])
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        XCTAssertTrue(importButton.isEnabled, "The shared page can be imported")
        element(safari, ["Cancel", "Cancelar"]).tap()
        XCTAssertFalse(title.waitForExistence(timeout: 3), "Cancelled without importing")
        #endif
    }
}
