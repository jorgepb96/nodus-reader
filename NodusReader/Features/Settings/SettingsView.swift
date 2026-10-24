// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct SettingsView: View {
    var showsBrand: Bool = true

    @Environment(ThemeManager.self) private var themeManager
    @Environment(VoiceCatalog.self) private var voices
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(CloudSyncService.self) private var sync
    @Environment(\.nodusPalette) private var palette

    @State private var target: ThemeTarget = .reader
    @State private var editorContext: ThemeEditorContext?
    @State private var pendingCustomDelete: CustomReaderTheme?
    @State private var showDeleteTheme = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DisplayTitle("Settings")
                    .padding(.bottom, 2)

                Eyebrow("Theme")
                ThemeTargetPicker(target: $target)

                ThemeGrid(
                    target: target,
                    onCreateCustom: { editorContext = ThemeEditorContext(theme: nil) },
                    onEditCustom: { editorContext = ThemeEditorContext(theme: $0) },
                    onDeleteCustom: { theme in
                        pendingCustomDelete = theme
                        showDeleteTheme = true
                    }
                )

                if target == .reader {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Match app theme")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(palette.text)
                            Text("The reader follows the App appearance.")
                                .font(.caption2)
                                .foregroundStyle(palette.muted)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { themeManager.readerFollowsApp },
                            set: { isOn in
                                if isOn {
                                    themeManager.followAppTheme()
                                } else if let id = themeManager.selectedReaderThemeID {
                                    themeManager.selectReaderTheme(id)
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(palette.accent)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .panelCard(radius: 16)
                }

                Eyebrow("General")
                    .padding(.top, 6)

                VStack(spacing: 0) {
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        SettingsRow(title: "iCloud & Storage", value: syncValue)
                    }
                    divider
                    NavigationLink {
                        VoicesView()
                    } label: {
                        SettingsRow(title: "Voices & Models", value: voices.defaultVoice?.name ?? "System")
                    }
                    divider
                    NavigationLink {
                        ReadingSettingsView()
                    } label: {
                        SettingsRow(title: "Reading & Typography", value: preferences.summary)
                    }
                    divider
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        SettingsRow(title: "Privacy", value: nil)
                    }
                    divider
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsRow(title: "About Nodus Reader", value: version)
                    }
                }
                .panelCard(radius: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .toolbar {
            if showsBrand {
                ToolbarItem(placement: .principal) { BrandToolbar() }
            }
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .sheet(item: $editorContext) { context in
            CustomThemeEditor(existing: context.theme)
        }
        .confirmationDialog("Delete Custom Theme?", isPresented: $showDeleteTheme, titleVisibility: .visible) {
            Button("Delete Theme", role: .destructive) {
                if let pendingCustomDelete {
                    themeManager.deleteCustomTheme(pendingCustomDelete)
                }
                pendingCustomDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCustomDelete = nil }
        } message: {
            Text("The built-in themes remain available.")
        }
    }

    private var divider: some View {
        Divider()
            .overlay(palette.line)
            .padding(.leading, 14)
    }

    private var syncValue: String {
        guard sync.isEnabled else { return "Off" }
        return sync.isAvailable ? "On" : "Unavailable"
    }
}

struct ThemeTargetPicker: View {
    @Binding var target: ThemeTarget
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ThemeTarget.allCases) { option in
                Button {
                    target = option
                } label: {
                    Text(option.rawValue)
                        .font(.footnote.weight(target == option ? .semibold : .regular))
                        .foregroundStyle(target == option ? palette.text : palette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            target == option ? palette.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(target == option ? [.isSelected] : [])
            }
        }
        .padding(3)
        .frame(height: 36)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme applies to")
    }
}

private struct ThemeEditorContext: Identifiable {
    let id = UUID()
    let theme: CustomReaderTheme?
}

struct SettingsRow: View {
    @Environment(\.nodusPalette) private var palette
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}
