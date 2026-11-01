// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import AVFoundation
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Studio, in Voices & Models: voices the user records or adds from an audio
/// file for Ming, plus the bundled one. They are listed with Ming's voices as
/// Studio voices, can be renamed, and deleted after a confirmation.
struct StudioSection: View {
    /// Shows the Models tab, where Ming is installed.
    var onShowModels: () -> Void

    @Environment(ModelManager.self) private var models
    @Environment(VoiceCatalog.self) private var voices
    @Environment(\.nodusPalette) private var palette

    @State private var cloneMode: MingVoiceCloneSheet.Mode?
    @State private var pendingDelete: MingVoiceStore.ClonedVoice?
    @State private var renameTarget: MingVoiceStore.ClonedVoice?
    @State private var renameText = ""
    @State private var errorMessage: String?

    private var mingInstalled: Bool {
        models.models.first { $0.engine == .ming }.map(models.isInstalled) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record your voice reading a paragraph, or add a recording of 6 to 15 seconds (WAV, MP3, M4A, AIFF, FLAC or CAF) with its exact words. Ming 3.0 reads books with it, and it appears with Ming's voices as a Studio voice.")
                .font(.footnote)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if mingInstalled {
                studioContent
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Studio needs Ming 3.0", systemImage: "waveform.badge.mic")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text("Studio voices are read by Ming 3.0 0.5B. Install it in Models to record or add a voice.")
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

            Text("Clone only your own voice or one you have permission to use. Recordings stay on this Mac and are never synced.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .sheet(item: $cloneMode) { mode in
            MingVoiceCloneSheet(mode: mode)
        }
        #if DEBUG
        .task {
            if let mode = UserDefaults.standard.string(forKey: "NodusShowMingClone").flatMap(MingVoiceCloneSheet.Mode.init) {
                try? await Task.sleep(for: .seconds(1))
                cloneMode = mode
            }
        }
        #endif
        .confirmationDialog("Delete this voice?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { clone in
            Button("Delete \(clone.name)", role: .destructive) { models.deleteMingVoice(clone) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its recording is deleted from this Mac. Books that use it read with their default voice.")
        }
        .alert("Rename Voice", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { clone in
            TextField("Name", text: $renameText)
            Button("Save") {
                do {
                    try models.renameMingVoice(clone, to: renameText)
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
            ForEach(models.mingClones) { clone in
                row(clone)
                if clone.id != models.mingClones.last?.id {
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

    private func row(_ clone: MingVoiceStore.ClonedVoice) -> some View {
        HStack(spacing: 12) {
            let voice = voices.allInstalledVoices.first { $0.id == clone.voiceID }
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

    private func originLabel(_ clone: MingVoiceStore.ClonedVoice) -> String {
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
struct MingVoiceCloneSheet: View {
    enum Mode: String, Identifiable {
        case record
        case file
        var id: String { rawValue }
    }

    let mode: Mode

    @Environment(ModelManager.self) private var models
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    @State private var name = ""
    @State private var language = MingVoiceCloneSheet.defaultLanguage
    @State private var paragraphIndex = 0
    @State private var clip: MingVoiceStore.PreparedClip?
    @State private var transcript = ""
    @State private var consent = false
    @State private var isTranscribing = false
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var recorder = MingVoiceRecorder()
    @State private var preview: AVAudioPlayer?

    private static var defaultLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return MingVoiceStore.languages.first { $0.hasPrefix(code) } ?? "en-US"
    }

    private var paragraphs: [String] { MingVoiceStore.sampleParagraphs(for: language) }

    private var minimumCharacters: Int {
        MingVoiceStore.minimumTranscriptCharacters(forDuration: clip?.durationS ?? MingVoiceStore.minimumSeconds)
    }

    private var canSave: Bool {
        guard let clip, consent, !isTranscribing, !recorder.isRecording else { return false }
        return clip.durationS >= MingVoiceStore.minimumSeconds && clip.durationS <= MingVoiceStore.maximumSeconds
            && transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumCharacters
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("My voice"))
                    Picker("Language", selection: $language) {
                        ForEach(MingVoiceStore.languages, id: \.self) { tag in
                            Text(VoiceCatalog.variantName(for: tag)).tag(tag)
                        }
                    }
                }

                if mode == .record {
                    recordSection
                } else {
                    fileSection
                }

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
            .navigationTitle(mode == .record ? "Record a voice" : "Add a voice from a file")
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
        .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 700)
        .onChange(of: language) { _, _ in paragraphIndex = 0 }
        .onChange(of: recorder.finishedURL) { _, url in
            guard let url else { return }
            recorder.finishedURL = nil
            load(url, recorded: true)
        }
        .onDisappear { recorder.cancel() }
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
                playButton
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("6 to 15 seconds give the best result. Nodus Reader asks for the microphone the first time.")
        }
    }

    private var fileSection: some View {
        Section {
            HStack {
                Button(clip == nil ? "Choose Audio File…" : "Choose Another File…") { showImporter = true }
                Spacer()
                playButton
            }
            if let clip {
                Text("\(clip.durationS, format: .number.precision(.fractionLength(1))) s of speech after trimming silence")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
        } header: {
            Text("Audio file")
        } footer: {
            Text("WAV, M4A, MP3 or AIFF with one person speaking clearly, without music. 6 to 15 seconds give the best result; up to 30 are accepted.")
        }
    }

    private var transcriptSection: some View {
        Section {
            TextEditor(text: $transcript)
                .font(.body)
                .frame(minHeight: 90)
            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recognizing the words on this Mac…")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
        } header: {
            Text("Exact words spoken")
        } footer: {
            Text("Ming reads the clip together with these words, so they must match what is said, including any slips. At least \(minimumCharacters) characters for this clip.")
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if clip != nil {
            Button {
                playPreview()
            } label: {
                Label("Listen", systemImage: "play.fill")
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
                    try await recorder.start()
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func load(_ url: URL, recorded: Bool = false) {
        errorMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try MingVoiceStore.prepare(url: url)
            try MingVoiceStore.validate(prepared)
            clip = prepared
            if name.isEmpty, !recorded {
                name = url.deletingPathExtension().lastPathComponent
            }
            if recorded {
                // The words read are the paragraph; the user fixes any slip.
                transcript = paragraphs[min(paragraphIndex, paragraphs.count - 1)]
            } else {
                transcript = ""
                transcribe(prepared)
            }
        } catch {
            clip = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func transcribe(_ prepared: MingVoiceStore.PreparedClip) {
        isTranscribing = true
        let language = language
        Task {
            let text = await MingVoiceStore.transcribe(prepared, language: language)
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodus-ming-preview.wav")
        try? MingVoiceStore.writeWAV(clip.samples, to: url)
        preview = try? AVAudioPlayer(contentsOf: url)
        preview?.play()
    }

    private func save() {
        guard let clip else { return }
        do {
            try models.addMingVoice(clip, name: name, language: language, transcript: transcript,
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
final class MingVoiceRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                String(localized: "Nodus Reader cannot use the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
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
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodus-ming-recording.wav")

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw RecorderError.microphoneDenied }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MingVoiceStore.sampleRate,
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
                if recorder.currentTime >= MingVoiceStore.maximumSeconds { self.finishedURL = self.stop() }
            }
        }
    }

    /// Stops and returns the recorded file.
    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        timer?.cancel()
        timer = nil
        isRecording = false
        return url
    }

    func cancel() {
        _ = stop()
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
