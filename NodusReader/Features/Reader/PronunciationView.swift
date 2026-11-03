// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import DesignSystem

private struct PronunciationActionKey: EnvironmentKey {
    static let defaultValue: (Book, String) -> Void = { _, _ in }
}
private struct PronunciationSelectionKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}
extension EnvironmentValues {
    var openPronunciations: (Book, String) -> Void {
        get { self[PronunciationActionKey.self] }
        set { self[PronunciationActionKey.self] = newValue }
    }
    var pronunciationSelection: (String) -> Void {
        get { self[PronunciationSelectionKey.self] }
        set { self[PronunciationSelectionKey.self] = newValue }
    }
}
private struct PronunciationRequest: Identifiable {
    let id = UUID()
    let book: Book
    let selection: String
}
private struct PronunciationHost: ViewModifier {
    var book: Book?
    @State private var request: PronunciationRequest?
    func body(content: Content) -> some View {
        content
            .environment(\.openPronunciations) { book, text in request = .init(book: book, selection: text) }
            .environment(\.pronunciationSelection) { text in
                if let book { request = .init(book: book, selection: text) }
            }
            .sheet(item: $request) { request in
                PronunciationView(book: request.book, selection: request.selection)
            }
    }
}
extension View {
    func pronunciationHost(book: Book? = nil) -> some View { modifier(PronunciationHost(book: book)) }
}

struct PronunciationView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    let book: Book
    var selection = ""
    @State private var written = ""
    @State private var spoken = ""
    @State private var editingID: UUID?
    @State private var contextText = ""
    @State private var previewError: String?

    private var valid: Bool {
        !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !written.contains(where: \.isNewline) && !spoken.contains(where: \.isNewline)
    }
    private var draft: [PronunciationRule] {
        let name = written.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        var rules = book.pronunciations.filter { $0.id != editingID && $0.written != name }
        rules.append(.init(id: editingID ?? UUID(), written: name,
                           spoken: spoken.trimmingCharacters(in: .whitespacesAndNewlines)))
        return rules
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name in the text", text: $written)
                        .accessibilityIdentifier("PronunciationWritten")
                    TextField("Pronounce as", text: $spoken)
                        .accessibilityIdentifier("PronunciationSpoken")
                    Text("Applies to this entire book. Spelling, accents and capitalisation must match.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Original") { preview(corrected: false) }
                        Button("With correction") { preview(corrected: true) }
                            .disabled(!valid)
                        if playback.isPreparingSample { ProgressView() }
                        if playback.isPlayingSample { Button("Stop") { playback.stopSample() } }
                    }
                    .disabled(written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let previewError { Text(previewError).foregroundStyle(.red) }
                    Button("Save pronunciation") {
                        library.setPronunciations(draft, for: book)
                        if library.saveError == nil { clear() }
                    }
                    .disabled(!valid)
                    .accessibilityIdentifier("SavePronunciation")
                } header: { Text("Pronunciation") }
                Section("Saved pronunciations") {
                    ForEach(book.pronunciations) { rule in
                        HStack {
                            Button { select(rule) } label: {
                                VStack(alignment: .leading) {
                                    Text(rule.written)
                                    Text(rule.spoken).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button(role: .destructive) {
                                library.setPronunciations(book.pronunciations.filter { $0.id != rule.id }, for: book)
                                if editingID == rule.id { clear() }
                            } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete pronunciation")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pronunciations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add") { clear() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 500)
        #endif
        .task {
            written = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rule = book.pronunciations.first(where: { $0.written == written }) { select(rule) }
            if let chapters = try? await BookTextLoader.loadChapters(for: book) {
                contextText = chapters.map(\.text).joined(separator: "\n")
            }
        }
        .onChange(of: playback.errorMessage) { _, message in
            if let message { previewError = message }
        }
        .onDisappear { playback.stopSample() }
    }
    private func clear() { written = ""; spoken = ""; editingID = nil; previewError = nil }
    private func select(_ rule: PronunciationRule) { written = rule.written; spoken = rule.spoken; editingID = rule.id }
    private func preview(corrected: Bool) {
        guard playback.voices.narrationVoice(preferredID: book.preferredVoiceID, language: book.language) != nil else {
            previewError = String(localized: "Install a voice model to preview pronunciation.")
            return
        }
        previewError = nil
        var phrase = written
        let ns = contextText as NSString
        if let range = SentenceTokenizer.ranges(from: contextText).first(where: {
            (ns.substring(with: $0) as NSString).range(of: written).location != NSNotFound
        }) { phrase = ns.substring(with: range) }
        playback.previewPronunciation(corrected ? PronunciationTransformer.prepare(phrase, rules: draft).spoken : phrase, book: book)
    }
}
