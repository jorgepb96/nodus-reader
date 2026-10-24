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
    private let text: String

    public init(_ text: String, size: CGFloat = 36) {
        self.text = text
        self.baseSize = size
    }

    public var body: some View {
        Text(text)
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

    public init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(NodusType.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(color ?? palette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct SectionHeading: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(.title3, design: .serif))
            .accessibilityAddTraits(.isHeader)
    }
}
