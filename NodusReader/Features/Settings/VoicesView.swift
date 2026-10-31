// SPDX-License-Identifier: AGPL-3.0-only
import AuthenticationServices
import DesignSystem
import SwiftUI

enum VoicesMode: String, CaseIterable, Identifiable {
    case voices = "Voices"
    case models = "Models"
    var id: String { rawValue }
}

struct VoicesView: View {
    @Environment(VoiceCatalog.self) private var voices
    @Environment(PlaybackController.self) private var playback
    @Environment(ModelManager.self) private var models
    @Environment(\.nodusPalette) private var palette

    @State private var mode: VoicesMode
    var initialMode: VoicesMode = .voices
    @State private var searchText = ""
    @State private var languageFilter: String?
    @State private var qualityFilter: Int?
    @State private var engineFilter: String?
    @State private var didSetInitialLanguage = false
    @State private var hfToken = ""
    @State private var hfStatus: String?
    @State private var isVerifyingToken = false
    @State private var tokenSaved = false
    @State private var showTokenGuide = false
    @State private var hfSession: HuggingFaceOAuth.Session?
    @State private var isSigningIn = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var showBundleImporter = false
    /// Choosing a voice in the list switches the model without moving the
    /// filters under the user's finger.
    @State private var keepFiltersOnModelChange = false
    @AppStorage(SpeechWordAligner.enabledKey) private var preciseWordTiming = true

    init(initialMode: VoicesMode = .voices) {
        self.initialMode = initialMode
        _mode = State(initialValue: initialMode)
    }

    private var filteredVoices: [VoiceCatalog.Voice] {
        // Every installed model, not only the selected one, so any voice can
        // be tried and chosen.
        voices.allInstalledVoices.filter { voice in
            if let languageFilter, let code = VoiceCatalog.languageCode(languageFilter),
               !voice.language.lowercased().hasPrefix(code) { return false }
            if let qualityFilter, voice.quality != qualityFilter { return false }
            if let engineFilter, voice.modelID != engineFilter { return false }
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
                    Text("Voices of every model on this \(DeviceInfo.platformName). Play any of them to try it; choosing one from another model makes that model the voice engine. Nothing is synced to iCloud.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Voices and models", selection: $mode) {
                    ForEach(VoicesMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
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
            if keepFiltersOnModelChange {
                keepFiltersOnModelChange = false
                return
            }
            if let model = models.selectedModel ?? installedModels.first {
                engineFilter = model.id
                if let first = model.voices.first {
                    languageFilter = first.language
                }
            } else {
                engineFilter = nil
            }
        }
        .task {
            await voices.loadIfNeeded()
            if !didSetInitialLanguage {
                let bookLanguage = VoiceCatalog.languageCode(playback.activeBook?.language)
                let modelLanguage = VoiceCatalog.languageCode(
                    (models.selectedModel ?? installedModels.first)?.voices.first?.language
                )
                let preferred = bookLanguage ?? modelLanguage
                    ?? VoiceCatalog.languageCode(voices.defaultVoice?.language)
                if let preferred,
                   let match = voices.voices.first(where: { $0.language.lowercased().hasPrefix(preferred) }) {
                    languageFilter = match.language
                }
                engineFilter = (models.selectedModel ?? installedModels.first)?.id
                if installedModels.isEmpty { mode = .models }
                didSetInitialLanguage = true
            }
            hfToken = HuggingFaceTokenStore.load() ?? ""
            tokenSaved = !hfToken.isEmpty
            hfSession = HuggingFaceSessionStore.load()
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
        // One row: icon chips, then Clear. On the narrowest widths the row
        // scrolls sideways instead of wrapping.
        ViewThatFits(in: .horizontal) {
            filterRow
            ScrollView(.horizontal, showsIndicators: false) { filterRow }
        }

        Group {
            if let languageFilter {
                Text("\(filteredVoices.count) voices · \(voices.languageName(for: languageFilter))")
            } else {
                Text("\(filteredVoices.count) voices")
            }
        }
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
                    Text("\(voice.engineLabel) · \(VoiceCatalog.variantName(for: voice.language)) · \(voice.qualityLabel)")
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

        if #available(iOS 26.0, macOS 26.0, *) {
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

        Eyebrow("Neural engines")
            .padding(.top, 8)

        ForEach(models.models.filter { !$0.requiresAcceptedLicense }) { model in
            modelCard(model)
        }

        // The account section sits right above the models whose licence must
        // be accepted on Hugging Face.
        Eyebrow("Hugging Face")
            .padding(.top, 6)

        huggingFaceCard

        ForEach(models.models.filter(\.requiresAcceptedLicense)) { model in
            modelCard(model)
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
                Text("No voice model is installed. Download a Kokoro or Phonon model below to enable narration.")
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
                              detail: String(localized: "\(model.voices.count) voices · \(model.language)"),
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
            engineFilter = models.selectedModel?.id
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
                        engineFilter = model.id
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
                    models.install(model)
                } label: {
                    Label("Download \(model.sizeText)", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(palette.accent)
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

    private var huggingFaceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hugging Face account (optional)")
                .font(.subheadline.weight(.medium))
            Text("The Kokoro and Phonon bundles used here are public, so no account is required. Sign-in details and tokens are kept in this device's Keychain only and are never written to iCloud, the library or logs.")
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
            .sheet(isPresented: $showTokenGuide) {
                HuggingFaceGuideView(gatedModels: models.models.filter(\.requiresAcceptedLicense))
            }
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

    private func engineLabel(for engine: String?) -> String {
        guard let engine else { return String(localized: "All") }
        return models.models.first { $0.id == engine }?.name ?? String(localized: "All")
    }

    // MARK: Helpers

    private var filterRow: some View {
        HStack(spacing: 6) {
            modelFilterMenu
            languageFilterMenu
            qualityFilterMenu
            Spacer(minLength: 0)
            clearFiltersButton
        }
    }

    private var modelFilterMenu: some View {
        filterMenu(title: String(localized: "Model"), systemImage: "cpu",
                   value: engineFilter == nil ? nil : engineLabel(for: engineFilter),
                   isActive: engineFilter != nil) {
            Button("All models") { engineFilter = nil }
            Divider()
            // Each downloaded model, selected or not.
            ForEach(installedModels) { model in
                Button(model.name) { engineFilter = model.id }
            }
        }
    }

    private var languageFilterMenu: some View {
        filterMenu(title: String(localized: "Language"), systemImage: "globe",
                   value: languageFilter.map { voices.languageName(for: $0) },
                   isActive: languageFilter != nil) {
            Button("All languages") { languageFilter = nil }
            Divider()
            ForEach(VoiceCatalog.baseLanguages(of: voices.allInstalledVoices), id: \.self) { language in
                Button(voices.languageName(for: language)) { languageFilter = language }
            }
        }
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
                languageFilter = nil
                qualityFilter = nil
                engineFilter = nil
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

/// A filter chip with a menu (Model, Language, Quality), shared by the Voices
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
            .font(.footnote)
            .foregroundStyle(isActive ? palette.onAccent : palette.text)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(isActive ? palette.accent : palette.panel, in: Capsule())
            .overlay(Capsule().stroke(isActive ? Color.clear : palette.line, lineWidth: 1))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Filter by \(title)"))
        .accessibilityValue(value ?? String(localized: "All"))
    }
}
