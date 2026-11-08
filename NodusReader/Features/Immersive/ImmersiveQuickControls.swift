// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// What plays now and the few controls a reader needs while reading:
/// play/pause, lock, pick the ambience or the music, back to automatic and
/// the two levels. Used in the player, the reader popover and on the Mac.
struct ImmersiveQuickControls: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette
    var showsTitle = true
    @State private var showStyles = false

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
                Text(preferences.source == .ai ? "Download a model in Settings › Soundscapes."
                                               : "Download a sound pack in Settings › Soundscapes.")
                    .font(.footnote)
                    .foregroundStyle(palette.text)
            } else if case .unavailable(let message) = immersive.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(palette.text)
            } else if preferences.isEnabled {
                // Return to automatic sits in this row so locking or choosing
                // never changes the panel's height and moves the popover.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        bedMenu
                        musicMenu
                        automaticControl
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            bedMenu
                            musicMenu
                        }
                        automaticControl
                    }
                }
                if preferences.source == .ai {
                    aiRow
                    if preferences.askBeforeSession {
                        // Turns the session's music offer back on (or off) for this book.
                        Toggle("Offer music when listening starts", isOn: Binding(
                            get: { immersive.asksSessionForCurrentBook },
                            set: { immersive.asksSessionForCurrentBook = $0 }))
                            .font(.footnote)
                            .foregroundStyle(palette.text)
                            .tint(palette.accent)
                            .accessibilityIdentifier("soundscapes.askForBook")
                    }
                }
                // The narrating voice beside the music and ambience it plays over.
                LabeledSlider("Voice", value: Binding(get: { playback.voiceVolume },
                                                      set: { playback.setVoiceVolume($0) }),
                              display: percent(playback.voiceVolume), systemImage: "waveform")
                    .accessibilityIdentifier("soundscapes.voiceVolume")
                LabeledSlider("Music", value: $preferences.musicVolume,
                              display: percent(preferences.musicVolume), systemImage: "music.note")
                LabeledSlider("Ambience", value: $preferences.ambienceVolume,
                              display: percent(preferences.ambienceVolume), systemImage: "leaf")
            }
        }
    }

    /// AI soundscapes: the book's style, the per-book pack and the favorite heart.
    private var aiRow: some View {
        HStack(spacing: 8) {
            // A list in a sheet: a long menu inside the reader's popover could not scroll.
            Button {
                showStyles = true
            } label: {
                chip(icon: "theatermasks", title: immersive.bookStyle.label)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Book style"))
            .accessibilityValue(Text(immersive.bookStyle.label))
            .accessibilityIdentifier("soundscapes.style")
            .sheet(isPresented: $showStyles) {
                SoundscapeStyleList()
                    .presentationDetents([.medium, .large])
            }

            if case .preparing = immersive.generation {
                Button {
                    immersive.cancelPreparation()
                } label: {
                    chip(icon: "xmark", title: String(localized: "Stop"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Stop preparing soundscapes"))
                .accessibilityIdentifier("soundscapes.cancelPrepare")
            } else if immersive.canPrepareSoundscapes {
                Button {
                    immersive.prepareSoundscapes()
                } label: {
                    chip(icon: "square.and.arrow.down", title: String(localized: "Prepare"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Prepare soundscapes for this book"))
                .accessibilityHint(Text("Composes a few pieces for this book now, so they are ready to play."))
                .accessibilityIdentifier("soundscapes.prepare")
            }

            if let piece = immersive.currentGeneratedPiece {
                CircleIconButton(piece.favorite ? "heart.fill" : "heart",
                                 label: piece.favorite ? "Remove from favorites" : "Add to favorites",
                                 filled: piece.favorite) {
                    immersive.toggleFavoriteCurrent()
                }
                .accessibilityValue(Text(piece.favorite ? "Favorite" : "Not favorite"))
                .accessibilityIdentifier("soundscapes.favorite")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var automaticControl: some View {
        if immersive.isLocked || immersive.isChosenByReader {
            Button {
                immersive.returnToAutomatic()
            } label: {
                chip(icon: "arrow.uturn.backward", title: String(localized: "Automatic"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Return to automatic"))
            .accessibilityIdentifier("immersive.automatic")
        }
    }

    private var canPlay: Bool {
        immersive.preferences.isEnabled && immersive.status != .needsPacks && immersive.status != .waiting
    }

    private var nowPlaying: String {
        guard immersive.preferences.isEnabled else { return String(localized: "Soundscapes are off") }
        guard let atmosphere = immersive.atmosphere else { return String(localized: "Nothing playing yet") }
        let parts = [atmosphere.base == .none ? nil : atmosphere.base.label, atmosphere.music?.label]
            .compactMap { $0 }
        return parts.isEmpty ? String(localized: "Silence") : parts.joined(separator: " · ")
    }

    private var statusLine: String {
        switch immersive.generation {
        case .composing(let what):
            return waitingSuffix(String(localized: "Composing \(what)…"))
        case .preparing(let done, let total):
            return waitingSuffix(String(localized: "Preparing soundscapes \(done)/\(total)"))
        default: break
        }
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

    /// Says why nothing is being composed right now, so a pack never looks stuck.
    private func waitingSuffix(_ line: String) -> String {
        guard let reason = immersive.generationWaiting else { return line }
        let why: String
        switch reason {
        case "narration": why = String(localized: "waiting for the narration")
        case "analysis": why = String(localized: "waiting for scene analysis")
        case "memory": why = String(localized: "waiting for free memory")
        case "hot": why = String(localized: "waiting for the device to cool")
        case "low power": why = String(localized: "paused in Low Power Mode")
        case "background": why = String(localized: "paused in the background")
        case "hourly limit": why = String(localized: "hourly limit reached")
        default: return line
        }
        return line + " · " + why
    }

    private var bedMenu: some View {
        Menu {
            ForEach([BaseAmbience.none] + BaseAmbience.allCases.filter { $0 != .none && immersive.availableBeds.contains($0) }) { bed in
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
            ForEach(MusicMood.allCases.filter { immersive.availableMoods.contains($0) }) { mood in
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

/// The book's soundscape style: detected from the text, or chosen.
private struct SoundscapeStyleList: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(String(localized: "Detected"), selected: !immersive.isStyleChosen) { immersive.setBookStyle(nil) }
                } footer: {
                    Text("AI music follows this style for the book.")
                }
                Section {
                    ForEach(SoundscapeStyle.allCases) { style in
                        row(style.label, selected: immersive.isStyleChosen && immersive.bookStyle == style) {
                            immersive.setBookStyle(style)
                        }
                    }
                }
            }
            .navigationTitle("Book style")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
