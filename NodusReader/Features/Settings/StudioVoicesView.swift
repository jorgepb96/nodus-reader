// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Studio, in Voices & Models: references the user records or adds from an audio
/// file for Qwen or Ming, plus the bundled one. They are listed as
/// Studio voices, can be renamed, and deleted after a confirmation.
struct StudioSection: View {
    /// Shows the Models tab, where the speech engines are installed.
    var onShowModels: () -> Void

    @Environment(ModelManager.self) private var models
    @Environment(VoiceCatalog.self) private var voices
    @Environment(\.nodusPalette) private var palette

    @State private var cloneMode: StudioVoiceCloneSheet.Mode?
    @State private var pendingDelete: StudioVoiceStore.ClonedVoice?
    @State private var renameTarget: StudioVoiceStore.ClonedVoice?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @State private var engine: ModelManager.Engine = .qwen

    private var installedEngines: [ModelManager.Engine] {
        models.models.filter { [.qwen, .ming].contains($0.engine) && models.isInstalled($0) }.map(\.engine)
    }

    private var references: [StudioVoiceStore.ClonedVoice] { models.studioReferences(for: engine) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record your voice reading a paragraph, or add 6 to 15 seconds of clear speech with its exact words. Use it to read books with Qwen, or with Ming on Mac. Everything stays on this device.")
                .font(.footnote)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !installedEngines.isEmpty {
                if installedEngines.count > 1 {
                    Picker("Voice engine", selection: $engine) {
                        ForEach(installedEngines, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                studioContent
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Install a model to create voices", systemImage: "waveform.badge.mic")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text("Install Qwen3-TTS in Models to record or add a voice. Ming also supports Studio voices on Mac.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show Models", action: onShowModels)
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(radius: 18)
            }

            Text("Clone only your own voice or one you have permission to use. Recordings stay on this device and are never synced.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .sheet(item: $cloneMode) { mode in
            StudioVoiceCloneSheet(mode: mode, engine: engine)
        }
        .onAppear { if !installedEngines.contains(engine), let first = installedEngines.first { engine = first } }
        .onChange(of: installedEngines) { _, available in
            if !available.contains(engine), let first = available.first { engine = first }
        }
        #if DEBUG
        .task {
            if let mode = UserDefaults.standard.string(forKey: "NodusShowMingClone").flatMap(StudioVoiceCloneSheet.Mode.init) {
                try? await Task.sleep(for: .seconds(1))
                cloneMode = mode
            }
        }
        #endif
        .confirmationDialog("Delete this voice?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { clone in
            Button("Delete \(clone.name)", role: .destructive) { models.deleteStudioVoice(clone) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its recording is deleted from this device for every voice engine. Books that use it read with their default voice.")
        }
        .alert("Rename Voice", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { clone in
            TextField("Name", text: $renameText)
            Button("Save") {
                do {
                    try models.renameStudioVoice(clone, to: renameText)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var studioContent: some View {
        Eyebrow("Studio voices")
            .padding(.top, 4)

        VStack(spacing: 0) {
            ForEach(references) { clone in
                row(clone)
                if clone.id != references.last?.id {
                    Divider().overlay(palette.line)
                }
            }
        }
        .panelCard(radius: 18)

        HStack(spacing: 10) {
            Button {
                cloneMode = .record
            } label: {
                Label("Record a voice…", systemImage: "mic")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            Button {
                cloneMode = .file
            } label: {
                Label("Add audio file…", systemImage: "waveform.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        }
        .buttonStyle(.bordered)
        .tint(palette.accent)

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(palette.destructive)
                .padding(.horizontal, 4)
        }
    }

    private func row(_ clone: StudioVoiceStore.ClonedVoice) -> some View {
        HStack(spacing: 12) {
            let id = engine == .qwen ? (clone.isBundled ? "qwen:es-ES" : QwenSpeech.clonePrefix + clone.id) : clone.voiceID
            let voice = voices.allInstalledVoices.first { $0.id == id }
            VoiceSampleButton(voice: voice, name: clone.name, diameter: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(clone.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.text)
                Text("\(VoiceCatalog.variantName(for: clone.language)) · \(Int(clone.durationS.rounded())) s · \(originLabel(clone))")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            Spacer()
            if !clone.isBundled {
                Button {
                    errorMessage = nil
                    renameText = clone.name
                    renameTarget = clone
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(palette.muted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename")
                .accessibilityLabel("Rename \(clone.name)")

                Button(role: .destructive) {
                    pendingDelete = clone
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(palette.muted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete")
                .accessibilityLabel("Delete \(clone.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contextMenu {
            if !clone.isBundled {
                Button {
                    errorMessage = nil
                    renameText = clone.name
                    renameTarget = clone
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = clone
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
        }
    }

    private func originLabel(_ clone: StudioVoiceStore.ClonedVoice) -> String {
        switch clone.origin {
        case .recorded: String(localized: "Recorded")
        case .imported: String(localized: "From a file")
        case .bundled: String(localized: "Included · CC0")
        }
    }
}

/// Records a paragraph or reads an audio file, suggests its transcript with
/// on-device speech recognition, and saves the voice once the user confirms
/// the words and their consent.
struct StudioVoiceCloneSheet: View {
    enum Mode: String, Identifiable {
        case record
        case file
        var id: String { rawValue }
    }

    let mode: Mode
    var engine: ModelManager.Engine = .qwen

    @Environment(ModelManager.self) private var models
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    @State private var name = ""
    @State private var language = StudioVoiceCloneSheet.defaultLanguage
    @State private var paragraphIndex = 0
    @State private var clip: StudioVoiceStore.PreparedClip?
    @State private var transcript = ""
    @State private var consent = false
    @State private var isTranscribing = false
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var recorder = StudioVoiceRecorder()
    @State private var preview: AVAudioPlayer?
    @State private var sourceURL: URL?
    @State private var sourceAccess = false
    @State private var sourceDuration = 0.0
    @State private var selectionStart = 0.0
    @State private var selectionDuration = 12.0
    @State private var isPreparingClip = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var selectionToken = UUID()
    @State private var editorClaim = UUID()
    private var maximumSeconds: Double { StudioVoiceStore.maximumSeconds(for: engine) }

    private var languages: [String] { engine == .qwen ? QwenSpeech.languages : StudioVoiceStore.languages }

    private static var defaultLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return StudioVoiceStore.languages.first { $0.hasPrefix(code) } ?? "en-US"
    }

    private var paragraphs: [String] { StudioVoiceStore.sampleParagraphs(for: language) }

    private var minimumCharacters: Int {
        StudioVoiceStore.minimumTranscriptCharacters(forDuration: clip?.durationS ?? StudioVoiceStore.minimumSeconds)
    }

    private var canSave: Bool {
        guard let clip, consent, !isTranscribing, !isPreparingClip, !recorder.isRecording else { return false }
        return clip.durationS >= StudioVoiceStore.minimumSeconds && clip.durationS <= maximumSeconds
            && transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumCharacters
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("My voice"))
                        .accessibilityIdentifier("StudioVoiceName")
                    Picker("Language", selection: $language) {
                        ForEach(languages, id: \.self) { tag in
                            Text(VoiceCatalog.variantName(for: tag)).tag(tag)
                        }
                    }
                }

                if mode == .record {
                    recordSection
                } else {
                    fileSection
                }

                if sourceURL != nil { selectionSection }

                if clip != nil {
                    transcriptSection
                }

                Section {
                    Toggle("This is my voice, or I have its owner's permission to clone it.", isOn: $consent)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(palette.destructive)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mode == .record ? "Record a voice" : "Add a voice")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Voice") { save() }
                        .disabled(!canSave)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { load(url) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 700)
        #endif
        .onAppear {
            playback.offlineAudio.setEditor(editorClaim, active: true)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NodusStudioTrimSample"),
               let url = Bundle.main.url(forResource: "es-dave", withExtension: "wav", subdirectory: "MingVoices")
                ?? Bundle.main.url(forResource: "es-dave", withExtension: "wav") { load(url) }
            #endif
        }
        .onChange(of: language) { _, _ in paragraphIndex = 0; if clip != nil { prepareSelection() } }
        .onChange(of: recorder.finishedURL) { _, url in
            guard let url else { return }
            recorder.finishedURL = nil
            load(url, recorded: true)
        }
        .onDisappear {
            recorder.cancel()
            preview?.stop()
            selectionToken = UUID()
            preparationTask?.cancel(); transcriptionTask?.cancel()
            if sourceAccess { sourceURL?.stopAccessingSecurityScopedResource() }
            playback.offlineAudio.setEditor(editorClaim, active: false)
            #if os(iOS)
            if AudioSessionCoordinator.shared.claims.isEmpty {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
        }
    }

    private var recordSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Read this aloud in a quiet room, at your usual pace:")
                    .font(.callout)
                    .foregroundStyle(palette.muted)
                Text(paragraphs[min(paragraphIndex, paragraphs.count - 1)])
                    .font(.system(.title3, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if paragraphs.count > 1 {
                    Button("Another paragraph") {
                        paragraphIndex = (paragraphIndex + 1) % paragraphs.count
                    }
                    .nodusTextButtonStyle()
                    .foregroundStyle(palette.accent)
                    .disabled(recorder.isRecording)
                }
            }
            HStack(spacing: 12) {
                Button {
                    toggleRecording()
                } label: {
                    Label(recorder.isRecording ? "Stop" : (clip == nil ? "Record" : "Record again"),
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? palette.destructive : palette.accent)
                if recorder.isRecording {
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                        .foregroundStyle(palette.muted)
                }
                Spacer()
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("6 to 15 seconds give the best result. Nodus Reader asks for the microphone the first time.")
            Text("Recording stops automatically after \(Int(maximumSeconds)) seconds.")
        }
    }

    private var fileSection: some View {
        Section {
            HStack {
                Button(clip == nil ? "Choose Audio File…" : "Choose Another File…") { showImporter = true }
                Spacer()
            }
            if let clip {
                Text("\(clip.durationS, format: .number.precision(.fractionLength(1))) s of speech after trimming silence")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
        } header: {
            Text("Audio file")
        } footer: {
            Text("Choose WAV, M4A, MP3 or AIFF, then select a short passage with one person speaking clearly, without music.")
        }
    }

    private var selectionSection: some View {
        Section("Voice sample") {
            Text("\(sourceDuration, format: .number.precision(.fractionLength(1))) s in the source · maximum \(Int(maximumSeconds)) s for \(engine.label)")
                .font(.caption).foregroundStyle(palette.muted)
            Slider(value: $selectionStart, in: 0...max(0.01, sourceDuration - StudioVoiceStore.minimumSeconds))
                .accessibilityLabel("Sample start")
            Stepper("Start: \(selectionStart, format: .number.precision(.fractionLength(1))) s", value: $selectionStart,
                    in: 0...max(0, sourceDuration - StudioVoiceStore.minimumSeconds), step: 0.5)
            Stepper("Length: \(selectionDuration, format: .number.precision(.fractionLength(1))) s", value: $selectionDuration,
                    in: StudioVoiceStore.minimumSeconds...max(StudioVoiceStore.minimumSeconds, min(maximumSeconds, sourceDuration - selectionStart)), step: 0.5)
            if isPreparingClip { ProgressView("Preparing selection…") }
            playButton
        }
        .onChange(of: selectionStart) { _, _ in
            selectionDuration = min(selectionDuration, max(StudioVoiceStore.minimumSeconds, sourceDuration - selectionStart))
            prepareSelection()
        }
        .onChange(of: selectionDuration) { _, _ in prepareSelection() }
    }

    private var transcriptSection: some View {
        Section {
            TextEditor(text: $transcript)
                .font(.body)
                .frame(minHeight: 90)
            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recognizing the words on this device…")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
        } header: {
            Text("Exact words spoken")
        } footer: {
            Text("The recording and its words must match exactly, including any slips. At least \(minimumCharacters) characters for this clip.")
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if clip != nil {
            Button {
                playPreview()
            } label: {
                Label("Listen / stop", systemImage: "play.fill")
            }
            .disabled(recorder.isRecording)
        }
    }

    // MARK: Actions

    private func toggleRecording() {
        errorMessage = nil
        if recorder.isRecording {
            guard let url = recorder.stop() else { return }
            load(url, recorded: true)
        } else {
            Task {
                do {
                    playback.pause()
                    playback.stopSample()
                    preview?.stop()
                    try await recorder.start(maximumSeconds: maximumSeconds)
                } catch is CancellationError {
                    return
                } catch {
                    recorder.cancel()
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func load(_ url: URL, recorded: Bool = false) {
        errorMessage = nil
        preview?.stop()
        selectionToken = UUID(); preparationTask?.cancel(); transcriptionTask?.cancel()
        if sourceAccess { sourceURL?.stopAccessingSecurityScopedResource() }
        sourceAccess = url.startAccessingSecurityScopedResource()
        sourceURL = url
        do {
            sourceDuration = try StudioVoiceStore.duration(url: url)
            guard sourceDuration >= StudioVoiceStore.minimumSeconds else { throw StudioVoiceStore.StoreError.tooShort }
            selectionStart = 0
            selectionDuration = min(recorded ? sourceDuration : 12, maximumSeconds, sourceDuration)
            if name.isEmpty, !recorded {
                name = url.deletingPathExtension().lastPathComponent
            }
            prepareSelection(prompt: recorded ? paragraphs[min(paragraphIndex, paragraphs.count - 1)] : nil)
        } catch {
            clip = nil
            if sourceAccess { url.stopAccessingSecurityScopedResource() }
            sourceAccess = false; sourceURL = nil; sourceDuration = 0; isPreparingClip = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func prepareSelection(prompt: String? = nil) {
        guard let sourceURL else { return }
        preview?.stop(); preparationTask?.cancel(); transcriptionTask?.cancel()
        let token = UUID(); selectionToken = token
        let start = selectionStart, duration = selectionDuration, limit = maximumSeconds
        clip = nil; transcript = ""; isTranscribing = false; isPreparingClip = true
        preparationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let work = Task.detached(priority: .userInitiated) {
                    try StudioVoiceStore.prepare(url: sourceURL, start: start, duration: duration, maximumSeconds: limit)
                }
                let prepared = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard token == selectionToken else { return }
                try StudioVoiceStore.validate(prepared)
                clip = prepared; isPreparingClip = false; errorMessage = nil
                if let prompt { transcript = prompt }
                else { transcribe(prepared) }
            } catch {
                guard token == selectionToken, !Task.isCancelled else { return }
                isPreparingClip = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func transcribe(_ prepared: StudioVoiceStore.PreparedClip) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-NodusSkipStudioTranscription") { return }
        #endif
        isTranscribing = true
        let language = language
        let token = selectionToken
        transcriptionTask = Task {
            let text = await StudioVoiceStore.transcribe(prepared, language: language)
            guard !Task.isCancelled, token == selectionToken else { return }
            isTranscribing = false
            if let text, transcript.isEmpty {
                transcript = text
            } else if text == nil {
                errorMessage = String(localized: "The words could not be recognized automatically. Type them, exactly as spoken.")
            }
        }
    }

    private func playPreview() {
        guard let clip else { return }
        if preview?.isPlaying == true { preview?.stop(); return }
        #if os(iOS)
        playback.pause()
        playback.stopSample()
        try? AudioSessionCoordinator.apply(.spokenAudio, to: AVAudioSession.sharedInstance())
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodus-studio-preview-\(editorClaim).wav")
        try? StudioVoiceStore.writeWAV(clip.samples, to: url)
        preview = try? AVAudioPlayer(contentsOf: url)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-NodusSilentAudioTests") { preview?.volume = 0 }
        #endif
        preview?.play()
    }

    private func save() {
        guard let clip else { return }
        do {
            try models.addStudioVoice(clip, name: name, language: language, transcript: transcript,
                                    origin: mode == .record ? .recorded : .imported, consent: consent)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Records the reference clip: mono 44.1 kHz PCM to a temporary file.
@MainActor
@Observable
final class StudioVoiceRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                String(localized: "Nodus Reader cannot use the microphone. Allow microphone access in Settings.")
            case .couldNotStart:
                String(localized: "The recording could not start. Check that a microphone is connected.")
            }
        }
    }

    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    /// Set when the recording stopped itself at the longest accepted length.
    var finishedURL: URL?
    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var permissionRequest = UUID()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodus-ming-recording.wav")

    func start(maximumSeconds: Double = StudioVoiceStore.maximumSeconds) async throws {
        let request = UUID()
        permissionRequest = request
        #if os(iOS)
        let granted = await AVAudioApplication.requestRecordPermission()
        #else
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard request == permissionRequest else { throw CancellationError() }
        guard granted else { throw RecorderError.microphoneDenied }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: StudioVoiceStore.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
            throw RecorderError.couldNotStart
        }
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                // Past the longest clip Ming accepts, stop on the user's behalf.
                if recorder.currentTime >= maximumSeconds { self.finishedURL = self.stop() }
            }
        }
    }

    /// Stops and returns the recorded file.
    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        #if os(iOS)
        if let configuration = AudioSessionCoordinator.shared.configuration {
            try? AudioSessionCoordinator.apply(configuration, to: AVAudioSession.sharedInstance())
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        timer?.cancel()
        timer = nil
        isRecording = false
        return url
    }

    func cancel() {
        permissionRequest = UUID()
        _ = stop()
        #if os(iOS)
        if let configuration = AudioSessionCoordinator.shared.configuration {
            try? AudioSessionCoordinator.apply(configuration, to: AVAudioSession.sharedInstance())
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        try? FileManager.default.removeItem(at: url)
    }
}
