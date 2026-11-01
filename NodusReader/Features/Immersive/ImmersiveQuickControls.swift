// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// What plays now and the few controls a reader needs while reading:
/// play/pause, lock, pick the ambience or the music, back to automatic and
/// the two levels. Used in the player, the reader popover and on the Mac.
struct ImmersiveQuickControls: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    var showsTitle = true

    var body: some View {
        @Bindable var preferences = immersive.preferences
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if showsTitle {
                        Eyebrow("Atmosphere")
                    }
                    Text(nowPlaying)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                        .accessibilityIdentifier("immersive.nowPlaying")
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if canPlay {
                    CircleIconButton(immersive.isLocked ? "lock.fill" : "lock.open",
                                     label: immersive.isLocked ? "Unlock atmosphere" : "Lock atmosphere",
                                     filled: immersive.isLocked) {
                        immersive.isLocked ? immersive.unlock() : immersive.lock()
                    }
                    .accessibilityValue(Text(immersive.isLocked ? "Locked" : "Unlocked"))
                    .accessibilityIdentifier("immersive.lock")
                    CircleIconButton(immersive.status == .playing ? "pause.fill" : "play.fill",
                                     label: immersive.status == .playing ? "Pause atmosphere" : "Play atmosphere",
                                     filled: true) {
                        immersive.togglePlayback()
                    }
                    .accessibilityIdentifier("immersive.playPause")
                }
            }

            if immersive.status == .needsPacks {
                Text("Download a sound pack in Settings › Immersive Audio.")
                    .font(.footnote)
                    .foregroundStyle(palette.text)
            } else if case .unavailable(let message) = immersive.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(palette.text)
            } else if preferences.isEnabled {
                HStack(spacing: 8) {
                    bedMenu
                    musicMenu
                }
                if immersive.isLocked || immersive.isChosenByReader {
                    Button {
                        immersive.returnToAutomatic()
                    } label: {
                        Label("Return to automatic", systemImage: "wand.and.stars")
                            .font(.footnote.weight(.medium))
                    }
                    .nodusTextButtonStyle()
                    .accessibilityIdentifier("immersive.automatic")
                }
                LabeledSlider("Music", value: $preferences.musicVolume,
                              display: percent(preferences.musicVolume), systemImage: "music.note")
                LabeledSlider("Ambience", value: $preferences.ambienceVolume,
                              display: percent(preferences.ambienceVolume), systemImage: "leaf")
            }
        }
    }

    private var canPlay: Bool {
        immersive.preferences.isEnabled && immersive.status != .needsPacks && immersive.status != .waiting
    }

    private var nowPlaying: String {
        guard immersive.preferences.isEnabled else { return String(localized: "Immersive Audio is off") }
        guard let atmosphere = immersive.atmosphere else { return String(localized: "Nothing playing yet") }
        let parts = [atmosphere.base == .none ? nil : atmosphere.base.label, atmosphere.music?.label]
            .compactMap { $0 }
        return parts.isEmpty ? String(localized: "Silence") : parts.joined(separator: " · ")
    }

    private var statusLine: String {
        if immersive.isLocked { return String(localized: "Locked for this book") }
        if immersive.isChosenByReader { return String(localized: "Chosen by you for this book") }
        switch immersive.preferences.mode {
        case .automatic:
            if !immersive.availability.allowsAutomatic { return String(localized: "Automatic needs Apple Intelligence: playing your default atmosphere") }
            if let kind = immersive.documentKind, !kind.hasScenes {
                return String(localized: "Steady atmosphere for non-fiction")
            }
            return String(localized: "Follows the story")
        case .study: return String(localized: "Study session: steady atmosphere")
        case .manual: return String(localized: "Manual")
        case .off: return ""
        }
    }

    private var bedMenu: some View {
        Menu {
            ForEach([BaseAmbience.none] + BaseAmbience.allCases.filter { immersive.library.installedBeds.contains($0) }) { bed in
                Button { immersive.choose(base: bed) } label: { Label(bed.label, systemImage: bed.symbol) }
            }
        } label: {
            chip(icon: immersive.atmosphere?.base.symbol ?? "leaf",
                 title: immersive.atmosphere?.base.label ?? String(localized: "Ambience"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose ambience"))
        .accessibilityIdentifier("immersive.chooseAmbience")
    }

    private var musicMenu: some View {
        Menu {
            Button(String(localized: "No music")) { immersive.choose(music: nil) }
            ForEach(MusicMood.allCases.filter { immersive.library.installedMoods.contains($0) }) { mood in
                Button(mood.label) { immersive.choose(music: mood) }
            }
        } label: {
            chip(icon: "music.note", title: immersive.atmosphere?.music?.label ?? String(localized: "No music"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose music"))
        .accessibilityIdentifier("immersive.chooseMusic")
    }

    private func chip(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(palette.accent)
            Text(title).foregroundStyle(palette.text).lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(palette.panel, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The player sheet's atmosphere card (only when Immersive Audio is on).
struct ImmersiveAudioCard: View {
    @Environment(ImmersiveAudioController.self) private var immersive

    var body: some View {
        if immersive.preferences.isEnabled {
            ImmersiveQuickControls()
                .padding(14)
                .panelCard(radius: 20)
        }
    }
}
