// SPDX-License-Identifier: AGPL-3.0-only
import Observation
import SwiftUI

// MARK: - App chrome themes

/// Themes available for the app chrome. The reader resolves the same names
/// into page palettes via `ReaderTheme`.
public enum NodusAppTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark
    case oled
    case sepia
    case highContrast

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .oled: String(localized: "OLED Black")
        case .sepia: String(localized: "Sepia")
        case .highContrast: String(localized: "High Contrast")
        }
    }

    /// Two-tone sample used by the theme tiles, mirroring design/Main.
    public var swatch: NodusThemeSwatch {
        switch self {
        case .system:
            NodusThemeSwatch(leading: Color(hex: 0xFBF8F1), trailing: Color(hex: 0x1C1A24),
                             label: Color(hex: 0x7C6FA0), border: Color.white.opacity(0.14))
        case .light:
            NodusThemeSwatch(leading: Color(hex: 0xFBF8F1), trailing: Color(hex: 0xFBF8F1),
                             label: Color(hex: 0x1D1B22), border: nil)
        case .dark:
            NodusThemeSwatch(leading: Color(hex: 0x1C1A24), trailing: Color(hex: 0x1C1A24),
                             label: Color(hex: 0xE6E1D6), border: Color.white.opacity(0.12))
        case .oled:
            NodusThemeSwatch(leading: .black, trailing: .black,
                             label: Color(hex: 0xCFCAC0), border: Color.white.opacity(0.16))
        case .sepia:
            NodusThemeSwatch(leading: Color(hex: 0xF2E7D3), trailing: Color(hex: 0xF2E7D3),
                             label: Color(hex: 0x3B2F20), border: nil)
        case .highContrast:
            NodusThemeSwatch(leading: .white, trailing: .white,
                             label: .black, border: .black, borderWidth: 2)
        }
    }
}

public struct NodusThemeSwatch: Sendable {
    public var leading: Color
    public var trailing: Color
    public var label: Color
    public var border: Color?
    public var borderWidth: CGFloat

    public init(leading: Color, trailing: Color, label: Color, border: Color?, borderWidth: CGFloat = 1) {
        self.leading = leading
        self.trailing = trailing
        self.label = label
        self.border = border
        self.borderWidth = borderWidth
    }
}

// MARK: - Palette

/// Concrete colours for one resolved appearance. Views read this from the
/// environment so no hex value leaks into feature code.
public struct NodusPalette {
    public var background: Color
    public var panel: Color
    public var panelRaised: Color
    public var sidebar: Color
    public var input: Color
    public var line: Color
    public var text: Color
    public var muted: Color
    public var accent: Color
    public var onAccent: Color
    public var violet: Color
    public var destructive: Color
    public var selection: Color
    public var shadow: Color
    public var isDark: Bool
    public var isHighContrast: Bool

    public init(background: Color, panel: Color, panelRaised: Color, sidebar: Color, input: Color,
                line: Color, text: Color, muted: Color, accent: Color, onAccent: Color,
                violet: Color, destructive: Color, selection: Color, shadow: Color, isDark: Bool,
                isHighContrast: Bool = false) {
        self.background = background
        self.panel = panel
        self.panelRaised = panelRaised
        self.sidebar = sidebar
        self.input = input
        self.line = line
        self.text = text
        self.muted = muted
        self.accent = accent
        self.onAccent = onAccent
        self.violet = violet
        self.destructive = destructive
        self.selection = selection
        self.shadow = shadow
        self.isDark = isDark
        self.isHighContrast = isHighContrast
    }

    public static let dark = NodusPalette(
        background: Color(hex: 0x0E0D14),
        panel: Color(hex: 0x17151F),
        panelRaised: Color(hex: 0x201D2C, opacity: 0.94),
        sidebar: Color(hex: 0x13111A),
        input: Color(hex: 0x1C1926),
        line: Color.white.opacity(0.08),
        text: Color(hex: 0xF2EFE8),
        muted: Color(hex: 0xA8A3B5),
        accent: Color(hex: 0xC4B5FD),
        onAccent: Color(hex: 0x16121F),
        violet: Color(hex: 0x7C3AED),
        destructive: Color(hex: 0xFF8F87),
        selection: Color(hex: 0xC4B5FD, opacity: 0.14),
        shadow: Color.black.opacity(0.45),
        isDark: true
    )

    public static let light = NodusPalette(
        background: Color(hex: 0xFBF8F1),
        panel: Color(hex: 0xFFFFFF),
        panelRaised: Color(hex: 0xFAF5EB, opacity: 0.96),
        sidebar: Color(hex: 0xF4EEE1),
        input: Color(hex: 0xEFE8DB),
        line: Color.black.opacity(0.09),
        text: Color(hex: 0x1D1B22),
        muted: Color(hex: 0x6B6577),
        accent: Color(hex: 0x6D28D9),
        onAccent: Color.white,
        violet: Color(hex: 0x6D28D9),
        destructive: Color(hex: 0xB3261E),
        selection: Color(hex: 0x6D28D9, opacity: 0.12),
        shadow: Color.black.opacity(0.18),
        isDark: false
    )

    public static let sepia = NodusPalette(
        background: Color(hex: 0xF2E7D3),
        panel: Color(hex: 0xF8F0E2),
        panelRaised: Color(hex: 0xFAF3E6, opacity: 0.96),
        sidebar: Color(hex: 0xE9DCC4),
        input: Color(hex: 0xE7DAC2),
        line: Color(hex: 0x3B2F20, opacity: 0.12),
        text: Color(hex: 0x3B2F20),
        muted: Color(hex: 0x6F5E46),
        accent: Color(hex: 0x5B21B6),
        onAccent: Color.white,
        violet: Color(hex: 0x5B21B6),
        destructive: Color(hex: 0x8C2F28),
        selection: Color(hex: 0x5B21B6, opacity: 0.12),
        shadow: Color(hex: 0x3B2F20, opacity: 0.2),
        isDark: false
    )

    public static let oled = NodusPalette(
        background: .black,
        panel: Color(hex: 0x111015),
        panelRaised: Color(hex: 0x18161F, opacity: 0.96),
        sidebar: Color(hex: 0x0A0A0D),
        input: Color(hex: 0x16141C),
        line: Color.white.opacity(0.09),
        text: Color(hex: 0xCFCAC0),
        muted: Color(hex: 0x9A95A3),
        accent: Color(hex: 0xC4B5FD),
        onAccent: Color(hex: 0x16121F),
        violet: Color(hex: 0x7C3AED),
        destructive: Color(hex: 0xFF8F87),
        selection: Color(hex: 0xC4B5FD, opacity: 0.15),
        shadow: Color.black.opacity(0.6),
        isDark: true
    )

    public static let highContrast = NodusPalette(
        background: .white,
        panel: .white,
        panelRaised: .white,
        sidebar: .white,
        input: Color(hex: 0xF0F0F0),
        line: .black,
        text: .black,
        muted: Color(hex: 0x333333),
        accent: Color(hex: 0x4C1D95),
        onAccent: .white,
        violet: Color(hex: 0x4C1D95),
        destructive: Color(hex: 0x8B0000),
        selection: Color(hex: 0xEDE9FE),
        shadow: Color.black.opacity(0.25),
        isDark: false,
        isHighContrast: true
    )

    /// The palette for everything shown over the reader (player, sheets,
    /// popovers): the reader theme's own colours on the structure of the
    /// matching app palette, so a sheet never shows a different background
    /// from the page behind it. Panels of the dark and custom themes are drawn
    /// from their text colour, which keeps them a step lighter or darker than
    /// the reader's own background.
    public static func reader(_ theme: ReaderTheme) -> NodusPalette {
        var palette: NodusPalette
        switch theme.id {
        case .light?: palette = .light
        case .sepia?: palette = .sepia
        case .oled?: palette = .oled
        case .highContrast?: palette = .highContrast
        case .dark?, .system?, nil: palette = theme.isDark ? .dark : .light
        }
        palette.background = theme.background
        palette.text = theme.text
        palette.muted = theme.muted
        palette.accent = theme.accent
        palette.line = theme.line
        if theme.id == .dark || theme.id == nil {
            palette.panel = theme.text.opacity(0.06)
            palette.panelRaised = theme.text.opacity(0.09)
            palette.input = theme.text.opacity(0.08)
            palette.sidebar = theme.background
            palette.selection = theme.accent.opacity(0.16)
            palette.violet = theme.accent
            palette.onAccent = theme.background
        }
        return palette
    }

    public static func palette(for theme: NodusAppTheme, colorScheme: ColorScheme) -> NodusPalette {
        switch theme {
        case .system:
            return colorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        case .oled:
            return .oled
        case .sepia:
            return .sepia
        case .highContrast:
            return .highContrast
        }
    }
}

// MARK: - Reader themes

public enum ReaderThemeID: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark
    case oled
    case sepia
    case highContrast

    public var id: String { rawValue }
    public var appTheme: NodusAppTheme { NodusAppTheme(rawValue: rawValue) ?? .system }
}

public struct ReaderTheme {
    public var id: ReaderThemeID?
    public var customID: UUID?
    public var name: String
    public var background: Color
    public var text: Color
    public var muted: Color
    public var narration: Color
    public var userHighlight: Color
    public var note: Color
    public var accent: Color
    public var line: Color
    public var isDark: Bool

    public init(id: ReaderThemeID?, customID: UUID? = nil, name: String, background: Color, text: Color,
                muted: Color, narration: Color, userHighlight: Color, note: Color,
                accent: Color, line: Color, isDark: Bool) {
        self.id = id
        self.customID = customID
        self.name = name
        self.background = background
        self.text = text
        self.muted = muted
        self.narration = narration
        self.userHighlight = userHighlight
        self.note = note
        self.accent = accent
        self.line = line
        self.isDark = isDark
    }

    public static func custom(_ theme: CustomReaderTheme) -> ReaderTheme {
        let background = Color(hex: theme.backgroundHex)
        let text = Color(hex: theme.textHex)
        let accent = Color(hex: theme.accentHex)
        return ReaderTheme(
            id: nil,
            customID: theme.id,
            name: theme.name,
            background: background,
            text: text,
            muted: text.opacity(0.66),
            narration: accent.opacity(theme.isDark ? 0.28 : 0.22),
            userHighlight: theme.isDark ? Color(hex: 0xC9A24B, opacity: 0.28) : Color(hex: 0xFBEFC0),
            note: theme.isDark ? Color(hex: 0xE8C98F) : Color(hex: 0xA16207),
            accent: accent,
            line: text.opacity(0.14),
            isDark: theme.isDark
        )
    }

    public static func resolve(_ id: ReaderThemeID, colorScheme: ColorScheme) -> ReaderTheme {
        switch id {
        case .system:
            return resolve(colorScheme == .dark ? .dark : .light, colorScheme: colorScheme)
        case .light:
            return ReaderTheme(
                id: .light, name: "Light",
                background: Color(hex: 0xFBF8F1), text: Color(hex: 0x1D1B22),
                muted: Color(hex: 0x6B6577), narration: Color(hex: 0xE7DEFD),
                userHighlight: Color(hex: 0xFBEFC0), note: Color(hex: 0xA16207),
                accent: Color(hex: 0x6D28D9), line: Color.black.opacity(0.1), isDark: false)
        case .sepia:
            return ReaderTheme(
                id: .sepia, name: "Sepia",
                background: Color(hex: 0xF2E7D3), text: Color(hex: 0x3B2F20),
                muted: Color(hex: 0x6F5E46), narration: Color(hex: 0xE2D3F2),
                userHighlight: Color(hex: 0xF3DE9C), note: Color(hex: 0x8A5A00),
                accent: Color(hex: 0x5B21B6), line: Color(hex: 0x3B2F20, opacity: 0.14), isDark: false)
        case .dark:
            return ReaderTheme(
                id: .dark, name: "Dark",
                background: Color(hex: 0x1C1A24), text: Color(hex: 0xE6E1D6),
                muted: Color(hex: 0xA39DAF), narration: Color(hex: 0x7C3AED, opacity: 0.28),
                userHighlight: Color(hex: 0xC9A24B, opacity: 0.28), note: Color(hex: 0xE8C98F),
                accent: Color(hex: 0xC4B5FD), line: Color.white.opacity(0.1), isDark: true)
        case .oled:
            return ReaderTheme(
                id: .oled, name: "OLED Black",
                background: .black, text: Color(hex: 0xCFCAC0),
                muted: Color(hex: 0x9A95A3), narration: Color(hex: 0x7C3AED, opacity: 0.30),
                userHighlight: Color(hex: 0xC9A24B, opacity: 0.30), note: Color(hex: 0xE8C98F),
                accent: Color(hex: 0xC4B5FD), line: Color.white.opacity(0.12), isDark: true)
        case .highContrast:
            return ReaderTheme(
                id: .highContrast, name: "High Contrast",
                background: .white, text: .black,
                muted: Color(hex: 0x333333), narration: Color(hex: 0xDDD6FE),
                userHighlight: Color(hex: 0xFFF3B0), note: Color(hex: 0x3F3F46),
                accent: Color(hex: 0x4C1D95), line: .black, isDark: false)
        }
    }
}

// MARK: - Custom themes

public struct CustomReaderTheme: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var backgroundHex: UInt32
    public var textHex: UInt32
    public var accentHex: UInt32
    public var isDark: Bool

    public init(id: UUID = UUID(), name: String, backgroundHex: UInt32,
                textHex: UInt32, accentHex: UInt32, isDark: Bool) {
        self.id = id
        self.name = name
        self.backgroundHex = backgroundHex
        self.textHex = textHex
        self.accentHex = accentHex
        self.isDark = isDark
    }

    public var readerTheme: ReaderTheme {
        ReaderTheme.custom(self)
    }
}

// MARK: - Theme manager

/// Persists the user's app and reader appearance. Hardware-specific settings
/// (brightness, audio) deliberately live outside this object.
@Observable
public final class ThemeManager {
    private enum Key {
        static let appTheme = "nodus.theme.app"
        static let readerTheme = "nodus.theme.reader"
        static let customThemes = "nodus.theme.custom"
        static let readerFollowsApp = "nodus.theme.readerFollowsApp.v2"
    }

    private let defaults: UserDefaults

    public var appTheme: NodusAppTheme {
        didSet {
            defaults.set(appTheme.rawValue, forKey: Key.appTheme)
            if readerFollowsApp {
                readerThemeSelection = Self.matchingReaderTheme(for: appTheme).rawValue
            }
        }
    }

    /// When true, the reader uses the same theme family as the app. Selecting a
    /// different reader theme turns this off; the UI exposes a way to restore it.
    public var readerFollowsApp: Bool {
        didSet { defaults.set(readerFollowsApp, forKey: Key.readerFollowsApp) }
    }

    /// Either a `ReaderThemeID` raw value or `custom:<uuid>`.
    public var readerThemeSelection: String {
        didSet { defaults.set(readerThemeSelection, forKey: Key.readerTheme) }
    }

    public private(set) var customThemes: [CustomReaderTheme] {
        didSet {
            if let data = try? JSONEncoder().encode(customThemes) {
                defaults.set(data, forKey: Key.customThemes)
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let appTheme = NodusAppTheme(rawValue: defaults.string(forKey: Key.appTheme) ?? "") ?? .dark
        self.appTheme = appTheme
        // The reader follows the app's light/dark/sepia family by default, so a
        // dark interface never opens onto a light page. Users can still pick a
        // different reader theme explicitly.
        let follows = defaults.object(forKey: Key.readerFollowsApp).map { _ in
            defaults.bool(forKey: Key.readerFollowsApp)
        } ?? true
        self.readerFollowsApp = follows
        self.readerThemeSelection = follows
            ? Self.matchingReaderTheme(for: appTheme).rawValue
            : (defaults.string(forKey: Key.readerTheme) ?? ReaderThemeID.light.rawValue)
        if let data = defaults.data(forKey: Key.customThemes),
           let themes = try? JSONDecoder().decode([CustomReaderTheme].self, from: data) {
            self.customThemes = themes
        } else {
            self.customThemes = []
        }
    }

    /// Replaces the custom themes with the copy synced from another device.
    public func replaceCustomThemes(_ themes: [CustomReaderTheme]) {
        guard themes != customThemes else { return }
        customThemes = themes
    }

    public static func matchingReaderTheme(for appTheme: NodusAppTheme) -> ReaderThemeID {
        switch appTheme {
        case .system: .system
        case .light: .light
        case .dark: .dark
        case .oled: .oled
        case .sepia: .sepia
        case .highContrast: .highContrast
        }
    }

    public func palette(colorScheme: ColorScheme) -> NodusPalette {
        NodusPalette.palette(for: appTheme, colorScheme: colorScheme)
    }

    public func readerTheme(colorScheme: ColorScheme) -> ReaderTheme {
        if let custom = selectedCustomTheme, !readerFollowsApp {
            return custom.readerTheme
        }
        let id = readerFollowsApp
            ? Self.matchingReaderTheme(for: appTheme)
            : (ReaderThemeID(rawValue: readerThemeSelection) ?? .system)
        return ReaderTheme.resolve(id, colorScheme: colorScheme)
    }

    /// Resolves a stored selection (`ReaderThemeID` raw value or
    /// `custom:<uuid>`), for example a book's own theme. A deleted custom theme
    /// falls back to the current reader theme.
    public func readerTheme(selection: String, colorScheme: ColorScheme) -> ReaderTheme {
        if selection.hasPrefix("custom:") {
            let uuid = UUID(uuidString: String(selection.dropFirst("custom:".count)))
            if let custom = customThemes.first(where: { $0.id == uuid }) {
                return custom.readerTheme
            }
            return readerTheme(colorScheme: colorScheme)
        }
        guard let id = ReaderThemeID(rawValue: selection) else {
            return readerTheme(colorScheme: colorScheme)
        }
        return ReaderTheme.resolve(id, colorScheme: colorScheme)
    }

    /// The selection string currently in effect for the reader.
    public var effectiveReaderSelection: String {
        readerFollowsApp ? Self.matchingReaderTheme(for: appTheme).rawValue : readerThemeSelection
    }

    public var selectedReaderThemeID: ReaderThemeID? {
        readerFollowsApp
            ? Self.matchingReaderTheme(for: appTheme)
            : ReaderThemeID(rawValue: readerThemeSelection)
    }

    public var selectedCustomTheme: CustomReaderTheme? {
        guard readerThemeSelection.hasPrefix("custom:"),
              let uuid = UUID(uuidString: String(readerThemeSelection.dropFirst("custom:".count))) else {
            return nil
        }
        return customThemes.first { $0.id == uuid }
    }

    public func selectReaderTheme(_ id: ReaderThemeID) {
        readerFollowsApp = false
        readerThemeSelection = id.rawValue
    }

    public func selectCustomTheme(_ theme: CustomReaderTheme) {
        readerFollowsApp = false
        readerThemeSelection = "custom:\(theme.id.uuidString)"
    }

    public func followAppTheme() {
        readerFollowsApp = true
        readerThemeSelection = Self.matchingReaderTheme(for: appTheme).rawValue
    }

    @discardableResult
    public func addCustomTheme(name: String, backgroundHex: UInt32, textHex: UInt32,
                               accentHex: UInt32, isDark: Bool) -> CustomReaderTheme {
        let theme = CustomReaderTheme(name: name, backgroundHex: backgroundHex,
                                      textHex: textHex, accentHex: accentHex, isDark: isDark)
        customThemes.append(theme)
        selectCustomTheme(theme)
        return theme
    }

    public func deleteCustomTheme(_ theme: CustomReaderTheme) {
        customThemes.removeAll { $0.id == theme.id }
        if readerThemeSelection == "custom:\(theme.id.uuidString)" {
            selectReaderTheme(.system)
        }
    }

    public func updateCustomTheme(_ theme: CustomReaderTheme) {
        if let index = customThemes.firstIndex(where: { $0.id == theme.id }) {
            customThemes[index] = theme
        } else {
            customThemes.append(theme)
        }
        selectCustomTheme(theme)
    }
}

// MARK: - Environment

private struct NodusPaletteKey: EnvironmentKey {
    static let defaultValue = NodusPalette.dark
}

public extension EnvironmentValues {
    var nodusPalette: NodusPalette {
        get { self[NodusPaletteKey.self] }
        set { self[NodusPaletteKey.self] = newValue }
    }
}

public extension View {
    func nodusPalette(_ palette: NodusPalette) -> some View {
        environment(\.nodusPalette, palette)
    }
}
