// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import SwiftUI

/// How the iOS/iPadOS paged reader moves between pages. The Mac uses a
/// two-page spread for paged reading and is not affected.
public enum PageTurnStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case curl
    case slide
    case vertical

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .curl: String(localized: "Page curl")
        case .slide: String(localized: "Slide")
        case .vertical: String(localized: "Vertical")
        }
    }
}

/// Paged reading, or free scrolling through the text: down a single column, or
/// sideways along a strip of columns.
public enum ReadingFlow: String, CaseIterable, Codable, Identifiable, Sendable {
    case paged
    case scrollVertical
    case scrollHorizontal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .paged: String(localized: "Paged")
        case .scrollVertical: String(localized: "Scroll down")
        case .scrollHorizontal: String(localized: "Scroll across")
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .paged: String(localized: "Paged")
        case .scrollVertical: String(localized: "Continuous vertical scroll")
        case .scrollHorizontal: String(localized: "Continuous horizontal scroll")
        }
    }

    public var isContinuous: Bool { self != .paged }
}

/// A complete set of reading typography. The global preferences and a book's
/// own override are both expressed as this value.
public struct ReaderTypography: Codable, Equatable, Sendable {
    public var fontScale: Double = 1
    public var lineHeight: Double = 1.55
    public var margin: Double = 28
    public var justify: Bool = true
    public var useSerif: Bool = true
    /// 0 = regular, 1 = medium, 2 = semibold.
    public var weightIndex: Int = 0
    public var pageTurn: PageTurnStyle = .curl
    public var flow: ReadingFlow = .paged

    public init() {}

    public static let fontScaleRange: ClosedRange<Double> = 0.8...1.6
    public static let lineHeightRange: ClosedRange<Double> = 1.2...2.0
    public static let marginRange: ClosedRange<Double> = 16...64

    public var baseFontSize: CGFloat {
        CGFloat(18.5 * fontScale)
    }

    public var lineSpacing: CGFloat {
        max(0, baseFontSize * CGFloat(lineHeight - 1))
    }

    public var fontWeight: Font.Weight {
        switch weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
    }

    public var summary: String {
        "\(useSerif ? String(localized: "Serif") : String(localized: "Sans")) · \(Int(baseFontSize.rounded())) pt"
    }

    // Tolerate payloads written before a field existed (synced books).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReaderTypography()
        fontScale = try container.decodeIfPresent(Double.self, forKey: .fontScale) ?? defaults.fontScale
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? defaults.lineHeight
        margin = try container.decodeIfPresent(Double.self, forKey: .margin) ?? defaults.margin
        justify = try container.decodeIfPresent(Bool.self, forKey: .justify) ?? defaults.justify
        useSerif = try container.decodeIfPresent(Bool.self, forKey: .useSerif) ?? defaults.useSerif
        weightIndex = try container.decodeIfPresent(Int.self, forKey: .weightIndex) ?? defaults.weightIndex
        pageTurn = (try? container.decodeIfPresent(PageTurnStyle.self, forKey: .pageTurn)) ?? defaults.pageTurn
        flow = (try? container.decodeIfPresent(ReadingFlow.self, forKey: .flow)) ?? defaults.flow
    }
}

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
        static let pageTurn = "nodus.reader.pageTurn"
        static let flow = "nodus.reader.flow"
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
    /// Reduce Motion always replaces the curl with a slide.
    public var pageTurn: PageTurnStyle {
        didSet { defaults.set(pageTurn.rawValue, forKey: Key.pageTurn) }
    }
    public var flow: ReadingFlow {
        didSet { defaults.set(flow.rawValue, forKey: Key.flow) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fontScale = defaults.object(forKey: Key.fontScale) as? Double ?? 1
        self.lineHeight = defaults.object(forKey: Key.lineHeight) as? Double ?? 1.55
        self.margin = defaults.object(forKey: Key.margin) as? Double ?? 28
        self.justify = defaults.object(forKey: Key.justify) as? Bool ?? true
        self.useSerif = defaults.object(forKey: Key.serif) as? Bool ?? true
        self.weightIndex = defaults.object(forKey: Key.weight) as? Int ?? 0
        self.pageTurn = (defaults.string(forKey: Key.pageTurn)).flatMap(PageTurnStyle.init(rawValue:)) ?? .curl
        self.flow = (defaults.string(forKey: Key.flow)).flatMap(ReadingFlow.init(rawValue:)) ?? .paged
    }

    /// The global typography as one value. Setting it writes only the fields
    /// that changed, so observers and `UserDefaults` see minimal updates.
    public var typography: ReaderTypography {
        get {
            var value = ReaderTypography()
            value.fontScale = fontScale
            value.lineHeight = lineHeight
            value.margin = margin
            value.justify = justify
            value.useSerif = useSerif
            value.weightIndex = weightIndex
            value.pageTurn = pageTurn
            value.flow = flow
            return value
        }
        set {
            if fontScale != newValue.fontScale { fontScale = newValue.fontScale }
            if lineHeight != newValue.lineHeight { lineHeight = newValue.lineHeight }
            if margin != newValue.margin { margin = newValue.margin }
            if justify != newValue.justify { justify = newValue.justify }
            if useSerif != newValue.useSerif { useSerif = newValue.useSerif }
            if weightIndex != newValue.weightIndex { weightIndex = newValue.weightIndex }
            if pageTurn != newValue.pageTurn { pageTurn = newValue.pageTurn }
            if flow != newValue.flow { flow = newValue.flow }
        }
    }

    public var baseFontSize: CGFloat { typography.baseFontSize }

    public var font: Font {
        .system(size: baseFontSize, weight: typography.fontWeight, design: useSerif ? .serif : .default)
    }

    public var lineSpacing: CGFloat { typography.lineSpacing }

    public func reset() {
        typography = ReaderTypography()
    }

    public var summary: String { typography.summary }
}
