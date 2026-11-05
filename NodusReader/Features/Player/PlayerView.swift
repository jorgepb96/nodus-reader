// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct PlayerView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(ModelManager.self) private var models
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.dismiss) private var dismiss

    var onOpenReader: (Book) -> Void
    var onClose: (() -> Void)? = nil
    var availableHeight: CGFloat = 600

    @State private var viewport = CGSize(width: 390, height: 700)
    @State private var macContentHeight: CGFloat = 540
    @State private var showVoicePicker = false
    @State private var showPronunciations = false
    @State private var showAudioJobs = false

    /// The app theme's palette, or the reader theme's when the player is
    /// opened from the reader: the player matches the screen it covers.
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        ScrollView {
            #if os(macOS)
            macContent
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { macContentHeight = $0 }
            #else
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
                if viewport.height < 600 && viewport.width < 600 {
                    DisclosureGroup("More playback options") {
                        ImmersiveAudioCard().padding(.top, 12)
                        audioCacheCard
                        footer
                    }
                    .font(.footnote)
                    .padding(.top, 12)
                } else if viewport.width >= 600 {
                    if immersive.preferences.isEnabled {
                        HStack(alignment: .top, spacing: 12) {
                            ImmersiveAudioCard().frame(maxWidth: .infinity).padding(.top, 12)
                            audioCacheCard.frame(maxWidth: .infinity)
                        }
                    } else {
                        audioCacheCard
                    }
                    footer
                } else {
                    ImmersiveAudioCard().padding(.top, 16)
                    audioCacheCard
                    footer
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            #endif
        }
        #if os(macOS)
        .frame(height: min(macContentHeight, max(0, availableHeight)))
        #endif
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .scrollIndicators(.hidden)
        .foregroundStyle(palette.text)
        .background(playerBackground)
        .nodusPalette(palette)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .sheet(isPresented: $showPronunciations) {
            if let book = playback.activeBook { PronunciationView(book: book) }
        }
        .sheet(isPresented: $showAudioJobs) { OfflineNarrationView().nodusPalette(palette) }
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
        .task {
            await playback.refreshAudioCacheSize()
            #if os(macOS) && DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NodusOpenVoicePicker") {
                try? await Task.sleep(for: .seconds(2))
                showVoicePicker = true
            }
            #endif
        }
        #if os(iOS)
        // A form sheet on iPad is only 640 pt tall, which pushed the whole
        // speed/voice/sleep/mode row below the transport and forced a scroll
        // before the listener could change the speed. The page presentation
        // keeps the primary controls visible, with the same sheet on iPhone.
        .presentationSizing(.page)
        #endif
    }

    #if os(macOS)
    private var macContent: some View {
        VStack(spacing: 0) {
            topBar
            if viewport.width >= 680 {
                HStack(alignment: .top, spacing: 16) {
                    macPlaybackControls
                        .frame(maxWidth: .infinity)
                    macAdditionalControls
                        .frame(width: 280)
                }
            } else {
                macPlaybackControls
                macAdditionalControls.padding(.top, 12)
            }
        }
        .padding(16)
    }

    private var macPlaybackControls: some View {
        VStack(spacing: 0) {
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
        }
    }

    private var macAdditionalControls: some View {
        VStack(spacing: 0) {
            if immersive.preferences.isEnabled { ImmersiveAudioCard() }
            audioCacheCard
            footer
        }
    }
    #endif

    private func closePlayer() {
        if let onClose { onClose() }
        else { dismiss() }
    }

    private var audioCacheCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Audio generation…") { showAudioJobs = true }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accent)
                .nodusTextButtonStyle().accessibilityIdentifier("OpenOfflineAudioJobs")
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
                    Text(playback.currentAudioJob?.state.status == .generating ? "Generating audio…" :
                         playback.currentAudioJob?.state.status == .caughtUp ? "Window ready · follows your reading" : "Queued · resumes when voice engines are free")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                    Spacer()
                    Button("Pause") { playback.cancelAudioCacheGeneration() }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .nodusTextButtonStyle()
                }
            } else {
                HStack(spacing: 16) {
                    Button("Generate for this book") {
                        playback.generateAudioCacheForCurrentBook()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(playback.isNeuralVoice ? palette.accent : palette.muted)
                    .disabled(!playback.isNeuralVoice)
                    .nodusTextButtonStyle()

                    if playback.audioCacheBytes > 0 {
                        Button("Delete cache") {
                            Task { await playback.deleteAudioCacheForCurrentBook() }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .nodusTextButtonStyle()
                    }
                    Spacer()
                }
                if !playback.isNeuralVoice {
                    Text("Choose a voice to generate offline audio.")
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
                closePlayer()
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
                if playback.activeBook != nil {
                    Button("Pronunciations…") { showPronunciations = true }
                }
                Button {
                    playback.stopAndClose()
                    closePlayer()
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
            .nodusMenuLabelStyle()
            .fixedSize()
            .accessibilityLabel("Player options")
        }
        .padding(.bottom, 8)
    }

    private var compactPlayer: Bool {
        #if os(macOS)
        true
        #else
        viewport.height < 720
        #endif
    }

    private var cover: some View {
        Group {
            if let book = playback.activeBook { BookCoverView(book: book, showBadges: false) }
            else { RoundedRectangle(cornerRadius: 10).fill(palette.panel) }
        }
        .frame(width: compactPlayer ? (viewport.width >= 600 ? 96 : 64) : 108,
               height: compactPlayer ? (viewport.width >= 600 ? 144 : 96) : 162)
        .accessibilityHidden(true)
    }

    private var bookIdentity: some View {
        VStack(spacing: 4) {
            Text(playback.activeBook?.title ?? String(localized: "Nothing playing"))
                .font(.system(size: compactPlayer ? 21 : 25, design: .serif))
                .foregroundStyle(palette.text)
                .lineLimit(2)
            Text("\(playback.activeBook?.displayAuthor ?? "") · \(playback.chapterTitle)")
                .font(.caption).foregroundStyle(palette.muted).lineLimit(1)
            if compactPlayer { contextText.padding(.top, 4) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var coverAndText: some View {
        VStack(spacing: 10) {
            if compactPlayer {
                HStack(spacing: 16) { cover; bookIdentity }
            } else {
                cover
                bookIdentity
                contextText
            }
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
        current.font = .system(size: compactPlayer ? 14 : 17, design: .serif).weight(.medium)
        attributed.append(current)
        if let next = playback.nextSentenceText {
            var part = AttributedString(" \(next.prefix(48))…")
            part.foregroundColor = palette.muted
            attributed.append(part)
        }
        return Text(attributed)
            .font(.system(size: compactPlayer ? 14 : 17, design: .serif))
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .lineLimit(compactPlayer ? 2 : 3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        let position = playback.sentenceIndexInChapter
        let count = max(playback.sentenceCountInChapter, 1)
        let start = max(0, playback.currentIndex - position)
        let bookID = playback.activeBook?.id
        let chapter = playback.chapterIndex
        return VStack(spacing: 8) {
            NarrationScrubber(
                index: playback.currentIndex,
                bounds: start..<(start + count)
            ) { value in
                guard playback.activeBook?.id == bookID, playback.chapterIndex == chapter else { return }
                playback.seek(to: value)
            }
            .disabled(playback.isLoading || count <= 1)
            HStack {
                Text("Sentence \(position + 1) of \(count)")
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
            : String(localized: "Generating the next sentence…")
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
                Image(systemName: playback.playbackActionSymbol)
                    .font(.system(size: 27, weight: .semibold))
                    .offset(x: playback.isPlaying || playback.narrationFinished ? 0 : 2)
                    .foregroundStyle(palette.onAccent)
                    .frame(width: compactPlayer ? 60 : 72, height: compactPlayer ? 60 : 72)
                    .background(palette.accent, in: Circle())
                    .overlay {
                        if playback.isLoading {
                            LoadingRing(color: palette.onAccent, lineWidth: 3.5).padding(5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.narrationFinished ? "Replay from beginning" : playback.isPlaying ? "Pause" : "Play")
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: viewport.width < 500 ? 3 : 5), spacing: 8) {
            speedControl
            voiceControl
            sleepControl
            returnToNarrationControl
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
        // A menu tile has the same size and look as the button tiles; the
        // Mac's pop-up bezel would otherwise draw around it.
        .nodusMenuLabelStyle()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(playback.speedLabel)
    }

    private var voiceControl: some View {
        Button {
            showVoicePicker = true
        } label: {
            controlTile(top: playback.activeVoice?.name ?? String(localized: "Voice"),
                        bottom: playback.preferredVoiceIsMissing ? String(localized: "Replacement voice") : playback.engineLabel,
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
        // A menu tile has the same size and look as the button tiles; the
        // Mac's pop-up bezel would otherwise draw around it.
        .nodusMenuLabelStyle()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Sleep timer")
        .accessibilityIdentifier("PlayerSleepTimer")
    }

    private var returnToNarrationControl: some View {
        Button {
            guard let book = playback.activeBook else { return }
            playback.requestReaderResume()
            onOpenReader(book)
            closePlayer()
        } label: {
            controlTile(icon: "location.fill", top: String(localized: "Return"),
                        bottom: String(localized: "To narration"), highlighted: false)
        }
        .buttonStyle(.plain)
        .disabled(playback.currentChapterOffset == nil)
        .accessibilityLabel("Return to narration")
        .accessibilityIdentifier("PlayerReturnToNarration")
    }

    private var modeControl: some View {
        Menu {
            ForEach(ReadingMode.allCases) { mode in
                Button {
                    playback.setMode(mode)
                    if mode != .listen, let book = playback.activeBook {
                        playback.requestReaderResume()
                        onOpenReader(book)
                        closePlayer()
                    }
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
        // A menu tile has the same size and look as the button tiles; the
        // Mac's pop-up bezel would otherwise draw around it.
        .nodusMenuLabelStyle()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Reading mode")
        .accessibilityIdentifier("PlayerReadingMode")
    }

    private func controlTile(top: String, bottom: String, highlighted: Bool) -> some View {
        VStack(spacing: 3) {
            Text(top)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(highlighted ? palette.accent : palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(bottom)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: viewport.width >= 600 ? 76 : 62)
        .background(highlighted ? palette.selection : palette.panel,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(highlighted ? palette.accent.opacity(0.3) : palette.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .font(.system(size: 9))
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: viewport.width >= 600 ? 76 : 62)
        .background(highlighted ? palette.selection : palette.panel,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(highlighted ? palette.accent.opacity(0.3) : palette.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            Button("Try again") {
                playback.errorMessage = nil
                playback.resume()
            }.nodusTextButtonStyle()
            Button("Choose another voice") {
                playback.errorMessage = nil
                showVoicePicker = true
            }.nodusTextButtonStyle()
            Button("Close") {
                playback.errorMessage = nil
                playback.stopAndClose()
                closePlayer()
            }
            .foregroundStyle(palette.accent)
            .nodusTextButtonStyle()
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
    var bounds: Range<Int>
    var onSeek: (Int) -> Void

    @Environment(\.nodusPalette) private var palette
    @State private var dragFraction: CGFloat?
    @State private var dragOrigin: (index: Int, bounds: Range<Int>)?
    @GestureState private var isDragging = false

    private var fraction: CGFloat {
        if let dragFraction { return dragFraction }
        return fraction(for: index, in: bounds)
    }

    private func fraction(for index: Int, in bounds: Range<Int>) -> CGFloat {
        guard bounds.count > 1 else { return 0 }
        return max(0, min(1, CGFloat(index - bounds.lowerBound) / CGFloat(bounds.count - 1)))
    }

    private func draggedFraction(translation: CGFloat, width: CGFloat,
                                 origin: (index: Int, bounds: Range<Int>)) -> CGFloat {
        max(0, min(1, fraction(for: origin.index, in: origin.bounds) + translation / max(width, 1)))
    }

    private func resetDrag() {
        dragFraction = nil
        dragOrigin = nil
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
                DragGesture(minimumDistance: 10)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        if dragOrigin == nil {
                            let thumbCenter = max(thumbSize / 2, min(width - thumbSize / 2, width * fraction))
                            // Only an intentional horizontal drag beginning
                            // near the handle can seek. Taps on the track and
                            // vertical scrolling leave playback untouched.
                            guard abs(value.startLocation.x - thumbCenter) <= 22,
                                  abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragOrigin = (index, bounds)
                        }
                        guard let origin = dragOrigin, origin.bounds == bounds else { return }
                        dragFraction = draggedFraction(translation: value.translation.width, width: width, origin: origin)
                    }
                    .onEnded { value in
                        defer { resetDrag() }
                        guard let origin = dragOrigin, origin.bounds == bounds,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        let fraction = draggedFraction(translation: value.translation.width, width: width, origin: origin)
                        let target = bounds.lowerBound + Int((fraction * CGFloat(max(bounds.count - 1, 0))).rounded())
                        if target != index { onSeek(target) }
                    }
            )
        }
        .frame(height: 22)
        // Retain the old drag bounds until the gesture ends, so a chapter
        // change cancels the seek instead of retargeting the new chapter.
        .onChange(of: bounds) { _, _ in dragFraction = nil }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { resetDrag() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position in chapter")
        .accessibilityHint("Drag the handle to move within this chapter.")
        .accessibilityValue("Sentence \(index - bounds.lowerBound + 1) of \(bounds.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if index + 1 < bounds.upperBound { onSeek(index + 1) }
            case .decrement:
                if index > bounds.lowerBound { onSeek(index - 1) }
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
    @AppStorage(VoiceFilterSelection.storageKey) private var savedVoiceFilters = ""
    @State private var automaticFilters = VoiceFilterSelection()
    @State private var didInitializeFilters = false

    private var filters: VoiceFilterSelection {
        VoiceFilterSelection.decode(savedVoiceFilters) ?? automaticFilters
    }

    private var filterBinding: Binding<VoiceFilterSelection> {
        Binding(get: { filters }, set: { value in
            if let encoded = value.encoded { savedVoiceFilters = encoded }
        })
    }

    /// The per-book voice syncs, but voices and models are installed per
    /// device (design/DESIGN.md §4). When it is missing here, say so and offer
    /// to install it instead of silently using another voice.
    private var bookVoiceIsMissing: Bool {
        playback.preferredVoiceIsMissing
    }

    /// Voices of every installed model, not only the selected engine's:
    /// choosing one stores that model and voice for this book.
    private var allVoices: [VoiceCatalog.Voice] {
        voices.allInstalledVoices
    }

    private var installedModels: [ModelManager.Model] {
        models.models.filter { $0.isAvailable && models.isInstalled($0) }
    }

    private var filtered: [VoiceCatalog.Voice] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allVoices.filter { voice in
            guard filters.matches(voice) else { return false }
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

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceFilterControls(selection: filterBinding,
                                modelOptions: modelOptions,
                                languageOptions: languageOptions,
                                genderOptions: genderOptions)
            if filters.isActive {
                Button {
                    filterBinding.wrappedValue = VoiceFilterSelection()
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .padding(.vertical, 6)
                }
                .nodusTextButtonStyle()
                .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background)
    }

    private var modelOptions: [VoiceFilterOption] {
        let ids = Set(installedModels.map(\.id)).union(filters.models)
        return ids.map { id in
            VoiceFilterOption(id: id, title: models.models.first { $0.id == id && $0.engine.isEnabled }?.name
                              ?? String(localized: "Unavailable model"))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var languageOptions: [VoiceFilterOption] {
        Set(availableLanguages).union(filters.languages).map {
            VoiceFilterOption(id: $0, title: voices.languageName(for: $0))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var genderOptions: [VoiceFilterOption] {
        VoiceGender.allCases.map { VoiceFilterOption(id: $0.rawValue, title: $0.label) }
            + [VoiceFilterOption(id: VoiceFilterSelection.unspecifiedGender, title: String(localized: "Not specified"))]
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
                                Label(String(localized: "Replacement voice"), systemImage: "arrow.down.circle")
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
                                filterBinding.wrappedValue = VoiceFilterSelection()
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
                                // Synthesis loads the model identified by this
                                // voice without changing the global default.
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
                await voices.loadIfNeeded()
                guard !Task.isCancelled, !didInitializeFilters else { return }
                let currentVoice = playback.activeVoice ?? voices.defaultVoice
                let language = VoiceCatalog.languageCode(playback.activeBook?.language)
                    ?? VoiceCatalog.languageCode(currentVoice?.language)
                let model = currentVoice?.modelID ?? models.selectedModel?.id ?? installedModels.first?.id
                automaticFilters = VoiceFilterSelection(
                    models: model.map { Set([$0]) } ?? [],
                    languages: language.map { Set([$0]) } ?? []
                )
                didInitializeFilters = true
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        // A Mac sheet takes its content's size: without one the list and its
        // filters were squeezed into a sliver.
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 680)
        #endif
    }
}
