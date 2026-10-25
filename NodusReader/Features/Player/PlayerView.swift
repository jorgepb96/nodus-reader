// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct PlayerView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss

    @State private var showVoicePicker = false

    /// The player keeps its cinematic dark chrome regardless of the app theme,
    /// matching design/screens/iPhone-NowPlaying.png.
    private let palette = NodusPalette.dark

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                handle
                topBar
                coverAndText
                scrubber
                transport
                controlGrid
                audioCacheCard
                footer
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(playerBackground)
        .nodusPalette(palette)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerSheet()
                .nodusPalette(palette)
                .preferredColorScheme(.dark)
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
                    Text("Generating every sentence with \(playback.activeVoice?.name ?? "this voice")…")
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
                    Text("Choose a Kokoro or Phonon voice to generate offline audio. System voices never write audio files.")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x1A1724), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.line, lineWidth: 1)
        )
        .padding(.top, 12)
    }

    private var playerBackground: some View {
        LinearGradient(colors: [Color(hex: 0x16131F), Color(hex: 0x110F18)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var handle: some View {
        Capsule()
            .fill(Color.white.opacity(0.25))
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
                Text(playback.activeBook?.title ?? "Nothing playing")
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
        case .listen: playback.isPlaying ? "LISTENING" : "LISTEN"
        case .readAndListen: "READ & LISTEN"
        case .read: "READING"
        }
    }

    private var contextText: some View {
        var attributed = AttributedString()
        if let previous = playback.previousSentenceText {
            var part = AttributedString("…\(previous.suffix(48)) ")
            part.foregroundColor = Color(hex: 0x7F7A8C)
            attributed.append(part)
        }
        var current = AttributedString(playback.currentSentence)
        current.foregroundColor = Color(hex: 0xF2EFE8)
        current.font = .system(size: 17, design: .serif).weight(.medium)
        attributed.append(current)
        if let next = playback.nextSentenceText {
            var part = AttributedString(" \(next.prefix(48))…")
            part.foregroundColor = Color(hex: 0x7F7A8C)
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

    private var transport: some View {
        HStack {
            transportButton("backward.end", label: "Previous chapter") { playback.previousChapter() }
                .frame(maxWidth: .infinity)
            transportButton("gobackward", label: "Previous sentence") { playback.previousSentence() }
                .frame(maxWidth: .infinity)
            Button {
                playback.toggle()
            } label: {
                Group {
                    if playback.isLoading {
                        ProgressView().tint(palette.onAccent)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .offset(x: playback.isPlaying ? 0 : 2)
                    }
                }
                .foregroundStyle(palette.onAccent)
                .frame(width: 76, height: 76)
                .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
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
                    Label(String(format: "%.2g×", speed),
                          systemImage: playback.speedMultiplier == speed ? "checkmark" : "circle")
                }
            }
        } label: {
            controlTile(top: playback.speedLabel, bottom: "Speed", highlighted: false)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Playback speed")
    }

    private var voiceControl: some View {
        Button {
            showVoicePicker = true
        } label: {
            controlTile(top: playback.activeVoice?.name ?? "Voice", bottom: playback.engineLabel, highlighted: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice for this book")
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
                bottom: "Sleep",
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
                bottom: "Mode",
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
        .background(highlighted ? palette.selection : Color(hex: 0x1A1724),
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
        .background(highlighted ? palette.selection : Color(hex: 0x1A1724),
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
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 6)
                Capsule().fill(palette.accent)
                    .frame(width: max(0, width * fraction), height: 6)
                Circle()
                    .fill(Color(hex: 0xF2EFE8))
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
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    @State private var searchText = ""
    @State private var languageFilter: String?
    @State private var didSetInitialLanguage = false

    private var filtered: [VoiceCatalog.Voice] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = VoiceCatalog.languageCode(languageFilter)
        return voices.voices.filter { voice in
            if let language, !voice.language.lowercased().hasPrefix(language) { return false }
            guard !trimmed.isEmpty else { return true }
            return voice.name.localizedCaseInsensitiveContains(trimmed)
                || voice.languageName.localizedCaseInsensitiveContains(trimmed)
                || voice.engineLabel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var availableLanguages: [String] {
        Array(Set(voices.voices.map(\.language))).sorted {
            voices.languageName(for: $0).localizedStandardCompare(voices.languageName(for: $1)) == .orderedAscending
        }
    }

    private var languageLabel: String {
        languageFilter.map { voices.languageName(for: $0) } ?? "All languages"
    }

    private var groupedLanguages: [String] {
        Array(Set(filtered.map(\.language))).sorted {
            voices.languageName(for: $0).localizedStandardCompare(voices.languageName(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No voices in this language")
                                .font(.system(.headline, design: .serif))
                            Text("The selected engine has no installed voice for \(languageLabel). Search all languages or choose another model in Settings.")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Show all languages") { languageFilter = nil }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(palette.accent)
                        }
                        .padding(.vertical, 6)
                    }
                }

                ForEach(groupedLanguages, id: \.self) { language in
                    Section(voices.languageName(for: language)) {
                        ForEach(filtered.filter { $0.language == language }) { voice in
                            Button {
                                playback.setVoice(voice)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(voice.name)
                                            .foregroundStyle(palette.text)
                                        Text("\(voice.engineLabel) · \(voice.qualityLabel)")
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
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search voices")
            .navigationTitle("Voice for this book")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button("All languages") { languageFilter = nil }
                        Divider()
                        ForEach(availableLanguages, id: \.self) { language in
                            Button(voices.languageName(for: language)) { languageFilter = language }
                        }
                    } label: {
                        Label(languageLabel, systemImage: "globe")
                            .font(.footnote)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !didSetInitialLanguage else { return }
                let bookLanguage = VoiceCatalog.languageCode(playback.activeBook?.language)
                let fallback = VoiceCatalog.languageCode(voices.defaultVoice?.language)
                if let code = bookLanguage ?? fallback,
                   voices.voices.contains(where: { $0.language.lowercased().hasPrefix(code) }) {
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
