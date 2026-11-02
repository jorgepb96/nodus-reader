// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Import › Paste text: the reader pastes or types text, titles it if they
/// wish, and it is imported like a plain-text document (language, cover,
/// narration and sync work as for any other book).
struct PasteTextImportView: View {
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette
    @State private var title = ""
    @State private var text = ""

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title,
                              prompt: Text(trimmedText.isEmpty ? String(localized: "Optional")
                                           : ImportCoordinator.suggestedTitle(for: trimmedText)))
                        .accessibilityIdentifier("pasteText.title")
                } header: {
                    Text("Title")
                } footer: {
                    Text("Leave it empty to use the first line. You can change it later in Edit Info.")
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 260)
                        .accessibilityLabel(Text("Text to import"))
                        .accessibilityIdentifier("pasteText.body")
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Paste or type the text here")
                                    .foregroundStyle(palette.muted)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            let pasted = strings.joined(separator: "\n\n")
                            Task { @MainActor in
                                text = text.isEmpty ? pasted : text + "\n\n" + pasted
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        Spacer()
                        if !text.isEmpty {
                            Button("Clear", role: .destructive) { text = "" }
                        }
                    }
                } header: {
                    Text("Text")
                } footer: {
                    Text("\(wordCount) words · Stays on this device, like any imported document.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Paste Text")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        imports.destinationCollectionID = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let text = text
                        let title = title
                        // The sheet closes first so the reader can open the
                        // new book; the import shows its usual progress.
                        dismiss()
                        Task { await imports.importPastedText(text, title: title) }
                    }
                    .disabled(trimmedText.isEmpty || imports.isImporting)
                    .accessibilityIdentifier("pasteText.import")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 520, minHeight: 540)
        #endif
    }
}

/// The import "+": documents from Files, or text pasted in.
struct ImportMenu<Content: View>: View {
    @Environment(ImportCoordinator.self) private var imports
    var collectionID: UUID?
    @ViewBuilder var label: () -> Content

    var body: some View {
        Menu {
            Button {
                imports.beginImport(collectionID: collectionID)
            } label: {
                Label("Import Files…", systemImage: "doc.badge.plus")
            }
            Button {
                imports.beginPasteText(collectionID: collectionID)
            } label: {
                Label("Paste Text…", systemImage: "doc.on.clipboard")
            }
        } label: {
            label()
        }
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
    }
}
