// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

public enum NodusType {
    /// Serif display face (New York on Apple platforms), tracking from design/DESIGN.md.
    public static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    public static func interface(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default).weight(weight)
    }

    public static let displayTracking: CGFloat = -0.9
    public static let eyebrowTracking: CGFloat = 2
}

/// Large serif editorial title that still scales with Dynamic Type.
public struct DisplayTitle: View {
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    private let baseSize: CGFloat
    private let text: Text

    /// A literal is looked up in the app's string catalog, like `Text`.
    public init(_ key: LocalizedStringKey, size: CGFloat = 36) {
        self.text = Text(key)
        self.baseSize = size
    }

    /// Data (a book or collection name) is shown as it is.
    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S, size: CGFloat = 36) {
        self.text = Text(text)
        self.baseSize = size
    }

    public var body: some View {
        text
            .font(.system(size: baseSize * typeScale, weight: .regular, design: .serif))
            .tracking(baseSize * NodusType.displayTracking / 36)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct Eyebrow: View {
    @Environment(\.nodusPalette) private var palette

    private let text: String
    private let color: Color?

    /// A literal is translated through the app's string catalog. It is
    /// resolved here, not by `Text`, because a localized `Text` also turns its
    /// accessibility label into capitals, which VoiceOver may spell out.
    public init(_ resource: LocalizedStringResource, color: Color? = nil) {
        self.text = String(localized: resource)
        self.color = color
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S, color: Color? = nil) {
        self.text = String(text)
        self.color = color
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .tracking(NodusType.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(color ?? palette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct SectionHeading: View {
    private let text: Text

    public init(_ key: LocalizedStringKey) {
        self.text = Text(key)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S) {
        self.text = Text(text)
    }

    public var body: some View {
        text
            .font(.system(.title3, design: .serif))
            .accessibilityAddTraits(.isHeader)
    }
}
