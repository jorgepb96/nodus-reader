// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct ReaderAppearanceSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nodusPalette) private var palette

    @State private var editorContext: ThemeEditorContext?
    @State private var pendingDelete: CustomReaderTheme?
    @State private var showDeleteConfirmation = false

    var body: some View {
        @Bindable var preferences = preferences

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("Theme")
                    ThemeGrid(
                        target: .reader,
                        onCreateCustom: { editorContext = ThemeEditorContext(theme: nil) },
                        onEditCustom: { editorContext = ThemeEditorContext(theme: $0) },
                        onDeleteCustom: { theme in
                            pendingDelete = theme
                            showDeleteConfirmation = true
                        }
                    )

                    Toggle("Match app theme", isOn: Binding(
                        get: { themeManager.readerFollowsApp },
                        set: { isOn in
                            if isOn {
                                themeManager.followAppTheme()
                            } else if let id = themeManager.selectedReaderThemeID {
                                themeManager.selectReaderTheme(id)
                            }
                        }
                    ))
                    .font(.footnote)
                    .tint(palette.accent)
                    .padding(.horizontal, 4)

                    Eyebrow("Typography")
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Text size")
                                Spacer()
                                Text("\(Int(preferences.baseFontSize.rounded())) pt")
                                    .foregroundStyle(palette.muted)
                                    .monospacedDigit()
                            }
                            .font(.footnote)
                            Slider(value: $preferences.fontScale, in: 0.8...1.6, step: 0.05)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Line spacing")
                                Spacer()
                                Text(String(format: "%.2f", preferences.lineHeight))
                                    .foregroundStyle(palette.muted)
                                    .monospacedDigit()
                            }
                            .font(.footnote)
                            Slider(value: $preferences.lineHeight, in: 1.2...2.0, step: 0.05)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Margins")
                                Spacer()
                                Text("\(Int(preferences.margin.rounded())) pt")
                                    .foregroundStyle(palette.muted)
                                    .monospacedDigit()
                            }
                            .font(.footnote)
                            Slider(value: $preferences.margin, in: 16...64, step: 2)
                        }
                        Picker("Typeface", selection: $preferences.useSerif) {
                            Text("Serif").tag(true)
                            Text("Sans").tag(false)
                        }
                        .pickerStyle(.segmented)
                        Picker("Weight", selection: $preferences.weightIndex) {
                            Text("Regular").tag(0)
                            Text("Medium").tag(1)
                            Text("Semibold").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Justify text", isOn: $preferences.justify)
                            .font(.footnote)
                    }
                    .padding(14)
                    .panelCard(radius: 18)

                    preview

                    Button("Reset typography") {
                        preferences.reset()
                    }
                    .font(.footnote)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 4)
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

    private var preview: some View {
        let theme = themeManager.readerTheme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 8) {
            Text("CHAPTER 1")
                .font(.system(size: 9, weight: .semibold))
                .tracking(2)
                .foregroundStyle(theme.muted)
            Text("Loomings")
                .font(.system(size: 22, design: .serif))
                .italic()
                .foregroundStyle(theme.text)
            JustifiedText(
                text: "Call me Ishmael. Some years ago—never mind how long precisely—I thought I would sail about a little and see the watery part of the world.",
                size: preferences.baseFontSize,
                weight: weight,
                useSerif: preferences.useSerif,
                color: theme.text,
                lineSpacing: preferences.lineSpacing,
                justified: preferences.justify
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }

    private var weight: JustifiedText.Weight {
        switch preferences.weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
    }
}

private struct ThemeEditorContext: Identifiable {
    let id = UUID()
    let theme: CustomReaderTheme?
}
