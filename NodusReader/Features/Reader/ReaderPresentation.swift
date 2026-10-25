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
    func readerPresentation(isDark: Bool) -> some View {
        let palette: NodusPalette = isDark ? .dark : .light
        return self
            .nodusPalette(palette)
            .tint(palette.accent)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .preferredColorScheme(isDark ? .dark : .light)
    }
}
