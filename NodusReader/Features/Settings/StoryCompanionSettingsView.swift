// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Settings › Recaps & Characters: Apple Intelligence recaps in the reader.
struct StoryCompanionSettingsView: View {
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(\.nodusPalette) private var palette

    @State private var savedBytes: Int64 = 0
    @State private var confirmDelete = false

    private let availability = StoryCompanionAvailability.current

    var body: some View {
        @Bindable var preferences = preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Recaps & Characters")
                    Text("A reminder of the story so far and of the people in it, from the pages you have read.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if availability != .available {
                    notice
                }

                VStack(spacing: 0) {
                    toggleRow("Recaps and characters",
                              detail: "Adds a button to the reader with a recap and a list of characters.",
                              isOn: $preferences.storyCompanion)
                    Divider().overlay(palette.line).padding(.leading, 14)
                    toggleRow("Offer a recap after a break",
                              detail: "When you open a book you have not read for two days or more.",
                              isOn: $preferences.recapAfterBreak)
                        .disabled(!preferences.storyCompanion)
                        .opacity(preferences.storyCompanion ? 1 : 0.5)
                }
                .panelCard(radius: 20)
                .disabled(availability != .available)

                Eyebrow("How it works")
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 10) {
                    point("lock", "Apple Intelligence writes everything on this device. The book’s text never leaves it.")
                    point("book.closed", "Only the pages before the one you are reading are used, so nothing ahead is given away. Prefaces and tables of contents are skipped.")
                    point("exclamationmark.bubble", "Summaries are generated and can contain mistakes.")
                    point("clock.arrow.circlepath", "While a book is open, the pages you have read are summarised a little at a time, so the next recap is quick. This pauses in Low Power Mode.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(radius: 20)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved recaps")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                        Text(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .font(.subheadline.weight(.medium))
                        .nodusTextButtonStyle()
                        .disabled(savedBytes == 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .panelCard(radius: 16)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Recaps & Characters")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
        .task { await measure() }
        .confirmationDialog("Delete Saved Recaps?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Saved Recaps", role: .destructive) {
                StoryCompanionStore().removeAll()
                Task { await measure() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are written again the next time you ask for a recap.")
        }
    }

    private var notice: some View {
        Label {
            Text(availability == .notEnabled
                 ? "Turn on Apple Intelligence in the system Settings to use recaps."
                 : "Apple Intelligence is getting ready on this device. Recaps will be available when it finishes.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(palette.text)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 16)
    }

    private func toggleRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.text)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(palette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
                .frame(width: 22)
        }
        .font(.footnote)
        .foregroundStyle(palette.text)
    }

    private func measure() async {
        savedBytes = await Task.detached(priority: .utility) { StoryCompanionStore().totalSize() }.value
    }
}
