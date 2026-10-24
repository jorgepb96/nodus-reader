// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public extension Color {
    /// Creates a colour from a 24-bit RGB hex value, e.g. `Color(hex: 0xC4B5FD)`.
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// The sRGB value used by the custom-theme editor and persistence.
    var rgbHex: UInt32 {
        #if os(macOS)
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return Self.pack(color.redComponent, color.greenComponent, color.blueComponent)
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Self.pack(red, green, blue)
        #endif
    }

    var isPerceptuallyDark: Bool {
        let hex = rgbHex
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.5
    }

    private static func pack(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UInt32 {
        let r = UInt32(max(0, min(255, (red * 255).rounded())))
        let g = UInt32(max(0, min(255, (green * 255).rounded())))
        let b = UInt32(max(0, min(255, (blue * 255).rounded())))
        return (r << 16) | (g << 8) | b
    }
}
