// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// The full appearance editor opened from the reader popover's "More
/// settings…": every typography control, the preview and custom themes.
struct ReaderAppearanceSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let book: Book

    @State private var editorContext: ThemeEditorContext?
    @State private var pendingDelete: CustomReaderTheme?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ReaderAppearanceControls(target: .book(book), style: .full)

                    Eyebrow("Custom themes")
                        .padding(.top, 8)
                    Button {
                        editorContext = ThemeEditorContext(theme: nil)
                    } label: {
                        Label("Create custom theme", systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    ForEach(themeManager.customThemes) { custom in
                        HStack {
                            (custom.name.isEmpty ? Text("Custom") : Text(custom.name))
                                .font(.footnote)
                            Spacer()
                            Button("Edit") { editorContext = ThemeEditorContext(theme: custom) }
                                .font(.footnote)
                            Button("Delete", role: .destructive) {
                                pendingDelete = custom
                                showDeleteConfirmation = true
                            }
                            .font(.footnote)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(palette.background)
            .navigationTitle("Appearance")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editorContext) { context in
                CustomThemeEditor(existing: context.theme)
            }
            .confirmationDialog("Delete Custom Theme?", isPresented: $showDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete Theme", role: .destructive) {
                    if let pendingDelete { themeManager.deleteCustomTheme(pendingDelete) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }
}

private struct ThemeEditorContext: Identifiable {
    let id = UUID()
    let theme: CustomReaderTheme?
}
