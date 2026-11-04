// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct OfflineNarrationView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(VoiceCatalog.self) private var voices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette
    @State private var bookID: UUID?
    @State private var voiceID = ""
    @State private var paragraphs = 10
    @State private var progressive = true
    @State private var ahead = 2
    @State private var isAdding = false
    @State private var error: String?
    @State private var deletion: Deletion?
    private struct Deletion { let jobID: UUID; var unit: OfflineNarrationPlan.Unit? }
    private var books: [Book] { library.allBooks().filter { $0.downloadState == .downloaded }.sorted { $0.title < $1.title } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Prepare a whole book, or keep a few chapters ready as you read. Documents without chapters use paragraph groups. Sentences stay whole, and saved audio stays on this device.")
                    Text("Narration and voice previews take priority. On iPhone and iPad, keep Nodus open for long jobs; if iOS suspends it, generation resumes when you return.")
                }.font(.footnote).foregroundStyle(palette.muted)
                Section("Add a book") {
                    Picker("Book", selection: $bookID) {
                        Text("Choose a book").tag(Optional<UUID>.none)
                        ForEach(books) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Picker("Voice", selection: $voiceID) {
                        Text("Choose a voice").tag("")
                        ForEach(voices.allInstalledVoices) { Text("\($0.name) · \($0.engineLabel) · \($0.languageName)").tag($0.id) }
                    }
                    Toggle("Follow my reading", isOn: $progressive).accessibilityIdentifier("ProgressiveOfflineAudio")
                    if progressive { Stepper("Chapters or parts ready: \(ahead)", value: $ahead, in: 1...1000) }
                    Text("Includes the current chapter or part. The next one is added when you advance.").font(.caption)
                    Stepper("Paragraphs per part: \(paragraphs)", value: $paragraphs, in: 1...50)
                    Text("Used only for documents without chapters.").font(.caption)
                    Button("Add to audio queue") { addBook() }
                        .disabled(bookID == nil || voices.voice(withID: voiceID) == nil || isAdding)
                        .accessibilityIdentifier("AddOfflineAudioJob")
                    if isAdding { ProgressView() }
                    if let error { Text(error).foregroundStyle(palette.destructive) }
                }
                ForEach(playback.offlineAudio.jobs) { job in
                    Section {
                        Text(job.plan.title).font(.headline)
                        Text(job.plan.voiceName).font(.caption)
                        ProgressView(value: job.progress)
                        Text(status(job)).font(.caption)
                        Text("\(job.state.completed.count) of \(job.plan.sentences.count) sentences saved").font(.caption)
                        if let error = job.state.error { Text(error).font(.caption).foregroundStyle(palette.destructive) }
                        Toggle("Follow my reading", isOn: Binding(get: { job.state.lookAhead != nil }, set: {
                            playback.offlineAudio.setLookAhead(job.id, count: $0 ? 2 : nil)
                        }))
                        if let count = job.state.lookAhead {
                            Stepper("Chapters or parts ready: \(count)", value: Binding(get: { count }, set: {
                                playback.offlineAudio.setLookAhead(job.id, count: $0)
                            }), in: 1...1000)
                        }
                        HStack {
                            if [.queued, .generating, .waiting, .caughtUp].contains(job.state.status) {
                                Button("Pause") { playback.offlineAudio.pause(job.id) }
                            } else { Button("Resume") { playback.offlineAudio.resume(job.id) } }
                            Spacer()
                            Menu("Manage") {
                                Button("Remove job, keep audio") { Task { await playback.offlineAudio.remove(job.id, deletingAudio: false) } }
                                Button("Delete generated audio…", role: .destructive) { deletion = Deletion(jobID: job.id) }
                            }
                        }
                        DisclosureGroup("Chapters and parts") {
                            ForEach(job.plan.units) { unit in
                                HStack {
                                    Image(systemName: job.isReady(unit) ? "checkmark.circle.fill" : "circle")
                                    Text(unit.title)
                                    Spacer()
                                    Text("\(unit.indices.filter { job.state.completed.contains($0) }.count)/\(unit.end - unit.start)").font(.caption)
                                    if unit.indices.contains(where: job.state.completed.contains) {
                                        Button { deletion = Deletion(jobID: job.id, unit: unit) } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless).accessibilityLabel("Delete audio for \(unit.title)")
                                    }
                                }
                            }
                        }
                    }
                }
                if let error = playback.offlineAudio.errorMessage { Section { Text(error).foregroundStyle(palette.destructive) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Audio generation")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { bookID = playback.activeBook?.id ?? books.first?.id; voiceID = playback.activeVoiceID ?? voices.defaultVoiceID }
            .confirmationDialog("Delete generated audio?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { request in
                Button("Delete audio", role: .destructive) {
                    Task {
                        if let unit = request.unit { await playback.offlineAudio.deleteAudio(request.jobID, unit: unit) }
                        else { await playback.offlineAudio.remove(request.jobID, deletingAudio: true) }
                        await playback.refreshAudioCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("The book and your saved voices are kept. You can generate the audio again later.") }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 620)
        #endif
    }

    private func status(_ job: OfflineNarrationQueue.Job) -> String {
        switch job.state.status {
        case .queued, .waiting: voices.voice(withID: job.plan.voiceID) == nil ? String(localized: "Waiting for the saved voice model") : String(localized: "Queued · resumes when voice engines are free")
        case .generating: String(localized: "Generating audio…")
        case .paused: String(localized: "Paused")
        case .caughtUp: String(localized: "Window ready · follows your reading")
        case .completed: String(localized: "Ready to listen")
        case .failed: String(localized: "Stopped · check the error and resume")
        }
    }

    private func addBook() {
        guard let book = books.first(where: { $0.id == bookID }), let voice = voices.voice(withID: voiceID) else { return }
        isAdding = true; error = nil
        Task {
            defer { isAdding = false }
            do { try await playback.enqueueOfflineAudio(book: book, voice: voice, paragraphsPerBlock: paragraphs, lookAhead: progressive ? ahead : nil) }
            catch { self.error = error.localizedDescription }
        }
    }
}
