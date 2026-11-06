// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Shown the first time the reader picks AI soundscapes: what they are, what they cost
/// in space and whose licences apply, with the two downloads.
struct SoundscapeAIIntroSheet: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisplayTitle("AI soundscapes")
                    Text("Music and ambience composed on this device for the book you are reading, then kept to play again offline.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        point("lock", "Everything runs on this device. No text or audio leaves it, and no account is needed.")
                        point("internaldrive", "Music needs about 1.9 GB; music and ambience about 2.9 GB. Use Wi‑Fi. You can delete either later.")
                        point("bolt.horizontal", "Pieces are composed a few at a time while a book is open, and never in the background or when the device is hot.")
                        point("doc.text", "The models are Stability AI's Stable Audio 3 Small (Stability AI Community License) with Google's T5Gemma (Gemma Terms of Use). Powered by Stability AI.")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelCard(radius: 20)

                    if SoundscapeModels.isSupported {
                        VStack(spacing: 10) {
                            Button {
                                immersive.preferences.source = .ai
                                immersive.soundscapeModels.install([.music])
                                dismiss()
                            } label: {
                                Text("Download music").frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.accent)
                            .accessibilityIdentifier("soundscapes.downloadMusic")
                            Button {
                                immersive.preferences.source = .ai
                                immersive.soundscapeModels.install([.music, .sfx])
                                dismiss()
                            } label: {
                                Text("Download music and ambience").frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("soundscapes.downloadBoth")
                        }
                    } else {
                        Label {
                            Text("AI soundscapes are not available on this device.")
                                .fixedSize(horizontal: false, vertical: true)
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
                    SoundscapeLicenceLinks()
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(palette.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .accessibilityIdentifier("soundscapes.notNow")
                }
            }
        }
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(palette.accent).frame(width: 22)
        }
        .font(.footnote)
        .foregroundStyle(palette.text)
    }
}

/// The licences that apply to the AI soundscape models.
struct SoundscapeLicenceLinks: View {
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Powered by Stability AI")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.text)
            Link("Stability AI Community License", destination: URL(string: "https://stability.ai/license")!)
            Link("Stability AI Acceptable Use Policy", destination: URL(string: "https://stability.ai/use-policy")!)
            Link("Gemma Terms of Use", destination: URL(string: "https://ai.google.dev/gemma/terms")!)
            Link("Model card", destination: URL(string: "https://huggingface.co/stabilityai/stable-audio-3-optimized")!)
        }
        .font(.footnote)
        .tint(palette.accent)
    }
}
