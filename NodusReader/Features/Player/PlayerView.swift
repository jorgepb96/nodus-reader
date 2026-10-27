// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct PlayerView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(ModelManager.self) private var models
    @Environment(\.dismiss) private var dismiss

    @State private var showVoicePicker = false

    /// The app theme's palette, or the reader theme's when the player is
    /// opened from the reader: the player matches the screen it covers.
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                handle
                topBar
                coverAndText
                scrubber
                transport
                if playback.isLoading {
                    Text(loadingText)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .padding(.top, 8)
                        .accessibilityIdentifier("PlayerLoadingText")
                }
                controlGrid
                audioCacheCard
                footer
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 56)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(palette.text)
        .background(playerBackground)
        .nodusPalette(palette)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerSheet()
                .nodusPalette(palette)
                .tint(palette.accent)
                .environment(\.colorScheme, palette.isDark ? .dark : .light)
                .preferredColorScheme(palette.isDark ? .dark : .light)
        }
        .overlay {
            if let error = playback.errorMessage {
                errorOverlay(error)
            }
        }
        .task { await playback.refreshAudioCacheSize() }
    }

    private var audioCacheCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Offline audio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text(playback.audioCacheBytes > 0
                         ? "\(ByteCountFormatter.string(fromByteCount: playback.audioCacheBytes, countStyle: .file)) cached on this device"
                         : "Cached sentence by sentence as you listen")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                }
                Spacer()
            }

            if playback.isGeneratingAudioCache {
                ProgressView(value: playback.audioCacheProgress ?? 0)
                    .tint(palette.accent)
                HStack {
                    Text("Generating every sentence with \(playback.activeVoice?.name ?? String(localized: "this voice"))…")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                    Spacer()
                    Button("Cancel") { playback.cancelAudioCacheGeneration() }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            } else {
                HStack(spacing: 16) {
                    Button("Generate for this book") {
                        playback.generateAudioCacheForCurrentBook()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(playback.isNeuralVoice ? palette.accent : palette.muted)
                    .disabled(!playback.isNeuralVoice)

                    if playback.audioCacheBytes > 0 {
                        Button("Delete cache") {
                            Task { await playback.deleteAudioCacheForCurrentBook() }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                    }
                    Spacer()
                }
                if !playback.isNeuralVoice {
                    Text("Choose a Kokoro or Phonon voice to generate offline audio.")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = playback.cacheErrorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.line, lineWidth: 1)
        )
        .padding(.top, 12)
    }

    private var playerBackground: some View {
        palette.background
            .ignoresSafeArea()
    }

    private var handle: some View {
        Capsule()
            .fill(palette.text.opacity(0.25))
            .frame(width: 38, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")

            Spacer()

            Text("\(playbackTopLabel) · FROM CHAPTER \(playback.chapterNumber)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(2)
                .foregroundStyle(palette.muted)
                .lineLimit(1)

            Spacer()

            Menu {
                Button {
                    playback.stopAndClose()
                    dismiss()
                } label: {
                    Label("Stop narration", systemImage: "stop.fill")
                }
                Button {
                    showVoicePicker = true
                } label: {
                    Label("Choose voice…", systemImage: "waveform")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Player options")
        }
        .padding(.bottom, 8)
    }

    private var coverAndText: some View {
        VStack(spacing: 20) {
            Group {
                if let book = playback.activeBook {
                    BookCoverView(book: book, showBadges: false)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(palette.panel)
                }
            }
            .frame(width: 164, height: 246)
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text(playback.activeBook?.title ?? String(localized: "Nothing playing"))
                    .font(.system(size: 26, design: .serif))
                    .tracking(-0.3)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(playback.activeBook?.displayAuthor ?? "") · \(playback.chapterTitle)")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            contextText
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    private var playbackTopLabel: String {
        switch playback.mode {
        case .listen: playback.isPlaying ? String(localized: "LISTENING") : String(localized: "LISTEN")
        case .readAndListen: String(localized: "READ & LISTEN")
        case .read: String(localized: "READING")
        }
    }

    private var contextText: some View {
        var attributed = AttributedString()
        if let previous = playback.previousSentenceText {
            var part = AttributedString("…\(previous.suffix(48)) ")
            part.foregroundColor = palette.muted
            attributed.append(part)
        }
        var current = AttributedString(playback.currentSentence)
        current.foregroundColor = palette.text
        current.font = .system(size: 17, design: .serif).weight(.medium)
        attributed.append(current)
        if let next = playback.nextSentenceText {
            var part = AttributedString(" \(next.prefix(48))…")
            part.foregroundColor = palette.muted
            attributed.append(part)
        }
        return Text(attributed)
            .font(.system(size: 17, design: .serif))
            .lineSpacing(5)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            NarrationScrubber(
                index: playback.currentIndex,
                total: max(playback.sentenceCount, 1)
            ) { value in
                playback.seek(to: value)
            }
            HStack {
                Text("Sentence \(playback.sentenceNumber) of \(max(playback.sentenceCount, 1))")
                Spacer()
                Text("Chapter \(playback.chapterNumber) of \(max(playback.chapterCount, 1))")
            }
            .font(.caption2)
            .foregroundStyle(palette.muted)
            .monospacedDigit()
        }
        .padding(.top, 18)
    }

    /// What the play button is waiting for: the model loading into memory
    /// (the first time, several seconds) or the next sentence being made.
    private var loadingText: String {
        models.loadingEngine != nil
            ? String(localized: "Loading the voice model on this device…")
            : String(localized: "Preparing the voice…")
    }

    private var transport: some View {
        HStack {
            transportButton("backward.end", label: "Previous chapter") { playback.previousChapter() }
                .frame(maxWidth: .infinity)
            transportButton("gobackward", label: "Previous sentence") { playback.previousSentence() }
                .frame(maxWidth: .infinity)
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .offset(x: playback.isPlaying ? 0 : 2)
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 76, height: 76)
                    .background(palette.accent, in: Circle())
                    .overlay {
                        if playback.isLoading {
                            LoadingRing(color: palette.onAccent, lineWidth: 3.5).padding(5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .accessibilityValue(playback.isLoading ? loadingText : "")
            transportButton("goforward", label: "Next sentence") { playback.nextSentence() }
                .frame(maxWidth: .infinity)
            transportButton("forward.end", label: "Next chapter") { playback.nextChapter() }
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 12)
    }

    private func transportButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(palette.text)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var controlGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            speedControl
            voiceControl
            sleepControl
            modeControl
        }
        .padding(.top, 16)
    }

    private var speedControl: some View {
        Menu {
            ForEach(PlaybackController.speedOptions, id: \.self) { speed in
                Button {
                    playback.setSpeed(speed)
                } label: {
                    Label(String(format: "%g×", speed),
                          systemImage: playback.speedMultiplier == speed ? "checkmark" : "circle")
                }
            }
        } label: {
            controlTile(top: playback.speedLabel, bottom: String(localized: "Speed"), highlighted: false)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Playback speed")
    }

    private var voiceControl: some View {
        Button {
            showVoicePicker = true
        } label: {
            controlTile(top: playback.activeVoice?.name ?? String(localized: "Voice"),
                        bottom: playback.preferredVoiceIsMissing ? String(localized: "Install voice") : playback.engineLabel,
                        highlighted: playback.preferredVoiceIsMissing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice for this book")
        .accessibilityHint(playback.preferredVoiceIsMissing
                           ? String(localized: "The voice chosen for this book is not installed on this device")
                           : "")
    }

    private var sleepControl: some View {
        Menu {
            ForEach(SleepTimerOption.allCases) { option in
                Button {
                    playback.setSleepTimer(option)
                } label: {
                    Label(option.label, systemImage: playback.sleepTimer == option ? "checkmark" : "circle")
                }
            }
        } label: {
            controlTile(
                icon: "moon",
                top: playback.sleepRemainingLabel ?? playback.sleepTimer.shortLabel,
                bottom: String(localized: "Sleep"),
                highlighted: playback.sleepTimer != .off
            )
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Sleep timer")
    }

    private var modeControl: some View {
        Menu {
            ForEach(ReadingMode.allCases) { mode in
                Button {
                    playback.setMode(mode)
                    if mode == .read { dismiss() }
                } label: {
                    Label(mode.label, systemImage: playback.mode == mode ? "checkmark" : "circle")
                }
            }
        } label: {
            controlTile(
                icon: "book.pages",
                top: playback.mode.label,
                bottom: String(localized: "Mode"),
                highlighted: playback.mode == .readAndListen
            )
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Reading mode")
    }

    private func controlTile(top: String, bottom: String, highlighted: Bool) -> some View {
        VStack(spacing: 3) {
            Text(top)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(highlighted ? palette.accent : palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(bottom)
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(highlighted ? palette.selection : palette.panel,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(highlighted ? palette.accent.opacity(0.3) : palette.line, lineWidth: 1)
        )
    }

    private func controlTile(icon: String, top: String, bottom: String, highlighted: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(highlighted ? palette.accent : palette.text)
            Text(String(top.prefix(16)))
                .font(.system(size: 10))
                .foregroundStyle(highlighted ? palette.accent : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(bottom)
                .font(.system(size: 9))
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(highlighted ? palette.selection : palette.panel,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(highlighted ? palette.accent.opacity(0.3) : palette.line, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 11))
            Text("Voice generated on this \(DeviceInfo.platformName)")
                .font(.system(size: 11))
        }
        .foregroundStyle(palette.muted)
        .padding(.top, 18)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(palette.accent)
            Text("Narration unavailable")
                .font(.system(.headline, design: .serif))
            Text(message)
                .font(.footnote)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
            Button("Close") {
                playback.errorMessage = nil
                playback.stopAndClose()
                dismiss()
            }
            .foregroundStyle(palette.accent)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(palette.panelRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.line, lineWidth: 1))
        .padding(24)
    }
}

// MARK: - Scrubber

struct NarrationScrubber: View {
    var index: Int
    var total: Int
    var onSeek: (Int) -> Void

    @Environment(\.nodusPalette) private var palette
    @State private var dragFraction: CGFloat?

    private var fraction: CGFloat {
        if let dragFraction { return dragFraction }
        guard total > 1 else { return 0 }
        return CGFloat(index) / CGFloat(total - 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumbSize: CGFloat = 16
            ZStack(alignment: .leading) {
                Capsule().fill(palette.text.opacity(0.12)).frame(height: 6)
                Capsule().fill(palette.accent)
                    .frame(width: max(0, width * fraction), height: 6)
                Circle()
                    .fill(palette.text)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: max(0, min(width - thumbSize, width * fraction - thumbSize / 2)))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = max(0, min(1, value.location.x / max(width, 1)))
                    }
                    .onEnded { value in
                        let value = max(0, min(1, value.location.x / max(width, 1)))
                        dragFraction = nil
                        onSeek(Int((value * CGFloat(max(total - 1, 0))).rounded()))
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Narration position")
        .accessibilityValue("Sentence \(index + 1) of \(total)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(index + 1, total - 1))
            case .decrement: onSeek(max(index - 1, 0))
            default: break
            }
        }
    }
}

// MARK: - Voice picker

struct VoicePickerSheet: View {
    @Environment(VoiceCatalog.self) private var voices
    @Environment(ModelManager.self) private var models
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    @State private var searchText = ""
    @State private var languageFilter: String?
    /// An installed model's ID; nil shows every model.
    @State private var modelFilter: String?
    @State private var didSetInitialLanguage = false

    /// The per-book voice syncs, but voices and models are installed per
    /// device (design/DESIGN.md §4). When it is missing here, say so and offer
    /// to install it instead of silently using another voice.
    private var bookVoiceIsMissing: Bool {
        playback.preferredVoiceIsMissing
    }

    /// Voices of every installed model, not only the selected engine's:
    /// choosing one from another model switches to it.
    private var allVoices: [VoiceCatalog.Voice] {
        voices.allInstalledVoices
    }

    private var installedModels: [ModelManager.Model] {
        models.models.filter { $0.isAvailable && models.isInstalled($0) }
    }

    private var modelLabel: String? {
        guard let modelFilter else { return nil }
        return installedModels.first { $0.id == modelFilter }?.name
    }

    private var filtered: [VoiceCatalog.Voice] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = VoiceCatalog.languageCode(languageFilter)
        return allVoices.filter { voice in
            if let language, !voice.language.lowercased().hasPrefix(language) { return false }
            if let modelFilter, voice.modelID != modelFilter { return false }
            guard !trimmed.isEmpty else { return true }
            return voice.name.localizedCaseInsensitiveContains(trimmed)
                || voice.languageName.localizedCaseInsensitiveContains(trimmed)
                || voice.engineLabel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var availableLanguages: [String] {
        VoiceCatalog.baseLanguages(of: allVoices)
    }

    /// One section per language; regional variants are shown on each row.
    private var groupedLanguages: [String] {
        VoiceCatalog.baseLanguages(of: filtered)
    }

    /// Model and language filters, as on the Voices screen.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                VoiceFilterMenu(title: String(localized: "Model"), systemImage: "cpu",
                                value: modelLabel, isActive: modelFilter != nil) {
                    Button("All models") { modelFilter = nil }
                    Divider()
                    ForEach(installedModels) { model in
                        Button(model.name) { modelFilter = model.id }
                    }
                }
                VoiceFilterMenu(title: String(localized: "Language"), systemImage: "globe",
                                value: languageFilter.map { voices.languageName(for: $0) },
                                isActive: languageFilter != nil) {
                    Button("All languages") { languageFilter = nil }
                    Divider()
                    ForEach(availableLanguages, id: \.self) { language in
                        Button(voices.languageName(for: language)) { languageFilter = language }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(palette.background)
    }

    var body: some View {
        NavigationStack {
            List {
                if bookVoiceIsMissing {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Book voice not installed")
                                .font(.system(.headline, design: .serif))
                            Text("This book uses a voice chosen on another device. \(playback.voiceLabel) reads it here until that voice is installed; voices and models are downloaded separately on each device.")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            NavigationLink {
                                VoicesView()
                                    .navigationTitle("Voices & Models")
                            } label: {
                                Label(String(localized: "Install voice"), systemImage: "arrow.down.circle")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(palette.panel)
                    }
                }
                if filtered.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No voices match")
                                .font(.system(.headline, design: .serif))
                            Text("No installed voice matches these filters. Show every voice, or download another model in Settings › Voices & Models.")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Show all voices") {
                                languageFilter = nil
                                modelFilter = nil
                                searchText = ""
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.accent)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(palette.panel)
                    }
                }

                ForEach(groupedLanguages, id: \.self) { language in
                    Section(voices.languageName(for: language)) {
                        ForEach(filtered.filter { VoiceCatalog.languageCode($0.language) == language }) { voice in
                            Button {
                                // A voice of a model that is not the voice
                                // engine makes that model the engine, so it
                                // really narrates instead of falling back.
                                if let modelID = voice.modelID, modelID != models.selectedModelID {
                                    models.selectModel(modelID)
                                }
                                playback.setVoice(voice)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(voice.name)
                                            .foregroundStyle(palette.text)
                                        Text("\(voice.engineLabel) · \(VoiceCatalog.variantName(for: voice.language)) · \(voice.qualityLabel)")
                                            .font(.caption)
                                            .foregroundStyle(palette.muted)
                                    }
                                    Spacer()
                                    if playback.activeVoiceID == voice.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(palette.panel)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                filterRow
            }
            .searchable(text: $searchText, prompt: "Search voices")
            .navigationTitle("Voice for this book")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !didSetInitialLanguage else { return }
                let bookLanguage = VoiceCatalog.languageCode(playback.activeBook?.language)
                let fallback = VoiceCatalog.languageCode(voices.defaultVoice?.language)
                if let code = bookLanguage ?? fallback,
                   allVoices.contains(where: { $0.language.lowercased().hasPrefix(code) }) {
                    languageFilter = code
                }
                didSetInitialLanguage = true
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }
}
