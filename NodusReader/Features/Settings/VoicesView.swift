// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

private enum VoicesMode: String, CaseIterable, Identifiable {
    case voices = "Voices"
    case models = "Models"
    var id: String { rawValue }
}

struct VoicesView: View {
    @Environment(VoiceCatalog.self) private var voices
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    @State private var mode: VoicesMode = .voices
    @State private var searchText = ""
    @State private var languageFilter: String?
    @State private var qualityFilter: Int?
    @State private var didSetInitialLanguage = false

    private var filteredVoices: [VoiceCatalog.Voice] {
        voices.voices.filter { voice in
            if let languageFilter, voice.language != languageFilter { return false }
            if let qualityFilter, voice.quality != qualityFilter { return false }
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return voice.name.localizedCaseInsensitiveContains(trimmed)
                    || voice.languageName.localizedCaseInsensitiveContains(trimmed)
                    || voice.qualityLabel.localizedCaseInsensitiveContains(trimmed)
            }
            return true
        }
    }

    private var hasFilters: Bool {
        languageFilter != nil || qualityFilter != nil || !searchText.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Voices")
                    Text("System voices installed on this \(DeviceInfo.platformName). Nothing is synced to iCloud.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Voices and models", selection: $mode) {
                    ForEach(VoicesMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Voices and models")

                if mode == .voices {
                    voiceSearchField
                    voicesContent
                } else {
                    modelsContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .task {
            await voices.loadIfNeeded()
            if !didSetInitialLanguage {
                languageFilter = voices.defaultVoice?.language
                didSetInitialLanguage = true
            }
        }
    }

    // MARK: Voices

    private var voiceSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(palette.muted)
            TextField("Search voices", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(palette.text)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(palette.panel, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    @ViewBuilder
    private var voicesContent: some View {
        HStack(spacing: 8) {
            filterMenu(title: "Language",
                       value: languageFilter.map { voices.languageName(for: $0) } ?? "All",
                       isActive: languageFilter != nil) {
                Button("All languages") { languageFilter = nil }
                Divider()
                ForEach(voices.languages, id: \.self) { language in
                    Button(voices.languageName(for: language)) { languageFilter = language }
                }
            }

            filterMenu(title: "Quality",
                       value: qualityLabel(for: qualityFilter),
                       isActive: qualityFilter != nil) {
                Button("All qualities") { qualityFilter = nil }
                Divider()
                Button("Standard") { qualityFilter = 1 }
                Button("Enhanced") { qualityFilter = 2 }
                Button("Premium") { qualityFilter = 3 }
            }

            Spacer()

            if hasFilters {
                Button("Clear") {
                    searchText = ""
                    languageFilter = nil
                    qualityFilter = nil
                }
                .font(.footnote)
                .foregroundStyle(palette.accent)
            }
        }

        Text("\(filteredVoices.count) voices\(languageFilter.map { " · \(voices.languageName(for: $0))" } ?? "")")
            .font(.caption)
            .foregroundStyle(palette.muted)

        if voices.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading system voices…")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 0) {
                ForEach(filteredVoices) { voice in
                    voiceRow(voice)
                    if voice.id != filteredVoices.last?.id {
                        Divider().overlay(palette.line)
                    }
                }
            }
            .panelCard(radius: 18)

            if filteredVoices.isEmpty {
                NodusEmptyState(icon: "waveform", title: "No voices match",
                                message: "Try clearing the search or filters.")
                    .frame(minHeight: 220)
            }
        }

        Text("Nodus Reader uses the voices already installed by the operating system. Neural Kokoro and Phonon voices are downloaded separately and also stay on this device.")
            .font(.caption)
            .foregroundStyle(palette.muted)
            .lineSpacing(2)
            .padding(.horizontal, 4)
    }

    private func voiceRow(_ voice: VoiceCatalog.Voice) -> some View {
        HStack(spacing: 12) {
            Button {
                playback.playSample(voice: voice)
            } label: {
                Image(systemName: playback.isPlayingSample ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 44, height: 44)
                    .background(palette.panel, in: Circle())
                    .overlay(Circle().stroke(palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play sample, \(voice.name)")

            Button {
                voices.setDefault(voice)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(voice.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        if voices.defaultVoiceID == voice.id {
                            Text("BOOK DEFAULT")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(palette.selection, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text("System · \(voice.languageName) · \(voice.qualityLabel)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set \(voice.name) as default voice")

            Button {
                voices.toggleFavorite(voice)
            } label: {
                Image(systemName: voices.isFavorite(voice) ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundStyle(voices.isFavorite(voice) ? palette.accent : palette.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voices.isFavorite(voice) ? "Remove favorite" : "Mark as favorite")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: Models

    @ViewBuilder
    private var modelsContent: some View {
        Eyebrow("Engines")
            .padding(.top, 2)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System voices")
                        .font(.subheadline.weight(.medium))
                    Text("\(voices.voices.count) voices · Provided by the operating system")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                Spacer()
                Label("Installed", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(palette.accent)
            }
            .padding(14)
        }
        .panelCard(radius: 18)

        Eyebrow("Neural engines")
            .padding(.top, 6)

        VStack(alignment: .leading, spacing: 10) {
            Text("Kokoro and Phonon are not installed")
                .font(.system(.title3, design: .serif))
            Text("This build narrates with the system voices above. When the neural engine arrives, Kokoro 82M and Phonon models will download here, run entirely on this device and never be uploaded to iCloud.")
                .font(.footnote)
                .foregroundStyle(palette.muted)
                .lineSpacing(2)
            Link("Model licences and sources", destination: URL(string: "https://github.com/jorgepb96/nodus-reader-mobile/blob/main/MODEL_LICENSES.md")!)
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 20)

        HStack {
            Text("Models on this \(DeviceInfo.platformName)")
            Spacer()
            Text("0 MB")
        }
        .font(.caption)
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 4)

        Text("Voice models, audio caches and OCR caches are device-local by design.")
            .font(.caption)
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 4)
    }

    // MARK: Helpers

    private func filterMenu<Content: View>(title: String, value: String, isActive: Bool,
                                           @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(isActive ? palette.onAccent : palette.muted)
                Text(value)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.footnote)
            .foregroundStyle(isActive ? palette.onAccent : palette.text)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(isActive ? palette.accent : palette.panel, in: Capsule())
            .overlay(Capsule().stroke(isActive ? Color.clear : palette.line, lineWidth: 1))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Filter by \(title)")
    }

    private func qualityLabel(for quality: Int?) -> String {
        switch quality {
        case 3: "Premium"
        case 2: "Enhanced"
        case 1: "Standard"
        default: "All"
        }
    }
}
