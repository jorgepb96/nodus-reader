// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

extension View {
    /// Everything the reader presents (sheets, popovers) takes the reader's
    /// colour scheme on both sides: SwiftUI views and our palette through the
    /// environment, and the system chrome (navigation bar, list background,
    /// segmented controls, popover material) through `preferredColorScheme`.
    /// Setting only one of them mixed a dark header with a white list, or dark
    /// labels on a dark panel, when the reader theme differs from the app's.
    /// The palette comes from the reader theme itself, so a sheet over a
    /// sepia, dark or custom page has that page's colours.
    func readerPresentation(_ theme: ReaderTheme) -> some View {
        let palette = NodusPalette.reader(theme)
        return self
            .nodusPalette(palette)
            .tint(palette.accent)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
