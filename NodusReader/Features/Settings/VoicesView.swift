// SPDX-License-Identifier: AGPL-3.0-only
import AuthenticationServices
import DesignSystem
import SwiftUI

enum VoicesMode: String, CaseIterable, Identifiable {
    case models = "Models"
    case voices = "Voices"
    /// Device-local reference voices for Qwen and Ming.
    case studio = "Studio"
    var id: String { rawValue }

    static var available: [VoicesMode] {
        #if os(iOS)
        [.models, .voices]
        #else
        allCases
        #endif
    }
}

struct VoicesView: View {
    @Environment(VoiceCatalog.self) private var voices
    @Environment(PlaybackController.self) private var playback
    @Environment(ModelManager.self) private var models
    @Environment(\.nodusPalette) private var palette

    @State private var mode: VoicesMode
    var initialMode: VoicesMode = .models
    @State private var searchText = ""
    @State private var qualityFilter: Int?
    @AppStorage(VoiceFilterSelection.storageKey) private var savedVoiceFilters = ""
    @State private var automaticVoiceFilters = VoiceFilterSelection()
    @State private var didInitializeFilters = false

    private var voiceFilters: VoiceFilterSelection {
        VoiceFilterSelection.decode(savedVoiceFilters) ?? automaticVoiceFilters
    }

    private var voiceFilterBinding: Binding<VoiceFilterSelection> {
        Binding(get: { voiceFilters }, set: { value in
            if let encoded = value.encoded { savedVoiceFilters = encoded }
        })
    }
    @State private var hfToken = ""
    @State private var hfStatus: String?
    @State private var isVerifyingToken = false
    @State private var tokenSaved = false
    @State private var showTokenGuide = false
    @State private var hfSession: HuggingFaceOAuth.Session?
    @State private var isSigningIn = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var showBundleImporter = false
    /// The gated model whose Download button was selected, shown in the
    /// Hugging Face notice before anything is downloaded.
    @State private var gatedModelToDownload: ModelManager.Model?
    /// Choosing a voice in the list switches the model without moving the
    /// filters under the user's finger.
    @State private var keepFiltersOnModelChange = false
    @AppStorage(SpeechWordAligner.enabledKey) private var preciseWordTiming = true
    @AppStorage("nodus.models.languageFilter") private var modelLanguageFilterJSON = "[]"
    @State private var showModelLanguages = false
    @State private var modelLanguageSearch = ""
    @State private var expandedModelLanguages: Set<String> = []
    @FocusState private var modelLanguageSearchFocused: Bool

    private var selectedModelLanguages: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(modelLanguageFilterJSON.utf8))) ?? [])
    }

    private var availableModelLanguages: [String] {
        Set(models.models.filter { $0.engine.isEnabled }.flatMap { $0.metadata.languages }
            .compactMap { VoiceCatalog.languageCode($0) }).sorted {
                voices.languageName(for: $0).localizedStandardCompare(voices.languageName(for: $1)) == .orderedAscending
            }
    }

    private func saveModelLanguages(_ values: Set<String>) {
        if let data = try? JSONEncoder().encode(values.sorted()) {
            modelLanguageFilterJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func languageLabels(for model: ModelManager.Model) -> [String] {
        let grouped = Dictionary(grouping: model.metadata.languages) { VoiceCatalog.languageCode($0) ?? $0 }
        return grouped.keys.sorted {
            voices.languageName(for: $0).localizedStandardCompare(voices.languageName(for: $1)) == .orderedAscending
        }.map { language in
            let flags = Set((grouped[language] ?? []).map { code -> String in
                let region = Locale(identifier: code).region?.identifier.uppercased() ?? ""
                guard region.utf8.count == 2, region.utf8.allSatisfy({ (65...90).contains($0) }) else { return "🌐" }
                return region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
            }).sorted().joined(separator: " ")
            return flags + " " + voices.languageName(for: language)
        }
    }

    private var modelLanguagePicker: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField("Search languages", text: $modelLanguageSearch)
                        .textFieldStyle(.plain)
                        .focused($modelLanguageSearchFocused)
                        .onSubmit { modelLanguageSearchFocused = false }
                        .submitLabel(.done)
                        .accessibilityIdentifier("ModelLanguageSearch")
                }
                .padding(12).background(palette.panel, in: RoundedRectangle(cornerRadius: 12)).padding(16)
                List {
                    Button { saveModelLanguages([]); modelLanguageSearchFocused = false } label: {
                        HStack {
                            Text("All languages")
                            Spacer()
                            if selectedModelLanguages.isEmpty { Image(systemName: "checkmark") }
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    ForEach(availableModelLanguages.filter {
                        modelLanguageSearch.isEmpty || voices.languageName(for: $0).localizedCaseInsensitiveContains(modelLanguageSearch)
                            || $0.localizedCaseInsensitiveContains(modelLanguageSearch)
                    }, id: \.self) { code in
                        Button {
                            var selection = selectedModelLanguages
                            if selection.contains(code) { selection.remove(code) } else { selection.insert(code) }
                            saveModelLanguages(selection)
                            modelLanguageSearchFocused = false
                        } label: {
                            HStack {
                                Text(voices.languageName(for: code))
                                Spacer()
                                Image(systemName: selectedModelLanguages.contains(code) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedModelLanguages.contains(code) ? palette.accent : palette.muted)
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("ModelLanguage-\(code)")
                        .accessibilityValue(selectedModelLanguages.contains(code) ? String(localized: "Selected") : String(localized: "Not selected"))
                    }
                }
                .listStyle(.plain)
            }
            .background(palette.background)
            .navigationTitle("Filter models by language")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showModelLanguages = false }
                }
            }
        }
        .nodusPalette(palette)
        .tint(palette.accent)
        #if os(macOS)
        .frame(width: 380, height: 480)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    init(initialMode: VoicesMode = .models) {
        self.initialMode = initialMode
        _mode = State(initialValue: VoicesMode.available.contains(initialMode) ? initialMode : .models)
    }

    private var filteredVoices: [VoiceCatalog.Voice] {
        // Every installed model, not only the selected one, so any voice can
        // be tried and chosen.
        voices.allInstalledVoices.filter { voice in
            guard voiceFilters.matches(voice) else { return false }
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
        voiceFilters.isActive || qualityFilter != nil || !searchText.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Voices")
                    Text("Voices of every model on this \(DeviceInfo.platformName). Play any of them to try it; choosing one from another model makes that model the voice engine. Voice models stay on this device. Manual voice choices can sync with iCloud.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Voices and models", selection: $mode) {
                    ForEach(VoicesMode.available) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Voices and models")

                switch mode {
                case .voices:
                    voiceSearchField
                    voicesContent
                case .models:
                    modelsContent
                case .studio:
                    StudioSection(onShowModels: { mode = .models })
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .sheet(isPresented: $showTokenGuide) {
            HuggingFaceGuideView(gatedModels: models.models.filter(\.requiresAcceptedLicense))
        }
        #if os(iOS)
        .sheet(isPresented: $showModelLanguages) { modelLanguagePicker }
        #else
        .popover(isPresented: $showModelLanguages) { modelLanguagePicker }
        #endif
        .alert("Hugging Face account required",
               isPresented: Binding(get: { gatedModelToDownload != nil },
                                    set: { if !$0 { gatedModelToDownload = nil } }),
               presenting: gatedModelToDownload) { model in
            if hasHuggingFaceAccess {
                Button("Download") { models.install(model) }
            } else {
                Button("Sign in with Hugging Face") { signInWithHuggingFace() }
            }
            Button("Show the guide") { showTokenGuide = true }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("\(model.name) is published by Gradium with a gated licence. To download it, sign in to Hugging Face and accept Gradium's conditions on the model's page with the same account. The guide explains each step.")
        }
        .persistentAppTabs()
        .onChange(of: models.selectedModelID) { _, _ in
            guard didInitializeFilters else { return }
            if keepFiltersOnModelChange {
                keepFiltersOnModelChange = false
                return
            }
            guard VoiceFilterSelection.decode(savedVoiceFilters) == nil else { return }
            let model = models.selectedModel ?? installedModels.first
            automaticVoiceFilters.models = model.map { Set([$0.id]) } ?? []
            let language = model.flatMap { models.voices(for: $0).first?.language }
                .flatMap { VoiceCatalog.languageCode($0) }
            automaticVoiceFilters.languages = language.map { Set([$0]) } ?? []
        }
        .task {
            await voices.loadIfNeeded()
            if !didInitializeFilters {
                let voice = playback.activeVoice ?? voices.defaultVoice
                let language = VoiceCatalog.languageCode(playback.activeBook?.language)
                    ?? VoiceCatalog.languageCode(voice?.language)
                let model = voice?.modelID ?? models.selectedModel?.id ?? installedModels.first?.id
                automaticVoiceFilters = VoiceFilterSelection(
                    models: model.map { Set([$0]) } ?? [],
                    languages: language.map { Set([$0]) } ?? []
                )
                if installedModels.isEmpty { mode = .models }
                didInitializeFilters = true
            }
            #if DEBUG
            // Screen captures run a differently signed build, for which the
            // Keychain would ask the person at the Mac before answering.
            let readsKeychain = UserDefaults.standard.string(forKey: "NodusShowVoices") == nil
            #else
            let readsKeychain = true
            #endif
            if readsKeychain {
                hfToken = HuggingFaceTokenStore.load() ?? ""
                tokenSaved = !hfToken.isEmpty
                hfSession = HuggingFaceSessionStore.load()
            }
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
        filterRow

        Text("\(filteredVoices.count) voices")
            .font(.caption)
            .foregroundStyle(palette.muted)

        if voices.allInstalledVoices.isEmpty {
            NodusEmptyState(icon: "waveform.badge.plus",
                            title: "No voice model installed",
                            message: "Install a Kokoro or Phonon model in the Models tab to start listening.")
                .frame(minHeight: 220)
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
            VoiceSampleButton(voice: voice, name: voice.name)

            Button {
                // A voice from a model other than the selected one switches the
                // narration engine to that model, then becomes the default.
                if let modelID = voice.modelID, modelID != models.selectedModelID {
                    keepFiltersOnModelChange = true
                    models.selectModel(modelID)
                }
                voices.setDefault(voice)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(voice.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        if voices.defaultVoiceID == voice.id {
                            Text("DEFAULT")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(palette.selection, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text("\(voice.engineLabel) · \(VoiceCatalog.variantName(for: voice.language)) · \(voice.isStudio ? String(localized: "Studio") : voice.qualityLabel)")
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

        if #available(iOS 26.0, macOS 26.0, *), models.selectedModel?.engine != .system {
            Toggle(isOn: $preciseWordTiming) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Precise word timing")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Text("Neural voices are timed word by word with Apple's on-device speech recognition, so the read-along highlight follows the audio. iOS may download its speech model for the book's language once. The audio never leaves this device.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(palette.accent)
            .padding(14)
            .panelCard(radius: 16)
        }

        Eyebrow("Available models")
            .padding(.top, 8)

        Button {
            modelLanguageSearch = ""
            showModelLanguages = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Languages")
                Spacer(minLength: 8)
                Text(selectedModelLanguages.isEmpty ? String(localized: "All languages") : selectedModelLanguages.sorted().map { voices.languageName(for: $0) }.joined(separator: ", "))
                    .foregroundStyle(palette.muted).lineLimit(2)
                Image(systemName: "chevron.down").font(.caption)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard(radius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ModelLanguageFilter")
        .accessibilityLabel("Filter models by language")
        .accessibilityValue(selectedModelLanguages.isEmpty ? String(localized: "All languages") : selectedModelLanguages.sorted().map { voices.languageName(for: $0) }.joined(separator: ", "))

        // Every model in one list, so the gated ones are found without
        // scrolling past the account section. Their Download button explains
        // the Hugging Face requirement first.
        let matchingModels = models.models.filter { model in
            model.engine.isEnabled && (selectedModelLanguages.isEmpty || model.metadata.languages.contains {
                VoiceCatalog.languageCode($0).map { selectedModelLanguages.contains($0) } ?? false
            })
        }
        ForEach(matchingModels) { model in
            modelCard(model)
        }
        if matchingModels.isEmpty {
            Text("No models match these languages.").font(.footnote).foregroundStyle(palette.muted).padding(.vertical, 12)
        }

        Button {
            showBundleImporter = true
        } label: {
            Label("Install from file…", systemImage: "folder.badge.plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Installs a Kokoro or Phonon Core ML bundle folder that is already on this device")
        .fileImporter(isPresented: $showBundleImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result {
                Task { await models.installFromFolder(folder) }
            }
        }
        if let message = models.errorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(palette.destructive)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
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
            if installedModels.isEmpty {
                Text("No voice model is installed. Download a model below to enable narration.")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(installedModels) { model in
                    if model.id != installedModels.first?.id {
                        Divider().overlay(palette.line)
                    }
                    engineRow(id: model.id,
                              title: model.name,
                              detail: String(localized: "\(models.voices(for: model).count) voices · \(model.engine == .system ? String(localized: "Provided by Apple with iOS") : model.language)"),
                              systemImage: "brain")
                }

                Divider().overlay(palette.line)

                Text("Default model for new books. Each book can keep its own voice and model.")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }

    private func engineRow(id: String, title: String, detail: String, systemImage: String) -> some View {
        Button {
            models.selectModel(id)
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
        .accessibilityLabel(models.selectedModelID == id ? "\(title), selected" : "\(title), not selected")
    }

    private func modelCard(_ model: ModelManager.Model) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(.title3, design: .serif))
                    Text(model.detail)
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

            let speed = models.performance.speed(model)
            let speedLabel = [String(localized: "Slow"), String(localized: "Moderate"), String(localized: "Fast"), String(localized: "Very fast"), String(localized: "Fastest")][ModelPerformance.bars(speed.value) - 1]
            modelRating("Speed", value: model.engine == .system ? 5 : ModelPerformance.bars(speed.value),
                        detail: model.engine == .system ? String(localized: "Very fast · Indicative rating") : speedLabel + " · " + (speed.measured ? String(localized: "Measured on this device") : String(localized: "Estimated on this device")))
            modelRating("Naturalness", value: model.metadata.naturalness, detail: String(localized: "Indicative rating"))
            Text("Languages").font(.caption.weight(.semibold))
            let languages = languageLabels(for: model)
            let expanded = expandedModelLanguages.contains(model.id)
            Text((expanded ? languages : Array(languages.prefix(10))).joined(separator: " · "))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if languages.count > 10 {
                Button {
                    if expanded { expandedModelLanguages.remove(model.id) }
                    else { expandedModelLanguages.insert(model.id) }
                } label: {
                    Label(expanded ? String(localized: "Show less") : String(localized: "Show more (+\(languages.count - 10))"),
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 6)
                }
                .nodusTextButtonStyle()
                .accessibilityIdentifier("ModelLanguagesToggle-\(model.id)")
                .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            }
            if model.engine == .system {
                Text("No download required").font(.caption)
                Text("Provided by Apple with iOS").font(.caption)
            } else {
            Text(model.sizeText + " · " + model.metadata.parameters + " · " + model.metadata.precision)
                .font(.caption).foregroundStyle(palette.muted)
            if model.metadata.clones { Label("On-device voice creation", systemImage: "mic").font(.caption) }
            Text("Code: \(model.metadata.codeLicense)").font(.caption)
            Text("Weights and voices: \(model.license)").font(.caption)
            }
            if model.requiresAcceptedLicense {
                Text("For non-commercial use only").font(.caption).foregroundStyle(palette.muted)
            }
            if model.engine == .qwen, let note = model.installNote {
                Text(note).font(.caption).foregroundStyle(palette.muted)
            }
            if model.engine == .linnet {
                Text("Linnet model weights by VoxRT, licensed under the Linnet Weights License 1.0\nPowered by Linnet (VoxRT)").font(.caption2)
                NavigationLink("Linnet licences") { LinnetLicenseView() }.font(.caption)
            }
            Link("Model card and licence", destination: model.source)
                .font(.caption2.weight(.medium)).foregroundStyle(palette.accent)

            if let note = model.availabilityNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelActions(model)

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }

    private func modelRating(_ title: LocalizedStringKey, value: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 5) {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                ForEach(1...5, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar <= value ? palette.accent : palette.line)
                        .frame(width: 7, height: CGFloat(5 + bar * 3))
                }
                Text("\(value)/5").font(.caption.monospacedDigit())
            }
            Text(detail).font(.caption2).foregroundStyle(palette.muted)
        }
        .accessibilityElement(children: .combine)
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
        case .converting:
            Label("Converting", systemImage: "gearshape.2")
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
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                }

                if model.engine != .system {
                    Button("Delete", role: .destructive) { models.delete(model) }
                        .font(.footnote).buttonStyle(.plain).foregroundStyle(palette.muted)
                }
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
        case .converting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Converting the model for this device. This can take a few minutes; keep Nodus Reader open.")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
            if model.isAvailable, model.downloadable {
                if let note = model.installNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    if model.requiresAcceptedLicense {
                        gatedModelToDownload = model
                    } else {
                        models.install(model)
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(palette.accent)
                .accessibilityLabel("Download \(model.name)")
            } else if model.isAvailable {
                // Not downloadable in the app: say how to get it, and offer
                // the folder picker right here.
                VStack(alignment: .leading, spacing: 8) {
                    if let note = model.installNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        showBundleImporter = true
                    } label: {
                        Label("Install from file…", systemImage: "folder.badge.plus")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
                }
            }
        }
    }

    /// A sign-in or a saved token; the licence itself is checked by Hugging
    /// Face when the download starts.
    private var hasHuggingFaceAccess: Bool {
        hfSession != nil || tokenSaved
    }

    private var huggingFaceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hugging Face account (optional)")
                .font(.subheadline.weight(.medium))
            Text("Kokoro 82M and Phonon 31M are public and need no account. Phonon 40M Multilingual and Spanish need an account that has accepted Gradium's conditions. Sign-in details and tokens are kept in this device's Keychain only and are never written to iCloud, the library or logs.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showTokenGuide = true
            } label: {
                Label("What is Hugging Face and how do I get a token?", systemImage: "questionmark.circle")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            huggingFaceSignIn
            Text("Or paste an access token")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.muted)
                .padding(.top, 4)
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

    /// "Sign in with Hugging Face" (OAuth with PKCE) or, once signed in, the
    /// account and a sign-out button.
    @ViewBuilder
    private var huggingFaceSignIn: some View {
        if let hfSession {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                if let account = hfSession.account {
                    Text("Signed in as \(account)")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("Signed in to Hugging Face")
                        .font(.footnote.weight(.semibold))
                }
                Spacer(minLength: 8)
                Button("Sign Out") { signOutOfHuggingFace() }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: 44)
            }
        } else {
            PrimaryPillButton("Sign in with Hugging Face", systemImage: "person.crop.circle") {
                signInWithHuggingFace()
            }
            .disabled(isSigningIn)
            .overlay(alignment: .trailing) {
                if isSigningIn {
                    ProgressView().controlSize(.small).padding(.trailing, 16)
                }
            }
        }
    }

    private func signInWithHuggingFace() {
        isSigningIn = true
        hfStatus = nil
        let request = HuggingFaceOAuth.Request()
        Task {
            defer { isSigningIn = false }
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: request.authorizeURL,
                    callback: .customScheme(HuggingFaceOAuth.callbackScheme),
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
                let code = try request.code(from: callback)
                var session = try await HuggingFaceOAuth.exchange(code: code, for: request)
                session.account = try? await HuggingFaceTokenStore.verify(session.accessToken)
                try HuggingFaceSessionStore.save(session)
                hfSession = session
                hfStatus = nil
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The person closed the sign-in sheet: nothing to report.
            } catch {
                hfStatus = error.localizedDescription
            }
        }
    }

    private func signOutOfHuggingFace() {
        HuggingFaceSessionStore.delete()
        hfSession = nil
        hfStatus = String(localized: "Signed out. To revoke Nodus Reader's access completely, remove it under Connected Apps in your Hugging Face settings.")
    }

    private func saveToken() {
        do {
            try HuggingFaceTokenStore.save(hfToken)
            tokenSaved = !hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            hfStatus = String(localized: "Token saved in the Keychain.")
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
                hfStatus = String(localized: "Signed in to Hugging Face as \(name).")
            } catch {
                hfStatus = error.localizedDescription
            }
            isVerifyingToken = false
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var installedModels: [ModelManager.Model] {
        models.models.filter { $0.isAvailable && models.isInstalled($0) }
    }

    // MARK: Helpers

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceFilterControls(selection: voiceFilterBinding,
                                modelOptions: voiceModelOptions,
                                languageOptions: voiceLanguageOptions,
                                genderOptions: voiceGenderOptions)
            HStack(spacing: 8) {
                qualityFilterMenu
                Spacer(minLength: 0)
                clearFiltersButton
            }
        }
    }

    private var voiceModelOptions: [VoiceFilterOption] {
        Set(installedModels.map(\.id)).union(voiceFilters.models).map { id in
            VoiceFilterOption(id: id, title: models.models.first { $0.id == id && $0.engine.isEnabled }?.name
                              ?? String(localized: "Unavailable model"))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var voiceLanguageOptions: [VoiceFilterOption] {
        Set(VoiceCatalog.baseLanguages(of: voices.allInstalledVoices)).union(voiceFilters.languages).map {
            VoiceFilterOption(id: $0, title: voices.languageName(for: $0))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var voiceGenderOptions: [VoiceFilterOption] {
        VoiceGender.allCases.map { VoiceFilterOption(id: $0.rawValue, title: $0.label) }
            + [VoiceFilterOption(id: VoiceFilterSelection.unspecifiedGender, title: String(localized: "Not specified"))]
    }

    private var qualityFilterMenu: some View {
        filterMenu(title: String(localized: "Quality"), systemImage: "waveform",
                   value: qualityFilter == nil ? nil : qualityLabel(for: qualityFilter),
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
            Button {
                searchText = ""
                voiceFilterBinding.wrappedValue = VoiceFilterSelection()
                qualityFilter = nil
            } label: {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 20))
                    .foregroundStyle(palette.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear filters")
        }
    }

    /// A compact chip: the filter's icon with its name, or with the chosen
    /// value once the filter is active.
    private func filterMenu<Content: View>(title: String, systemImage: String, value: String?,
                                           isActive: Bool,
                                           @ViewBuilder content: () -> Content) -> some View {
        VoiceFilterMenu(title: title, systemImage: systemImage, value: value, isActive: isActive,
                        content: content)
    }

    private func qualityLabel(for quality: Int?) -> String {
        switch quality {
        case 3: String(localized: "Premium")
        case 2: String(localized: "Enhanced")
        case 1: String(localized: "Standard")
        default: String(localized: "All")
        }
    }
}

/// Empty sets mean all values. An absent saved selection uses the current
/// book/model as an initial suggestion; explicit user choices, including
/// clearing every filter, are shared by both voice lists on this device.
struct VoiceFilterSelection: Codable, Equatable {
    static let storageKey = "nodus.voices.filters.v1"
    static let unspecifiedGender = "unspecified"
    var models: Set<String> = []
    var languages: Set<String> = []
    var genders: Set<String> = []

    var isActive: Bool { !models.isEmpty || !languages.isEmpty || !genders.isEmpty }

    static func decode(_ value: String) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(value.utf8))
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    func matches(_ voice: VoiceCatalog.Voice) -> Bool {
        (models.isEmpty || voice.modelID.map { models.contains($0) } == true)
            && (languages.isEmpty || VoiceCatalog.languageCode(voice.language).map { languages.contains($0) } == true)
            && (genders.isEmpty || genders.contains(voice.gender?.rawValue ?? Self.unspecifiedGender))
    }
}

struct VoiceFilterOption: Identifiable {
    let id: String
    let title: String
}

/// The three voice filters use the same multi-selection controls everywhere.
struct VoiceFilterControls: View {
    @Binding var selection: VoiceFilterSelection
    let modelOptions: [VoiceFilterOption]
    let languageOptions: [VoiceFilterOption]
    let genderOptions: [VoiceFilterOption]

    var body: some View {
        // Fixed, equally flexible slots: long selected names truncate instead
        // of creating a second row or replacing the menu while it is open.
        HStack(spacing: 8) {
            multiFilter(title: String(localized: "Model"), icon: "cpu", all: String(localized: "All models"),
                        options: modelOptions, selected: $selection.models, identifier: "VoiceModelFilter")
            multiFilter(title: String(localized: "Language"), icon: "globe", all: String(localized: "All languages"),
                        options: languageOptions, selected: $selection.languages, identifier: "VoiceLanguageFilter")
            multiFilter(title: String(localized: "Gender"), icon: "person.2", all: String(localized: "All genders"),
                        options: genderOptions, selected: $selection.genders, identifier: "VoiceGenderFilter")
        }
        .frame(maxWidth: .infinity)
    }

    private func multiFilter(title: String, icon: String, all: String, options: [VoiceFilterOption],
                             selected: Binding<Set<String>>, identifier: String) -> some View {
        VoiceMultiSelectionFilter(title: title, icon: icon, all: all, options: options, selected: selected,
                                  identifier: identifier)
            .frame(minWidth: 0, maxWidth: .infinity)
    }
}

/// A stable, scrollable picker rather than a native Menu rebuilt by playback
/// updates. Snapshot the options when opening; row IDs and scroll state remain
/// unchanged while the user scrolls or checks multiple languages.
private struct VoiceMultiSelectionFilter: View {
    let title: String
    let icon: String
    let all: String
    let options: [VoiceFilterOption]
    @Binding var selected: Set<String>
    let identifier: String
    @Environment(\.nodusPalette) private var palette
    @State private var isPresented = false
    @State private var presentedOptions: [VoiceFilterOption] = []
    @State private var query = ""

    private var selectedNames: [String] {
        options.filter { selected.contains($0.id) }.map(\.title)
    }

    private var summary: String {
        if selected.isEmpty { return title }
        if selected.count == 1 { return selectedNames.first ?? title }
        return "\(title) (\(selected.count))"
    }

    private var matchingOptions: [VoiceFilterOption] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? presentedOptions : presentedOptions.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Button {
            presentedOptions = options
            query = ""
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(selected.isEmpty ? palette.text : palette.onAccent)
            .padding(.horizontal, 9)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
            .background(selected.isEmpty ? palette.panel : palette.accent, in: Capsule())
            .overlay(Capsule().stroke(selected.isEmpty ? palette.line : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text("Filter by \(title)"))
        .accessibilityValue(selected.isEmpty ? all : selectedNames.joined(separator: ", "))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button("Done") { isPresented = false }
                }
                .padding(12)
                if presentedOptions.count > 10 {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        TextField("Search", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(10)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                List {
                    Button { selected = [] } label: {
                        optionLabel(all, checked: selected.isEmpty)
                    }
                    .listRowBackground(palette.panel)
                    ForEach(matchingOptions) { option in
                        Button {
                            if selected.contains(option.id) { selected.remove(option.id) }
                            else { selected.insert(option.id) }
                        } label: {
                            optionLabel(option.title, checked: selected.contains(option.id))
                        }
                        .accessibilityIdentifier("\(identifier)-\(option.id)")
                        .accessibilityAddTraits(selected.contains(option.id) ? .isSelected : [])
                        .listRowBackground(palette.panel)
                    }
                }
                .buttonStyle(.plain)
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .foregroundStyle(palette.text)
            .background(palette.background)
            .tint(palette.accent)
            .frame(width: 300, height: min(440, CGFloat(presentedOptions.count + 1) * 48 + 64))
            .presentationCompactAdaptation(.popover)
        }
    }

    private func optionLabel(_ label: String, checked: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .foregroundStyle(palette.accent)
                .opacity(checked ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A filter chip with a menu (Model, Language, Gender, Quality), shared by the Voices
/// screen and the book's voice picker.
struct VoiceFilterMenu<Content: View>: View {
    let title: String
    let systemImage: String
    let value: String?
    let isActive: Bool
    let content: Content
    @Environment(\.nodusPalette) private var palette

    init(title: String, systemImage: String, value: String?, isActive: Bool,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(value ?? title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isActive ? palette.onAccent : palette.text)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isActive ? palette.accent : palette.panel, in: Capsule())
            .overlay(Capsule().stroke(isActive ? Color.clear : palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .nodusMenuLabelStyle()
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Filter by \(title)"))
        .accessibilityValue(value ?? String(localized: "All"))
    }
}

/// Plays a voice's sample sentence. Synthesis can take seconds while a neural
/// model loads, so the button spins until the audio starts instead of looking
/// as if nothing happened; selecting it again stops the sample.
struct VoiceSampleButton: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    let voice: VoiceCatalog.Voice?
    let name: String
    var diameter: CGFloat = 44

    private var isCurrent: Bool {
        voice != nil && playback.isPlayingSample && playback.sampleVoiceID == voice?.id
    }

    private var isPreparing: Bool { isCurrent && playback.isPreparingSample }

    var body: some View {
        Button {
            if isCurrent {
                playback.stopSample()
            } else if let voice {
                playback.playSample(voice: voice)
            }
        } label: {
            ZStack {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.accent)
                } else {
                    Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: diameter > 40 ? 14 : 13, weight: .semibold))
                        .foregroundStyle(palette.text)
                }
            }
            .frame(width: diameter, height: diameter)
            .background(palette.panel, in: Circle())
            .overlay(Circle().stroke(isPreparing ? palette.accent : palette.line, lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(voice == nil)
        .accessibilityLabel(isPreparing ? Text("Loading sample, \(name)")
                                        : isCurrent ? Text("Stop sample, \(name)")
                                                    : Text("Play sample, \(name)"))
    }
}

private struct LinnetLicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(["LinnetNotice", "LinnetWeightsLicense", "LinnetCodeLicense"], id: \.self) { name in
                    Text((Bundle.main.url(forResource: name, withExtension: "txt").flatMap {
                        try? String(contentsOf: $0, encoding: .utf8)
                    }) ?? name).font(.footnote).textSelection(.enabled)
                }
            }.padding()
        }.navigationTitle("Linnet licences")
    }
}
