// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct ReadingSettingsView: View {
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        ScrollView {
            ReaderAppearanceControls(target: .global, style: .full, showsTheme: false)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Reading & Typography")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
    }
}
