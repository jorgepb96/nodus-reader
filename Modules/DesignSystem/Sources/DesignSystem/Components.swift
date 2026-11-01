// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

// MARK: - Brand

/// `NodusMark + NODUS / READER`, used in every navigation toolbar and sidebar.
public struct BrandToolbar: View {
    @Environment(\.nodusPalette) private var palette

    public init() {}

    public var body: some View {
        HStack(spacing: 7) {
            NodusMark()
                .frame(width: 19, height: 21)
            Text("NODUS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(3)
                .foregroundStyle(palette.accent)
            Text("/ READER")
                .font(.system(size: 10, weight: .medium))
                .tracking(2)
                .foregroundStyle(palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nodus Reader")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Controls

public struct CircleIconButton: View {
    @Environment(\.nodusPalette) private var palette

    private let systemName: String
    private let label: Text
    private let filled: Bool
    private let action: () -> Void

    public init(_ systemName: String, label: LocalizedStringKey, filled: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = Text(label)
        self.filled = filled
        self.action = action
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ systemName: String, label: S, filled: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = Text(label)
        self.filled = filled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(filled ? palette.accent : palette.text)
                .frame(width: 44, height: 44)
                .background(filled ? palette.selection : palette.panel, in: Circle())
                .overlay(Circle().stroke(filled ? Color.clear : palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(label)
    }
}

public struct CapsuleChip: View {
    @Environment(\.nodusPalette) private var palette

    private let title: Text
    private let isSelected: Bool
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, isSelected: Bool, action: @escaping () -> Void) {
        self.title = Text(title)
        self.isSelected = isSelected
        self.action = action
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, isSelected: Bool, action: @escaping () -> Void) {
        self.title = Text(title)
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            title
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? palette.onAccent : palette.text)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(isSelected ? palette.accent : palette.panel, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public struct PrimaryPillButton: View {
    @Environment(\.nodusPalette) private var palette

    private let title: Text
    private let systemImage: String?
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.action = action
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                title.font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(palette.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

public struct OutlinePillButton: View {
    @Environment(\.nodusPalette) private var palette

    private let title: Text
    private let systemImage: String?
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.action = action
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .medium))
                }
                title.font(.subheadline.weight(.medium))
            }
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.clear, in: Capsule())
            .overlay(
                Capsule().stroke(palette.isHighContrast ? palette.text : palette.accent.opacity(0.35),
                                 lineWidth: palette.isHighContrast ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct NodusProgressBar: View {
    @Environment(\.nodusPalette) private var palette

    private let value: Double
    private let height: CGFloat

    public init(value: Double, height: CGFloat = 4) {
        self.value = min(max(value, 0), 1)
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.text.opacity(palette.isDark ? 0.10 : 0.12))
                Capsule().fill(palette.accent)
                    .frame(width: max(0, proxy.size.width * value))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Cards

public struct PanelCardModifier: ViewModifier {
    @Environment(\.nodusPalette) private var palette
    private let radius: CGFloat

    public init(radius: CGFloat = 20) {
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .background(palette.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(palette.line, lineWidth: 1)
            )
    }
}

public extension View {
    func panelCard(radius: CGFloat = 20) -> some View {
        modifier(PanelCardModifier(radius: radius))
    }
}

// MARK: - Covers

/// The typographic cover language from design/: an author eyebrow over a serif
/// title on a flat, deterministic colour. Real covers replace it when available.
public struct CoverArtwork: View {
    public var author: String
    public var title: String
    public var background: Color
    public var foreground: Color
    public var formatBadge: String?
    public var cloudOnly: Bool
    public var downloadingProgress: Double?
    public var selected: Bool

    public init(author: String, title: String, background: Color, foreground: Color,
                formatBadge: String? = nil, cloudOnly: Bool = false,
                downloadingProgress: Double? = nil, selected: Bool = false) {
        self.author = author
        self.title = title
        self.background = background
        self.foreground = foreground
        self.formatBadge = formatBadge
        self.cloudOnly = cloudOnly
        self.downloadingProgress = downloadingProgress
        self.selected = selected
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let titleSize = max(12, min(width * 0.13, 120))
            let eyebrowSize = max(6.5, min(width * 0.04, 24))
            let padding = max(6, width * 0.07)

            ZStack(alignment: .topLeading) {
                background
                LinearGradient(colors: [Color.white.opacity(0.10), .clear, Color.black.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                VStack(alignment: .leading, spacing: 0) {
                    Text(author.uppercased())
                        .font(.system(size: eyebrowSize, weight: .regular))
                        .tracking(eyebrowSize * 0.18)
                        .foregroundStyle(foreground.opacity(0.86))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(title)
                        .font(.system(size: titleSize, weight: .regular, design: .serif))
                        .foregroundStyle(foreground)
                        .lineLimit(6)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(.leading)
                }
                .padding(padding)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)

                if let formatBadge {
                    Text(formatBadge.uppercased())
                        .font(.system(size: max(7, width * 0.045), weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color(hex: 0xF2EFE8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0x0E0D14, opacity: 0.82), in: RoundedRectangle(cornerRadius: 4))
                        .padding(max(5, width * 0.05))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
                }

                if cloudOnly {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: max(9, width * 0.06), weight: .medium))
                        .foregroundStyle(Color(hex: 0xF2EFE8))
                        .frame(width: max(20, width * 0.16), height: max(20, width * 0.16))
                        .background(Color(hex: 0x0E0D14, opacity: 0.82), in: Circle())
                        .padding(max(5, width * 0.05))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
                }

                if let downloadingProgress {
                    VStack {
                        Spacer()
                        NodusProgressBar(value: downloadingProgress, height: 3)
                            .padding(6)
                    }
                }
            }
            .clipShape(CoverShape())
            .overlay(
                CoverShape().stroke(selected ? Color(hex: 0xC4B5FD) : Color.black.opacity(0.08),
                                    lineWidth: selected ? 3 : 0.5)
            )
            .shadow(color: .black.opacity(0.42), radius: max(6, width * 0.08), x: 0, y: max(5, width * 0.06))
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), by \(author)"))
    }
}

public struct CoverShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let radii = RectangleCornerRadii(topLeading: 3, bottomLeading: 3,
                                         bottomTrailing: 8, topTrailing: 8)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}

/// Deterministic cover colours. The app derives a palette from a title so a
/// generated cover stays stable between launches and devices.
public enum CoverPalette {
    public struct Pair: Sendable {
        public let background: Color
        public let foreground: Color
    }

    public static let all: [Pair] = [
        Pair(background: Color(hex: 0x1F3A4D), foreground: Color(hex: 0xEDE6D6)),
        Pair(background: Color(hex: 0xC9A24B), foreground: Color(hex: 0x231B0E)),
        Pair(background: Color(hex: 0xEDEBE4), foreground: Color(hex: 0x1E1E1E)),
        Pair(background: Color(hex: 0x3F5A55), foreground: Color(hex: 0xEAF0E8)),
        Pair(background: Color(hex: 0x8C3B2E), foreground: Color(hex: 0xF4E9DC)),
        Pair(background: Color(hex: 0x2B2738), foreground: Color(hex: 0xD8CCF5)),
        Pair(background: Color(hex: 0x6E4E6F), foreground: Color(hex: 0xF3E9F0)),
        Pair(background: Color(hex: 0xB9C4B0), foreground: Color(hex: 0x1F2A1E)),
        Pair(background: Color(hex: 0x23201C), foreground: Color(hex: 0xE8C98F)),
        Pair(background: Color(hex: 0x5B6E8C), foreground: Color(hex: 0xF2F0EA)),
        Pair(background: Color(hex: 0xE4D3A8), foreground: Color(hex: 0x2F2A1C)),
        Pair(background: Color(hex: 0x262629), foreground: Color(hex: 0xE6DED0)),
        Pair(background: Color(hex: 0xC66B3D), foreground: Color(hex: 0xFFF4EA)),
        Pair(background: Color(hex: 0xD9C9A8), foreground: Color(hex: 0x2A2117)),
        Pair(background: Color(hex: 0x4E6B4A), foreground: Color(hex: 0xF1EDE1)),
        Pair(background: Color(hex: 0x2E3A5C), foreground: Color(hex: 0xE9E4F5)),
        Pair(background: Color(hex: 0xB04A2F), foreground: Color(hex: 0xFBEFE4)),
        Pair(background: Color(hex: 0x1E1B16), foreground: Color(hex: 0xE8C98F))
    ]

    /// Canonical colours for the public-domain sample titles, so the sample
    /// library matches design/screens/. Everything else is deterministic.
    private static let knownPairs: [String: Pair] = [
        "Moby-Dick": Pair(background: Color(hex: 0x1F3A4D), foreground: Color(hex: 0xEDE6D6)),
        "Don Quijote de la Mancha": Pair(background: Color(hex: 0xC9A24B), foreground: Color(hex: 0x231B0E)),
        "Experiments in Plant Hybridization": Pair(background: Color(hex: 0xEDEBE4), foreground: Color(hex: 0x1E1E1E)),
        "Walden": Pair(background: Color(hex: 0x3F5A55), foreground: Color(hex: 0xEAF0E8)),
        "Homage to Catalonia": Pair(background: Color(hex: 0x8C3B2E), foreground: Color(hex: 0xF4E9DC)),
        "Meditations": Pair(background: Color(hex: 0x2B2738), foreground: Color(hex: 0xD8CCF5)),
        "Middlemarch": Pair(background: Color(hex: 0x6E4E6F), foreground: Color(hex: 0xF3E9F0)),
        "On the Origin of Species": Pair(background: Color(hex: 0xB9C4B0), foreground: Color(hex: 0x1F2A1E)),
        "The Odyssey": Pair(background: Color(hex: 0x23201C), foreground: Color(hex: 0xE8C98F)),
        "The Spanish Civil War": Pair(background: Color(hex: 0x2E3A5C), foreground: Color(hex: 0xE9E4F5)),
        "The Spanish Labyrinth": Pair(background: Color(hex: 0xD9C9A8), foreground: Color(hex: 0x2A2117)),
        "Journey to the Alcarria": Pair(background: Color(hex: 0x4E6B4A), foreground: Color(hex: 0xF1EDE1))
    ]

    public static func pair(for seed: String) -> Pair {
        if let known = knownPairs[seed] { return known }
        if let known = knownPairs.first(where: { seed.hasPrefix($0.key) })?.value { return known }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return all[Int(hash % UInt64(all.count))]
    }
}

// MARK: - Empty states

public struct NodusEmptyState: View {
    @Environment(\.nodusPalette) private var palette

    private let icon: String
    private let title: Text
    private let message: Text

    public init(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.icon = icon
        self.title = Text(title)
        self.message = Text(message)
    }

    @_disfavoredOverload
    public init<S1: StringProtocol, S2: StringProtocol>(icon: String, title: S1, message: S2) {
        self.icon = icon
        self.title = Text(title)
        self.message = Text(message)
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(palette.accent)
                .frame(width: 64, height: 64)
                .background(palette.selection, in: Circle())
            title
                .font(.system(.title3, design: .serif))
                .multilineTextAlignment(.center)
            message
                .font(.subheadline)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// A ring that turns around a round button while something it starts is
/// getting ready (a voice model loading into memory, a sentence being made).
/// With Reduce Motion it is a still, full ring.
public struct LoadingRing: View {
    let color: Color
    let lineWidth: CGFloat
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color, lineWidth: CGFloat = 3) {
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            if !reduceMotion {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
                    .onAppear { turning = true }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// A native slider with its label and current value above it, for settings
/// and compact panels. The value is read to VoiceOver as shown.
public struct LabeledSlider: View {
    @Environment(\.nodusPalette) private var palette

    private let title: Text
    private let accessibilityTitle: Text
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let display: String
    private let systemImage: String?

    public init(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double> = 0...1,
                step: Double? = nil, display: String, systemImage: String? = nil) {
        self.title = Text(title)
        self.accessibilityTitle = Text(title)
        self._value = value
        self.range = range
        self.step = step
        self.display = display
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
                title
                    .foregroundStyle(palette.text)
                Spacer()
                Text(display)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
            .font(.footnote)
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .tint(palette.accent)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(Text(display))
        }
    }
}
