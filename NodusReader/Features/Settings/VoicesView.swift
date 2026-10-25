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
    @Environment(ModelManager.self) private var models
    @Environment(\.nodusPalette) private var palette

    @State private var mode: VoicesMode = .voices
    @State private var searchText = ""
    @State private var languageFilter: String?
    @State private var qualityFilter: Int?
    @State private var engineFilter: String?
    @State private var didSetInitialLanguage = false
    @State private var hfToken = ""
    @State private var hfStatus: String?
    @State private var isVerifyingToken = false
    @State private var tokenSaved = false

    private var filteredVoices: [VoiceCatalog.Voice] {
        voices.voices.filter { voice in
            if let languageFilter, let code = VoiceCatalog.languageCode(languageFilter),
               !voice.language.lowercased().hasPrefix(code) { return false }
            if let qualityFilter, voice.quality != qualityFilter { return false }
            if let engineFilter, voice.engineRaw != engineFilter { return false }
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
        languageFilter != nil || qualityFilter != nil || engineFilter != nil || !searchText.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Voices")
                    Text("Voices available on this \(DeviceInfo.platformName). Only the selected voice engine is shown; nothing is synced to iCloud.")
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
        .onChange(of: models.selectedModelID) { _, _ in
            guard didSetInitialLanguage else { return }
            if let model = models.selectedModel {
                engineFilter = model.engine.rawValue
                if let first = model.voices.first {
                    languageFilter = first.language
                }
            } else {
                engineFilter = "system"
                if !voices.voices(matchingLanguage: languageFilter).contains(where: { $0.isSystem }),
                   let system = voices.bestSystemVoice {
                    languageFilter = system.language
                }
            }
        }
        .task {
            await voices.loadIfNeeded()
            if !didSetInitialLanguage {
                let bookLanguage = VoiceCatalog.languageCode(playback.activeBook?.language)
                let modelLanguage = VoiceCatalog.languageCode(models.selectedModel?.voices.first?.language)
                let preferred = bookLanguage ?? modelLanguage
                    ?? VoiceCatalog.languageCode(voices.defaultVoice?.language)
                if let preferred,
                   let match = voices.voices.first(where: { $0.language.lowercased().hasPrefix(preferred) }) {
                    languageFilter = match.language
                }
                let code = VoiceCatalog.languageCode(languageFilter)
                if let model = models.selectedModel {
                    let modelSupportsLanguage = code.map { prefix in
                        model.voices.contains { $0.language.lowercased().hasPrefix(prefix) }
                    } ?? false
                    let systemSupportsLanguage = code.map { prefix in
                        voices.voices.contains { $0.isSystem && $0.language.lowercased().hasPrefix(prefix) }
                    } ?? false
                    engineFilter = modelSupportsLanguage || !systemSupportsLanguage
                        ? model.engine.rawValue
                        : "system"
                } else {
                    engineFilter = "system"
                }
                didSetInitialLanguage = true
            }
            hfToken = HuggingFaceTokenStore.load() ?? ""
            tokenSaved = !hfToken.isEmpty
            await models.refreshStorage()
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                modelFilterMenu
                languageFilterMenu
                qualityFilterMenu
                Spacer(minLength: 4)
                clearFiltersButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    modelFilterMenu
                    Spacer(minLength: 4)
                    clearFiltersButton
                }
                HStack(spacing: 8) {
                    languageFilterMenu
                    qualityFilterMenu
                    Spacer(minLength: 0)
                }
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
                Image(systemName: playback.isPlayingSample && playback.sampleVoiceID == voice.id
                      ? "speaker.wave.2.fill" : "play.fill")
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
                    Text("\(voice.engineLabel) · \(voice.languageName) · \(voice.qualityLabel)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voices.defaultVoiceID == voice.id
                                ? "\(voice.name) is the default voice"
                                : "Set \(voice.name) as default voice")
            .accessibilityAddTraits(voices.defaultVoiceID == voice.id ? [.isSelected] : [])

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
        Eyebrow("Voice engine")
            .padding(.top, 2)

        engineSelectionCard

        Eyebrow("Neural engines")
            .padding(.top, 8)

        ForEach(models.models) { model in
            modelCard(model)
        }

        Eyebrow("Hugging Face")
            .padding(.top, 6)

        huggingFaceCard

        HStack {
            Text("Models and audio on this \(DeviceInfo.platformName)")
            Spacer()
            Text(byteText(models.storage.totalBytes))
        }
        .font(.caption)
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 4)

        Text("Voice models, generated audio and OCR caches are device-local by design. They are excluded from backup and never enter iCloud.")
            .font(.caption)
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 4)
    }

    private var engineSelectionCard: some View {
        VStack(spacing: 0) {
            engineRow(id: ModelManager.systemModelID,
                      title: "System voices",
                      detail: "Voices provided by \(DeviceInfo.platformName)",
                      systemImage: "waveform")

            ForEach(models.models.filter { models.isInstalled($0) }) { model in
                Divider().overlay(palette.line)
                engineRow(id: model.id,
                          title: model.name,
                          detail: "\(model.voices.count) voices · \(model.language)",
                          systemImage: "brain")
            }

            Divider().overlay(palette.line)

            Text("Only the selected voice engine appears in the reader and player voice lists. System voices are always available as a fallback.")
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }

    private func engineRow(id: String, title: String, detail: String, systemImage: String) -> some View {
        Button {
            models.selectModel(id)
            engineFilter = id == ModelManager.systemModelID ? "system" : models.selectedModel?.engine.rawValue
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)
                    .background(palette.selection, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                Spacer()
                if models.selectedModelID == id {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(models.selectedModelID == id ? "selected" : "not selected")")
    }

    private func modelCard(_ model: ModelManager.Model) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(.title3, design: .serif))
                    Text("\(model.detail) · \(model.language)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if models.isSelected(model) {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.accent)
                } else {
                    stateBadge(for: model)
                }
            }

            HStack(spacing: 10) {
                Label(model.license, systemImage: "doc.text")
                Text(model.sizeText)
                if !model.voices.isEmpty, models.isInstalled(model) {
                    Text("\(model.voices.count) voices")
                }
            }
            .font(.caption2)
            .foregroundStyle(palette.muted)

            if let note = model.availabilityNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelActions(model)

            Link("Model card and licence", destination: model.source)
                .font(.caption2.weight(.medium))
                .foregroundStyle(palette.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }

    @ViewBuilder
    private func stateBadge(for model: ModelManager.Model) -> some View {
        switch models.state(for: model) {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.accent)
        case .downloading(let progress):
            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.accent)
        case .paused(let progress):
            Text("Paused · \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(palette.muted)
        case .loading:
            Label("Preparing", systemImage: "gearshape.2")
                .font(.caption)
                .foregroundStyle(palette.muted)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(palette.accent)
        case .notInstalled:
            if model.isAvailable {
                Text("Available")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            } else {
                Label("Unavailable", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
        }
    }

    @ViewBuilder
    private func modelActions(_ model: ModelManager.Model) -> some View {
        switch models.state(for: model) {
        case .installed:
            HStack(spacing: 14) {
                if models.isSelected(model) {
                    Label("Voice engine selected", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.accent)
                } else {
                    Button("Use this model") {
                        models.selectModel(model)
                        engineFilter = model.engine.rawValue
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                }

                Button("Delete", role: .destructive) {
                    models.delete(model)
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(palette.muted)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                    .tint(palette.accent)
                HStack {
                    Text("Downloading from Hugging Face")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                    Spacer()
                    Button("Pause") { models.pause(model) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                }
            }
        case .paused:
            HStack(spacing: 14) {
                Button("Resume") { models.resume(model) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                Button("Delete partial download", role: .destructive) { models.delete(model) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.muted)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compiling for this device. This can take a minute the first time.")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Retry") { models.install(model) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                    Button("Delete", role: .destructive) { models.delete(model) }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.muted)
                }
            }
        case .notInstalled:
            if model.isAvailable {
                Button {
                    models.install(model)
                } label: {
                    Label("Download \(model.sizeText)", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(palette.accent)
            }
        }
    }

    private var huggingFaceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional access token")
                .font(.subheadline.weight(.medium))
            Text("The Kokoro and Phonon bundles used here are public, so no account is required. A token is kept in this device's Keychain only and is never written to iCloud, the library or logs.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("hf_…", text: $hfToken)
                .textFieldStyle(.plain)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
            HStack(spacing: 14) {
                Button(tokenSaved ? "Update token" : "Save token") {
                    saveToken()
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .disabled(hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if tokenSaved {
                    Button("Verify") { verifyToken() }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                        .disabled(isVerifyingToken)
                    Button("Remove") {
                        HuggingFaceTokenStore.delete()
                        hfToken = ""
                        tokenSaved = false
                        hfStatus = nil
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.muted)
                }
                if isVerifyingToken {
                    ProgressView().controlSize(.small)
                }
            }
            if let hfStatus {
                Text(hfStatus)
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }

    private func saveToken() {
        do {
            try HuggingFaceTokenStore.save(hfToken)
            tokenSaved = !hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            hfStatus = "Token saved in the Keychain."
        } catch {
            hfStatus = error.localizedDescription
        }
    }

    private func verifyToken() {
        isVerifyingToken = true
        hfStatus = nil
        let token = hfToken
        Task {
            do {
                let name = try await HuggingFaceTokenStore.verify(token)
                hfStatus = "Signed in to Hugging Face as \(name)."
            } catch {
                hfStatus = error.localizedDescription
            }
            isVerifyingToken = false
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func engineLabel(for engine: String?) -> String {
        switch engine {
        case "system": "System"
        case "kokoro": "Kokoro 82M"
        case "phonon": "Phonon 31M"
        default: "All"
        }
    }

    // MARK: Helpers

    private var modelFilterMenu: some View {
        filterMenu(title: "Model",
                   value: engineLabel(for: engineFilter),
                   isActive: engineFilter != nil) {
            Button("All models") { engineFilter = nil }
            Divider()
            Button("System") { engineFilter = "system" }
            if voices.voices.contains(where: { $0.engineRaw == "kokoro" }) {
                Button("Kokoro 82M") { engineFilter = "kokoro" }
            }
            if voices.voices.contains(where: { $0.engineRaw == "phonon" }) {
                Button("Phonon 31M") { engineFilter = "phonon" }
            }
        }
    }

    private var languageFilterMenu: some View {
        filterMenu(title: "Language",
                   value: languageFilter.map { voices.languageName(for: $0) } ?? "All",
                   isActive: languageFilter != nil) {
            Button("All languages") { languageFilter = nil }
            Divider()
            ForEach(voices.languages, id: \.self) { language in
                Button(voices.languageName(for: language)) { languageFilter = language }
            }
        }
    }

    private var qualityFilterMenu: some View {
        filterMenu(title: "Quality",
                   value: qualityLabel(for: qualityFilter),
                   isActive: qualityFilter != nil) {
            Button("All qualities") { qualityFilter = nil }
            Divider()
            Button("Standard") { qualityFilter = 1 }
            Button("Enhanced") { qualityFilter = 2 }
            Button("Premium") { qualityFilter = 3 }
        }
    }

    @ViewBuilder
    private var clearFiltersButton: some View {
        if hasFilters {
            Button("Clear") {
                searchText = ""
                languageFilter = nil
                qualityFilter = nil
                engineFilter = nil
            }
            .font(.footnote)
            .foregroundStyle(palette.accent)
        }
    }

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
            .fixedSize(horizontal: true, vertical: false)
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
