// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Where appearance edits are written: the global preferences (synced with
/// the user's other devices) or one book's own override (synced with the book).
enum AppearanceTarget {
    case global
    case book(Book)

    var book: Book? {
        if case .book(let book) = self { return book }
        return nil
    }
}

/// Resolves the theme and typography the reader actually uses: a book's own
/// appearance when it has one, the global preferences otherwise.
@MainActor
enum ReaderAppearanceResolver {
    static func typography(for book: Book?, preferences: ReaderPreferences) -> ReaderTypography {
        book?.appearance?.typography ?? preferences.typography
    }

    static func themeSelection(for book: Book?, themeManager: ThemeManager) -> String {
        book?.appearance?.readerThemeSelection ?? themeManager.effectiveReaderSelection
    }

    static func theme(for book: Book?, themeManager: ThemeManager, colorScheme: ColorScheme) -> ReaderTheme {
        if let selection = book?.appearance?.readerThemeSelection {
            return themeManager.readerTheme(selection: selection, colorScheme: colorScheme)
        }
        return themeManager.readerTheme(colorScheme: colorScheme)
    }

    /// "This book only" starts from what the reader shows now, so switching it
    /// on never changes the page.
    static func snapshot(themeManager: ThemeManager, preferences: ReaderPreferences) -> BookAppearance {
        BookAppearance(readerThemeSelection: themeManager.effectiveReaderSelection,
                       typography: preferences.typography)
    }
}
