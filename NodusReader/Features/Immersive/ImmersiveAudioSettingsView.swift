// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Settings › Soundscapes (formerly Immersive Audio): music and ambient sound under
/// reading and narration, from downloaded packs or composed on this device. The main
/// page keeps only the essentials; everything else is in More options.
struct ImmersiveAudioSettingsView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette

    @State private var showAIIntro = false

    private var preferences: ImmersiveAudioPreferences { immersive.preferences }

    var body: some View {
        @Bindable var preferences = immersive.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Soundscapes")
                    Text("Quiet instrumental music and ambient sound while you read or listen, chosen for the passage you are in and kept steady.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: Binding(get: { preferences.isEnabled }, set: { immersive.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Soundscapes")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                        Text("Plays in the reader and under narration. Nothing plays until you turn it on.")
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
                .panelCard(radius: 16)
                .accessibilityIdentifier("immersive.enable")

                source(preferences: preferences)

                if preferences.isEnabled {
                    layers(preferences: preferences)
                    modeSection(preferences: preferences)
                }

                VStack(spacing: 0) {
                    NavigationLink {
                        SoundscapeMoreOptionsView()
                    } label: {
                        SettingsRow(title: "More options", value: nil)
                    }
                    .accessibilityIdentifier("soundscapes.moreOptions")
                }
                .buttonStyle(.plain)
                .panelCard(radius: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 110)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Soundscapes")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
        .sheet(isPresented: $showAIIntro) {
            SoundscapeAIIntroSheet()
        }
    }

    // MARK: Sections

    /// Downloaded packs or AI soundscapes, each with its own short setup.
    private func source(preferences: ImmersiveAudioPreferences) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Source")
            Picker("Source", selection: Binding(get: { preferences.source }, set: { choose($0) })) {
                Text("Downloaded").tag(SoundscapeSource.downloaded)
                Text("AI").tag(SoundscapeSource.ai)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("soundscapes.source")
            Text(preferences.source == .ai
                 ? "Composed on this device for each book, a few pieces at a time, and kept to play again offline."
                 : "Sound packs recorded by people and shared under free licences, downloaded once and played offline.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                if preferences.source == .ai {
                    NavigationLink {
                        SoundscapeModelsView()
                    } label: {
                        SettingsRow(title: "Models", value: modelsValue)
                    }
                    .accessibilityIdentifier("soundscapes.models")
                } else {
                    NavigationLink {
                        ImmersivePacksView()
                    } label: {
                        SettingsRow(title: "Sound packs", value: immersive.library.newSoundsCount > 0
                            ? String(localized: "\(immersive.library.newSoundsCount) new sounds")
                            : ByteCountFormatter.string(fromByteCount: immersive.library.bytesOnDisk, countStyle: .file))
                    }
                }
            }
            .buttonStyle(.plain)
            .panelCard(radius: 20)
            if let notice {
                Label {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(palette.text)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(radius: 16)
            }
            if case .paused(let reason) = immersive.generation {
                HStack {
                    Text("Composing is paused: \(reason).")
                        .font(.footnote)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Resume") { immersive.resumeGeneration() }
                        .font(.subheadline.weight(.medium))
                        .nodusTextButtonStyle()
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 14)
                .panelCard(radius: 16)
            }
        }
    }

    private func choose(_ source: SoundscapeSource) {
        preferences.source = source
        if source == .ai, !immersive.soundscapeModels.anyInstalled, !immersive.generated.hasAnything {
            showAIIntro = true
        }
    }

    private var modelsValue: String {
        let music = immersive.soundscapeModels.isInstalled(.music)
        let ambience = immersive.soundscapeModels.isInstalled(.sfx)
        switch (music, ambience) {
        case (true, true): return String(localized: "Music and ambience")
        case (true, false): return String(localized: "Music")
        case (false, true): return String(localized: "Ambience")
        case (false, false): return String(localized: "Not installed")
        }
    }

    private var notice: String? {
        if preferences.source == .ai {
            if !SoundscapeModels.isSupported, !immersive.generated.hasAnything {
                return String(localized: "AI soundscapes are not available on this device.")
            }
            if !immersive.soundscapeModels.anyInstalled, !immersive.generated.hasAnything {
                return String(localized: "Download a model to compose soundscapes on this device.")
            }
            return nil
        }
        return immersive.library.hasAnything ? nil
            : String(localized: "Download a sound pack to hear soundscapes. The sounds are stored on this device and play offline.")
    }

    private func layers(preferences: ImmersiveAudioPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 14) {
            Toggle("Music", isOn: $preferences.musicEnabled)
                .toggleStyle(.switch)
                .tint(palette.accent)
                .font(.subheadline.weight(.medium))
            LabeledSlider("Music volume", value: $preferences.musicVolume,
                          display: percent(preferences.musicVolume), systemImage: "music.note")
                .disabled(!preferences.musicEnabled)
                .opacity(preferences.musicEnabled ? 1 : 0.5)
            Divider().overlay(palette.line)
            Toggle("Ambient sounds", isOn: $preferences.ambienceEnabled)
                .toggleStyle(.switch)
                .tint(palette.accent)
                .font(.subheadline.weight(.medium))
            LabeledSlider("Ambience volume", value: $preferences.ambienceVolume,
                          display: percent(preferences.ambienceVolume), systemImage: "leaf")
                .disabled(!preferences.ambienceEnabled)
                .opacity(preferences.ambienceEnabled ? 1 : 0.5)
        }
        .padding(14)
        .panelCard(radius: 20)
    }

    private func modeSection(preferences: ImmersiveAudioPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Mode")
            Picker("Mode", selection: Binding(get: { preferences.mode }, set: {
                preferences.mode = $0
                preferences.profile = nil
            })) {
                if immersive.availability.showsAutomatic {
                    Text(ImmersiveMode.automatic.label).tag(ImmersiveMode.automatic)
                }
                Text(ImmersiveMode.study.label).tag(ImmersiveMode.study)
                Text(ImmersiveMode.manual.label).tag(ImmersiveMode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(modeDetail(preferences.mode))
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let explanation = immersive.availability.explanation {
                Label {
                    Text(explanation).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(palette.text)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(radius: 16)
            }
        }
    }

    private func modeDetail(_ mode: ImmersiveMode) -> LocalizedStringKey {
        switch mode {
        case .automatic: "Follows the story: Apple Intelligence on this device reads the passages ahead and the atmosphere changes only at clear new scenes."
        case .study: "One steady atmosphere for the whole session, with a new texture every block. The text is never analysed."
        case .manual, .off: "You choose the ambience and the music; they stay until you change them."
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Settings › Soundscapes › More options: everything beyond the essentials.
struct SoundscapeMoreOptionsView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette

    @State private var showAdvanced = false
    @State private var mapsBytes: Int64 = 0
    @State private var confirmDeleteMaps = false
    @State private var confirmDeleteGenerated = false

    private var preferences: ImmersiveAudioPreferences { immersive.preferences }

    var body: some View {
        @Bindable var preferences = immersive.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle("More options")
                if preferences.isEnabled {
                    profiles
                    character(preferences: preferences)
                    defaultAtmosphere(preferences: preferences)
                    advanced(preferences: preferences)
                }
                if preferences.source == .ai || immersive.generated.hasAnything {
                    generatedSection(preferences: preferences)
                }

                Eyebrow("Sounds")
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    NavigationLink {
                        ImmersivePacksView()
                    } label: {
                        SettingsRow(title: "Sound packs", value: ByteCountFormatter.string(fromByteCount: immersive.library.bytesOnDisk, countStyle: .file))
                    }
                    Divider().overlay(palette.line).padding(.leading, 14)
                    NavigationLink {
                        ImmersiveCreditsView()
                    } label: {
                        SettingsRow(title: "Credits and licences", value: nil)
                    }
                }
                .buttonStyle(.plain)
                .panelCard(radius: 20)

                Eyebrow("How it works")
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 10) {
                    point("lock", "Everything happens on this device: sounds are downloaded or composed here and played offline, and in Automatic mode Apple Intelligence reads the passages here. No text or audio leaves the device.")
                    point("clock", "The atmosphere stays for at least ten minutes and changes only when the story clearly moves to another scene, at a paragraph, scene or chapter break. When in doubt, it stays.")
                    point("waveform", "Music softens while narration speaks and never interrupts it.")
                    point("graduationcap", "Study mode keeps one atmosphere for the session and never reacts to what the text is about.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(radius: 20)

                if preferences.mode == .automatic {
                    sceneMaps
                }

                #if DEBUG
                ImmersiveDecisionLog()
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 110)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("More options")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .task { mapsBytes = immersive.sceneMapsSize }
        .confirmationDialog("Delete Scene Analysis?", isPresented: $confirmDeleteMaps, titleVisibility: .visible) {
            Button("Delete Scene Analysis", role: .destructive) {
                immersive.deleteSceneMaps()
                mapsBytes = immersive.sceneMapsSize
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Books are analysed again, a little at a time, the next time they are open in Automatic mode.")
        }
        .confirmationDialog("Delete Composed Soundscapes?", isPresented: $confirmDeleteGenerated, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { immersive.generated.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every piece composed on this device is deleted, favorites included. New ones are composed while you read.")
        }
    }

    private func character(preferences: ImmersiveAudioPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Music intensity")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.text)
                Picker("Music intensity", selection: $preferences.intensity) {
                    ForEach(MusicIntensity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Subtle never plays dramatic music; Expressive follows battles and chases when the story clearly has them.")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(palette.line)
            Toggle(isOn: $preferences.smoothTransitions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth transitions")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Text("Long, gentle crossfades between atmospheres.")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
            }
            .toggleStyle(.switch)
            .tint(palette.accent)
        }
        .padding(14)
        .panelCard(radius: 20)
    }

    private func generatedSection(preferences: ImmersiveAudioPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("AI soundscapes")
            VStack(spacing: 0) {
                NavigationLink {
                    SoundscapeFavoritesView()
                } label: {
                    SettingsRow(title: "Favorites", value: "\(immersive.generated.favoriteIDs.count)")
                }
                Divider().overlay(palette.line).padding(.leading, 14)
                NavigationLink {
                    SoundscapeModelsView()
                } label: {
                    SettingsRow(title: "Models", value: ByteCountFormatter.string(fromByteCount: immersive.soundscapeModels.bytesOnDisk, countStyle: .file))
                }
            }
            .buttonStyle(.plain)
            .panelCard(radius: 20)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Space for composed pieces")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: immersive.generated.bytesOnDisk, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                }
                Picker("Space for composed pieces", selection: $preferences.generatedBudgetMB) {
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1_000)
                    Text("2 GB").tag(2_000)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("When it fills, the pieces heard least recently are deleted first. Favorites are always kept.")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Delete composed soundscapes", role: .destructive) { confirmDeleteGenerated = true }
                    .font(.subheadline.weight(.medium))
                    .nodusTextButtonStyle()
                    .frame(minHeight: 44)
                    .disabled(!immersive.generated.hasAnything)
            }
            .padding(14)
            .panelCard(radius: 20)
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Profiles")
            FlowChips(items: ImmersiveProfile.allCases.filter {
                $0.settings.mode != .automatic || immersive.availability.showsAutomatic
            }) { profile in
                CapsuleChip(profile.label, isSelected: preferences.profile == profile) {
                    immersive.apply(profile: profile)
                }
            }
        }
    }

    private func defaultAtmosphere(preferences: ImmersiveAudioPreferences) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(preferences.mode == .automatic ? "Before the story is analysed" : "Atmosphere")
            HStack(spacing: 10) {
                Menu {
                    ForEach([BaseAmbience.none] + BaseAmbience.allCases.filter { $0 != .none && immersive.availableBeds.contains($0) }) { bed in
                        Button { preferences.defaultAtmosphere.base = bed; preferences.profile = nil } label: {
                            Label(bed.label, systemImage: bed.symbol)
                        }
                    }
                } label: {
                    atmosphereChip(icon: preferences.defaultAtmosphere.base.symbol,
                                   title: preferences.defaultAtmosphere.base.label)
                }
                .accessibilityLabel(Text("Ambience"))
                .accessibilityValue(Text(preferences.defaultAtmosphere.base.label))
                Menu {
                    Button(String(localized: "No music")) { preferences.defaultAtmosphere.music = nil; preferences.profile = nil }
                    ForEach(MusicMood.allCases.filter { immersive.availableMoods.contains($0) }) { mood in
                        Button(mood.label) { preferences.defaultAtmosphere.music = mood; preferences.profile = nil }
                    }
                } label: {
                    atmosphereChip(icon: "music.note",
                                   title: preferences.defaultAtmosphere.music?.label ?? String(localized: "No music"))
                }
                .accessibilityLabel(Text("Music"))
                .accessibilityValue(Text(preferences.defaultAtmosphere.music?.label ?? String(localized: "No music")))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    private func atmosphereChip(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(palette.accent)
            Text(title).foregroundStyle(palette.text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(palette.muted)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(palette.panel, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    private func advanced(preferences: ImmersiveAudioPreferences) -> some View {
        @Bindable var preferences = preferences
        return DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When narration pauses")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Picker("When narration pauses", selection: $preferences.pausePolicy) {
                        ForEach(ImmersivePausePolicy.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Music under narration")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Picker("Music under narration", selection: $preferences.ducking) {
                        ForEach(ImmersiveAudioPreferences.Ducking.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("How much the music softens while a voice is speaking.")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
                LabeledSlider("Crossfade", value: $preferences.crossfadeSeconds, in: 8...15, step: 1,
                              display: String(localized: "\(Int(preferences.crossfadeSeconds)) s"))
                    .disabled(!preferences.smoothTransitions)
                    .opacity(preferences.smoothTransitions ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Study blocks")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Picker("Study blocks", selection: $preferences.studyBlockMinutes) {
                        Text("25 min").tag(25)
                        Text("45 min").tag(45)
                        Text("60 min").tag(60)
                        Text("Whole session").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Advanced")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
        }
        .tint(palette.muted)
        .padding(14)
        .panelCard(radius: 20)
    }

    private var sceneMaps: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scene analysis")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.text)
                Text(ByteCountFormatter.string(fromByteCount: mapsBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
            Spacer()
            Button("Delete", role: .destructive) { confirmDeleteMaps = true }
                .font(.subheadline.weight(.medium))
                .nodusTextButtonStyle()
                .disabled(mapsBytes == 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .panelCard(radius: 16)
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
                .frame(width: 22)
        }
        .font(.footnote)
        .foregroundStyle(palette.text)
    }
}

/// Chips that wrap onto as many lines as they need.
struct FlowChips<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(items) { content($0) }
        }
    }
}

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

#if DEBUG
/// The director's recent decisions, to check on a device why the
/// atmosphere held or changed (development builds only).
struct ImmersiveDecisionLog: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Decision log (development)")
            Text("Analysed \(immersive.analysedWindows) of \(immersive.totalWindows) passages · \(immersive.documentKind?.rawValue ?? "—")")
                .font(.caption.monospaced())
                .foregroundStyle(palette.muted)
            ForEach(Array(immersive.directorLog.suffix(30).reversed().enumerated()), id: \.offset) { _, event in
                Text("\(Int(event.time)) s · \(event.layer.rawValue) · \(event.isChange ? "→ \(event.to ?? "none")" : "keep") · \(event.reason)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(event.isChange ? palette.text : palette.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 16)
    }
}
#endif
