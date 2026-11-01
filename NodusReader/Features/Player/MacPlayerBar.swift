// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import DesignSystem
import SwiftUI

struct MacPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(VoiceCatalog.self) private var voices
    @Environment(LibraryService.self) private var library
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @State private var showAtmosphere = false

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                if let book = playback.activeBook {
                    SquareCoverThumb(book: book, size: 36, cornerRadius: 5)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.activeBook?.title ?? "")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("Chapter \(playback.chapterNumber) · \(playback.chapterTitle)")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                .frame(minWidth: 0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    playerButton("backward.end", label: "Previous sentence") {
                        playback.previousSentence()
                    }
                    Button {
                        playback.toggle()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .offset(x: playback.isPlaying ? 0 : 1)
                            .foregroundStyle(palette.onAccent)
                            .frame(width: 36, height: 36)
                            .background(palette.accent, in: Circle())
                            .overlay {
                                if playback.isLoading {
                                    LoadingRing(color: palette.onAccent, lineWidth: 2.5).padding(2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    playerButton("forward.end", label: "Next sentence") {
                        playback.nextSentence()
                    }
                    // Ends narration and removes the player bar.
                    playerButton("stop.fill", label: "Stop narration") {
                        playback.stopAndClose()
                    }
                }
                NodusProgressBar(value: playback.overallProgress, height: 3)
                    .frame(width: 280)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Menu {
                    ForEach(PlaybackController.speedOptions, id: \.self) { speed in
                        Button(String(format: "%g×", speed)) { playback.setSpeed(speed) }
                    }
                } label: {
                    chip(playback.speedLabel)
                }
                .nodusMenuLabelStyle()

                Menu {
                    Button("Book default") {
                        if let book = playback.activeBook {
                            library.setPreferredVoice(book, voiceID: nil)
                        }
                    }
                    Divider()
                    ForEach(voices.allInstalledVoices, id: \.id) { voice in
                        Button("\(voice.name) · \(voice.engineLabel) · \(voice.languageName)") {
                            playback.setVoice(voice)
                        }
                    }
                } label: {
                    chip("\(playback.voiceLabel) · \(playback.engineLabel)")
                }
                .nodusMenuLabelStyle()

                if immersive.preferences.isEnabled {
                    Button {
                        showAtmosphere = true
                    } label: {
                        chip(immersive.atmosphere?.music?.label ?? immersive.atmosphere?.base.label
                             ?? String(localized: "Atmosphere"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Atmosphere")
                    .popover(isPresented: $showAtmosphere, arrowEdge: .top) {
                        ImmersiveQuickControls()
                            .padding(16)
                            .frame(width: 340)
                    }
                }

                HStack(spacing: 4) {
                    Text("Space")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.line, lineWidth: 1))
                    Text("play")
                        .font(.system(size: 11))
                }
                .foregroundStyle(palette.muted)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
        .background(palette.panelRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.accent.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func playerButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(palette.panel, in: Capsule())
            .overlay(Capsule().stroke(palette.line, lineWidth: 1))
            .lineLimit(1)
    }
}
#endif
