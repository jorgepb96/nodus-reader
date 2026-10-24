// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct ReadingSettingsView: View {
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.nodusPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                preview
            } header: {
                sectionLabel("Preview")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int(preferences.baseFontSize.rounded())) pt")
                            .foregroundStyle(palette.muted)
                            .monospacedDigit()
                    }
                    Slider(value: $preferences.fontScale, in: 0.8...1.6, step: 0.05)
                        .accessibilityLabel("Text size")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Line spacing")
                        Spacer()
                        Text(String(format: "%.2f", preferences.lineHeight))
                            .foregroundStyle(palette.muted)
                            .monospacedDigit()
                    }
                    Slider(value: $preferences.lineHeight, in: 1.2...2.0, step: 0.05)
                        .accessibilityLabel("Line spacing")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Margins")
                        Spacer()
                        Text("\(Int(preferences.margin.rounded())) pt")
                            .foregroundStyle(palette.muted)
                            .monospacedDigit()
                    }
                    Slider(value: $preferences.margin, in: 16...64, step: 2)
                        .accessibilityLabel("Margins")
                }
            } header: {
                sectionLabel("Layout")
            }

            Section {
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
            } header: {
                sectionLabel("Type")
            } footer: {
                Text("These settings apply to the reader. Theme colours are selected in Settings › Theme.")
            }

            Section {
                Button("Reset reading preferences") {
                    preferences.reset()
                }
                .foregroundStyle(palette.accent)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Reading & Typography")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
        }
    }

    private var preview: some View {
        let theme = themeManager.readerTheme(colorScheme: colorScheme)
        let size = preferences.baseFontSize * (DeviceInfo.isPad ? 1.06 : 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("CHAPTER 1")
                .font(.system(size: 9, weight: .semibold))
                .tracking(2)
                .foregroundStyle(theme.muted)
            Text("Loomings")
                .font(.system(size: 24, design: .serif))
                .italic()
                .foregroundStyle(theme.text)
            JustifiedText(
                text: "Call me Ishmael. Some years ago—never mind how long precisely—I thought I would sail about a little and see the watery part of the world.",
                size: size,
                weight: textWeight,
                useSerif: preferences.useSerif,
                color: theme.text,
                lineSpacing: preferences.lineSpacing,
                justified: preferences.justify
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(2)
            .foregroundStyle(palette.muted)
    }

    private var textWeight: JustifiedText.Weight {
        switch preferences.weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
    }
}
