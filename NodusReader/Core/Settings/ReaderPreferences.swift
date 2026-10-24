// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import SwiftUI

/// Typography and reading preferences. Hardware-specific settings (brightness,
/// audio route) are intentionally not stored here.
@Observable
public final class ReaderPreferences {
    private enum Key {
        static let fontScale = "nodus.reader.fontScale"
        static let lineHeight = "nodus.reader.lineHeight"
        static let margin = "nodus.reader.margin"
        static let justify = "nodus.reader.justify"
        static let serif = "nodus.reader.serif"
        static let weight = "nodus.reader.weight"
    }

    private let defaults: UserDefaults

    public var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: Key.fontScale) }
    }
    public var lineHeight: Double {
        didSet { defaults.set(lineHeight, forKey: Key.lineHeight) }
    }
    public var margin: Double {
        didSet { defaults.set(margin, forKey: Key.margin) }
    }
    public var justify: Bool {
        didSet { defaults.set(justify, forKey: Key.justify) }
    }
    public var useSerif: Bool {
        didSet { defaults.set(useSerif, forKey: Key.serif) }
    }
    /// 0 = regular, 1 = medium, 2 = semibold.
    public var weightIndex: Int {
        didSet { defaults.set(weightIndex, forKey: Key.weight) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fontScale = defaults.object(forKey: Key.fontScale) as? Double ?? 1
        self.lineHeight = defaults.object(forKey: Key.lineHeight) as? Double ?? 1.55
        self.margin = defaults.object(forKey: Key.margin) as? Double ?? 28
        self.justify = defaults.object(forKey: Key.justify) as? Bool ?? true
        self.useSerif = defaults.object(forKey: Key.serif) as? Bool ?? true
        self.weightIndex = defaults.object(forKey: Key.weight) as? Int ?? 0
    }

    public var baseFontSize: CGFloat {
        CGFloat(18.5 * fontScale)
    }

    public var font: Font {
        let weight: Font.Weight = switch weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
        return .system(size: baseFontSize, weight: weight, design: useSerif ? .serif : .default)
    }

    public var lineSpacing: CGFloat {
        max(0, baseFontSize * CGFloat(lineHeight - 1))
    }

    public func reset() {
        fontScale = 1
        lineHeight = 1.55
        margin = 28
        justify = true
        useSerif = true
        weightIndex = 0
    }

    public var summary: String {
        "\(useSerif ? "Serif" : "Sans") · \(Int(baseFontSize.rounded())) pt"
    }
}
