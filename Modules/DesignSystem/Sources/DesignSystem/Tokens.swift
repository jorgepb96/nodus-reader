// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Named colours from design/DESIGN.md that feature views use directly
/// (badges, the player's fixed dark chrome, PDF region overlays, smart-list
/// icons, narration word highlight). Keeping them here is the rule in
/// CLAUDE.md: no hex values in feature views.
public enum NodusColors {
    // Brand
    public static let lavender = Color(hex: NodusHex.lavender)
    public static let violet = Color(hex: NodusHex.violet)
    public static let onAccent = Color(hex: 0x16121F)

    // Accents used for smart lists and PDF region overlays
    public static let gold = Color(hex: 0xE9C46A)
    public static let slateBlue = Color(hex: 0x6E8CD8)
    public static let sage = Color(hex: 0x7FB89A)
    public static let rose = Color(hex: 0xE3A39D)
    public static let mutedGrey = Color(hex: 0xA8A3B5)

    // Cover badges (PDF, iCloud, downloading): always light on dark ink
    public static let coverBadgeText = Color(hex: 0xF2EFE8)
    public static let coverBadgeFill = Color(hex: 0x0E0D14, opacity: 0.82)

    // App-icon card (dark icon background, DESIGN.md §2)
    public static let iconBackgroundTop = Color(hex: 0x1D1929)
    public static let iconBackgroundBottom = Color(hex: 0x110F18)
    public static let iconHairline = Color(hex: NodusHex.lavender, opacity: 0.18)
}

/// Raw values where an API needs the number (custom theme defaults, AppKit /
/// UIKit colours built from hex).
public enum NodusHex {
    public static let lavender: UInt32 = 0xC4B5FD
    public static let violet: UInt32 = 0x7C3AED
    public static let lightPaper: UInt32 = 0xFBF8F1
    public static let lightInk: UInt32 = 0x1D1B22
    public static let deepViolet: UInt32 = 0x6D28D9
    /// Find in book: every match, and the one being shown.
    public static let searchMatch: UInt32 = 0xFDE68A
    public static let searchMatchDark: UInt32 = 0xB45309
    public static let searchCurrent: UInt32 = 0xFB923C
    public static let searchCurrentUnderline: UInt32 = 0xEA580C
}

/// Contents navigation: readable rows and a scrollbar with a full touch target.
public enum ReaderContentsLayout {
    public static let horizontalInset: CGFloat = 16
    public static let minimumRowHeight: CGFloat = 44
    public static let rowVerticalInset: CGFloat = 8
    public static let searchBottomInset: CGFloat = 12
    public static let scrollbarTouchWidth: CGFloat = 44
    public static let scrollbarInset: CGFloat = 8
    public static let minimumThumbHeight: CGFloat = 44
    public static let trackWidth: CGFloat = 3
    public static let thumbWidth: CGFloat = 8
}
