// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReaderPageHighlightSpan: Equatable {
    var range: NSRange
    var fill: PlatformColor
    var underline: PlatformColor?
    var underlineWidth: CGFloat
    var rounded: Bool
}

struct ReaderPageHighlights: Equatable {
    var spans: [ReaderPageHighlightSpan] = []
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}
