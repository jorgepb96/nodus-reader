// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Settings › Soundscapes › Models: download and delete Music and Ambience separately.
struct SoundscapeModelsView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @State private var pendingDelete: SoundscapeModels.Component?

    private var models: SoundscapeModels { immersive.soundscapeModels }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle("Models")
                Text("Stable Audio 3 Small composes music and ambience on this device. Deleting a model keeps the pieces already composed; they play without it.")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !SoundscapeModels.isSupported {
                    Label {
                        Text("AI soundscapes are not available on this device.").fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelCard(radius: 16)
                    .accessibilityIdentifier("soundscapes.unavailable")
                }
                VStack(spacing: 0) {
                    row(.music, title: "Music", detail: "Instrumental pieces for every mood and style")
                    Divider().overlay(palette.line).padding(.leading, 14)
                    row(.sfx, title: "Ambience", detail: "Rain, forests, cities and other places")
                }
                .panelCard(radius: 20)
                LabeledContent {
                    Text(ByteCountFormatter.string(fromByteCount: models.bytesOnDisk, countStyle: .file)).monospacedDigit()
                } label: {
                    Text("On this device")
                }
                .font(.subheadline)
                .foregroundStyle(palette.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .panelCard(radius: 16)
                SoundscapeLicenceLinks()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelCard(radius: 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background)
        .navigationTitle("Models")
        .inlineNavigationTitle()
        .onAppear { models.refresh() }
    }

    private func progressLine(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(title)
        }
        .font(.caption2)
        .foregroundStyle(palette.muted)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func row(_ component: SoundscapeModels.Component, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                switch models.state[component] ?? .notInstalled {
                case .downloading:
                    progressLine("Downloading…")
                case .converting:
                    progressLine("Installing…")
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                default:
                    Text(detail).font(.caption2).foregroundStyle(palette.muted)
                }
            }
            Spacer(minLength: 8)
            switch models.state[component] ?? .notInstalled {
            case .installed:
                Button("Delete", role: .destructive) { pendingDelete = component }
                    .font(.subheadline.weight(.medium))
                    .nodusTextButtonStyle()
                    .frame(minHeight: 44)
                    // Anchored to the button, so it opens beside it, not at the screen's edge.
                    .confirmationDialog("Delete Model?", isPresented: Binding(get: { pendingDelete == component },
                                                                              set: { if !$0 { pendingDelete = nil } }),
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            models.remove(component)
                            pendingDelete = nil
                        }
                        Button("Cancel", role: .cancel) { pendingDelete = nil }
                    } message: {
                        Text("The pieces already composed stay and keep playing. You can download the model again later.")
                    }
            case .downloading, .converting:
                Button("Cancel") { models.cancelInstall() }
                    .font(.subheadline.weight(.medium))
                    .nodusTextButtonStyle()
                    .frame(minHeight: 44)
            case .notInstalled, .failed:
                Button("Download") {
                    immersive.preferences.source = .ai
                    models.install([component])
                }
                .font(.subheadline.weight(.medium))
                .nodusTextButtonStyle()
                .frame(minHeight: 44)
                .disabled(!SoundscapeModels.isSupported || models.isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .accessibilityElement(children: .contain)
    }
}
