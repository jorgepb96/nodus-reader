// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation

/// Appearance and reading preferences that follow the user between devices
/// (plan §11–§12): app and reader theme, custom themes and typography.
/// Hardware-dependent settings (window size, audio route, brightness) and
/// everything about voices and models stay on the device.
struct SyncedPreferences: Codable, Equatable {
    var appTheme: String
    var readerFollowsApp: Bool
    var readerThemeSelection: String
    var customThemes: [CustomReaderTheme]
    var fontScale: Double
    var lineHeight: Double
    var margin: Double
    var justify: Bool
    var useSerif: Bool
    var weightIndex: Int
    var pageTurn: String
    var flow: String?

    @MainActor
    init(theme: ThemeManager, reading: ReaderPreferences) {
        appTheme = theme.appTheme.rawValue
        readerFollowsApp = theme.readerFollowsApp
        readerThemeSelection = theme.readerThemeSelection
        customThemes = theme.customThemes
        fontScale = reading.fontScale
        lineHeight = reading.lineHeight
        margin = reading.margin
        justify = reading.justify
        useSerif = reading.useSerif
        weightIndex = reading.weightIndex
        pageTurn = reading.pageTurn.rawValue
        flow = reading.flow.rawValue
    }

    @MainActor
    func apply(theme: ThemeManager, reading: ReaderPreferences) {
        theme.replaceCustomThemes(customThemes)
        if let app = NodusAppTheme(rawValue: appTheme), app != theme.appTheme {
            theme.appTheme = app
        }
        if theme.readerFollowsApp != readerFollowsApp { theme.readerFollowsApp = readerFollowsApp }
        if theme.readerThemeSelection != readerThemeSelection {
            theme.readerThemeSelection = readerThemeSelection
        }
        if reading.fontScale != fontScale { reading.fontScale = fontScale }
        if reading.lineHeight != lineHeight { reading.lineHeight = lineHeight }
        if reading.margin != margin { reading.margin = margin }
        if reading.justify != justify { reading.justify = justify }
        if reading.useSerif != useSerif { reading.useSerif = useSerif }
        if reading.weightIndex != weightIndex { reading.weightIndex = weightIndex }
        if let turn = PageTurnStyle(rawValue: pageTurn), reading.pageTurn != turn { reading.pageTurn = turn }
        if let flow, let value = ReadingFlow(rawValue: flow), reading.flow != value { reading.flow = value }
    }

    /// Deterministic bytes, so "changed since last sync" is a byte comparison.
    var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> SyncedPreferences? {
        try? JSONDecoder().decode(SyncedPreferences.self, from: data)
    }
}
