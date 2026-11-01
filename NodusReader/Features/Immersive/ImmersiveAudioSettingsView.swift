// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Settings › Immersive Audio: music and ambient sound under reading and
/// narration. Off until the reader turns it on.
struct ImmersiveAudioSettingsView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette

    @State private var showAdvanced = false
    @State private var mapsBytes: Int64 = 0
    @State private var confirmDeleteMaps = false

    private var preferences: ImmersiveAudioPreferences { immersive.preferences }

    var body: some View {
        @Bindable var preferences = immersive.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Immersive Audio")
                    Text("Quiet instrumental music and ambient sound while you read or listen, chosen for the passage you are in and kept steady.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: Binding(get: { preferences.isEnabled }, set: { immersive.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Immersive Audio")
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

                if !immersive.library.hasAnything {
                    packsNotice
                }

                if preferences.isEnabled {
                    profiles
                    modeSection(preferences: preferences)
                    levels(preferences: preferences)
                    defaultAtmosphere(preferences: preferences)
                    advanced(preferences: preferences)
                }

                Eyebrow("Sounds")
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    NavigationLink {
                        ImmersivePacksView()
                    } label: {
                        SettingsRow(title: "Sound packs", value: ByteCountFormatter.string(
                            fromByteCount: immersive.library.bytesOnDisk, countStyle: .file))
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
                    point("lock", "Everything happens on this device: the sounds are downloaded once and played offline, and in Automatic mode Apple Intelligence reads the passages here. No text or audio leaves the device.")
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
        .navigationTitle("Immersive Audio")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
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
    }

    // MARK: Sections

    private var packsNotice: some View {
        Label {
            Text("Download a sound pack to hear Immersive Audio. The sounds are stored on this device and play offline.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.down.circle")
        }
        .font(.footnote)
        .foregroundStyle(palette.text)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 16)
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

    private func levels(preferences: ImmersiveAudioPreferences) -> some View {
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
            Divider().overlay(palette.line)
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

    private func defaultAtmosphere(preferences: ImmersiveAudioPreferences) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(preferences.mode == .automatic ? "Before the story is analysed" : "Atmosphere")
            HStack(spacing: 10) {
                Menu {
                    ForEach([BaseAmbience.none] + BaseAmbience.allCases.filter { immersive.library.installedBeds.contains($0) }) { bed in
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
                    ForEach(MusicMood.allCases.filter { immersive.library.installedMoods.contains($0) }) { mood in
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

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
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
