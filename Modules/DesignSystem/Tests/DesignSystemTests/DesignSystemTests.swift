// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Testing
@testable import DesignSystem

@Test func colourCanBeBuiltFromHex() {
    let colour = Color(hex: 0xC4B5FD)
    #expect(colour != Color.clear)
}
