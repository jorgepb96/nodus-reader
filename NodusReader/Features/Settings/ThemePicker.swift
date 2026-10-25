// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

enum ThemeTarget: String, CaseIterable, Identifiable {
    case app = "App"
    case reader = "Reader"
    var id: String { rawValue }
}

struct ThemeGrid: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nodusPalette) private var palette

    var target: ThemeTarget
    var onCreateCustom: () -> Void = {}
    var onEditCustom: (CustomReaderTheme) -> Void = { _ in }
    var onDeleteCustom: (CustomReaderTheme) -> Void = { _ in }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(NodusAppTheme.allCases) { theme in
                    if target == .app {
                        AppThemeTile(theme: theme,
                                     isSelected: themeManager.appTheme == theme) {
                            themeManager.appTheme = theme
                        }
                    } else {
                        let reader = ReaderTheme.resolve(
                            ReaderThemeID(rawValue: theme.rawValue) ?? .system,
                            colorScheme: colorScheme
                        )
                        ThemeSwatchTile(
                            name: theme.title,
                            background: theme == .system ? nil : reader.background,
                            text: theme == .system ? nil : reader.text,
                            splitSwatch: theme == .system ? theme.swatch : nil,
                            border: theme == .highContrast ? .black : nil,
                            isSelected: themeManager.selectedReaderThemeID == (ReaderThemeID(rawValue: theme.rawValue) ?? .system)
                        ) {
                            themeManager.selectReaderTheme(ReaderThemeID(rawValue: theme.rawValue) ?? .system)
                        }
                    }
                }

                if target == .reader {
                    ForEach(themeManager.customThemes) { custom in
                        ThemeSwatchTile(
                            name: custom.name,
                            background: Color(hex: custom.backgroundHex),
                            text: Color(hex: custom.textHex),
                            splitSwatch: nil,
                            border: nil,
                            isSelected: themeManager.readerThemeSelection == "custom:\(custom.id.uuidString)"
                        ) {
                            themeManager.selectCustomTheme(custom)
                        }
                        .contextMenu {
                            Button {
                                onEditCustom(custom)
                            } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                onDeleteCustom(custom)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if target == .reader {
                Button {
                    onCreateCustom()
                } label: {
                    Label("Create custom theme", systemImage: "plus")
                        .font(.subheadline)
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(palette.isHighContrast ? palette.text : palette.accent.opacity(0.35),
                                        style: StrokeStyle(lineWidth: palette.isHighContrast ? 1.5 : 1,
                                                           dash: [4, 3]))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AppThemeTile: View {
    @Environment(\.nodusPalette) private var palette
    let theme: NodusAppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                swatch
                Text(theme.title)
                    .font(.caption)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var swatch: some View {
        let swatch = theme.swatch
        return ZStack {
            if theme == .system {
                LinearGradient(stops: [
                    .init(color: swatch.leading, location: 0),
                    .init(color: swatch.leading, location: 0.5),
                    .init(color: swatch.trailing, location: 0.5),
                    .init(color: swatch.trailing, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            } else {
                swatch.leading
            }
            Text("Aa")
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(swatch.label)
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(swatch.border ?? palette.line, lineWidth: swatch.borderWidth)
        )
        .overlay(selectionOverlay)
    }

    private var selectionOverlay: some View {
        ZStack(alignment: .topTrailing) {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.background, lineWidth: 2)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.accent, lineWidth: 2)
                    .padding(-2)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 18, height: 18)
                    .background(palette.accent, in: Circle())
                    .padding(5)
            }
        }
    }
}

struct ThemeSwatchTile: View {
    @Environment(\.nodusPalette) private var palette
    let name: String
    let background: Color?
    let text: Color?
    let splitSwatch: NodusThemeSwatch?
    let border: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    if let splitSwatch {
                        LinearGradient(stops: [
                            .init(color: splitSwatch.leading, location: 0),
                            .init(color: splitSwatch.leading, location: 0.5),
                            .init(color: splitSwatch.trailing, location: 0.5),
                            .init(color: splitSwatch.trailing, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    } else {
                        background ?? palette.panel
                    }
                    Text("Aa")
                        .font(.system(size: 22, design: .serif))
                        .foregroundStyle(text ?? palette.text)
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(border ?? palette.line, lineWidth: border == nil ? 1 : 2)
                )
                .overlay(selectionOverlay)

                Text(name.isEmpty ? "Custom" : name)
                    .font(.caption)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name.isEmpty ? "Custom" : name) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var selectionOverlay: some View {
        ZStack(alignment: .topTrailing) {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.background, lineWidth: 2)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.accent, lineWidth: 2)
                    .padding(-2)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 18, height: 18)
                    .background(palette.accent, in: Circle())
                    .padding(5)
            }
        }
    }
}

struct CustomThemeEditor: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let existing: CustomReaderTheme?

    @State private var name: String
    @State private var background: Color
    @State private var text: Color
    @State private var accent: Color

    init(existing: CustomReaderTheme?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _background = State(initialValue: Color(hex: existing?.backgroundHex ?? NodusHex.lightPaper))
        _text = State(initialValue: Color(hex: existing?.textHex ?? NodusHex.lightInk))
        _accent = State(initialValue: Color(hex: existing?.accentHex ?? NodusHex.deepViolet))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Theme name", text: $name)
                }
                Section("Colours") {
                    ColorPicker("Background", selection: $background, supportsOpacity: false)
                    ColorPicker("Text", selection: $text, supportsOpacity: false)
                    ColorPicker("Accent", selection: $accent, supportsOpacity: false)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aa")
                            .font(.system(size: 30, design: .serif))
                        Text("Call me Ishmael. Some years ago—never mind how long precisely—I thought I would sail about a little.")
                            .font(.system(size: 16, design: .serif))
                            .lineSpacing(4)
                    }
                    .foregroundStyle(text)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(accent).frame(width: 10, height: 10).padding(12)
                    }
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Custom themes apply to the reader. They are stored on this device and will join iCloud sync with the rest of your reading preferences.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil || existing?.name.isEmpty == true ? "New Theme" : "Edit Theme")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let backgroundHex = background.rgbHex
        let custom = CustomReaderTheme(
            id: existing?.id ?? UUID(),
            name: trimmed,
            backgroundHex: backgroundHex,
            textHex: text.rgbHex,
            accentHex: accent.rgbHex,
            isDark: Color(hex: backgroundHex).isPerceptuallyDark
        )
        themeManager.updateCustomTheme(custom)
        dismiss()
    }
}
