// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

public enum DocumentTypes {
    public static let markdown = UTType("net.daringfireball.markdown")
        ?? UTType(filenameExtension: "md")
        ?? .plainText

    public static var supported: [UTType] {
        [.epub, .pdf, .plainText, .html, .rtf, markdown]
    }
}

public struct LibraryAlert: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

@MainActor
@Observable
public final class ImportCoordinator {
    public let library: LibraryService

    public var isPickerPresented = false
    public var destinationCollectionID: UUID?
    public var isImporting = false
    public var progress: ImportProgress?
    public var lastResult: ImportResult?
    public var toast: String?
    public var alert: LibraryAlert?

    private var toastTask: Task<Void, Never>?

    public init(library: LibraryService) {
        self.library = library
    }

    public func beginImport(collectionID: UUID? = nil) {
        destinationCollectionID = collectionID
        isPickerPresented = true
    }

    public func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        progress = ImportProgress(current: 0, total: urls.count, fileName: "")
        defer {
            isImporting = false
            progress = nil
        }

        let result = await library.importFiles(urls, into: destinationCollectionID) { [weak self] progress in
            self?.progress = progress
        }
        lastResult = result
        destinationCollectionID = nil

        if !result.failures.isEmpty {
            alert = LibraryAlert(
                title: "Some files could not be imported",
                message: result.failures.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
            )
        } else if !result.isEmpty {
            show(toast: result.summaryText)
        }
    }

    public func handleOpenURLs(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        destinationCollectionID = nil
        Task { await importFiles(files) }
    }

    /// Imports documents staged by the Share Extension in the App Group.
    /// Each item is removed only after the app has attempted it; the app never
    /// parses inside the extension.
    public func consumeSharedInbox() async {
        guard !isImporting,
              let root = SharedImportInbox.defaultRoot else { return }
        SharedImportInbox.sweepStale(root: root)
        let pending = SharedImportInbox.pending(root: root)
        guard !pending.isEmpty else { return }

        isImporting = true
        progress = ImportProgress(current: 0, total: pending.count, fileName: "")
        defer {
            isImporting = false
            progress = nil
        }

        var imported = 0
        var duplicates = 0
        var failures: [ImportFailure] = []
        for (index, item) in pending.enumerated() {
            progress = ImportProgress(current: index + 1, total: pending.count, fileName: item.fileName)
            guard let url = SharedImportInbox.fileURL(for: item, root: root) else {
                SharedImportInbox.remove(item, root: root)
                continue
            }
            let result = await library.importFiles([url], into: item.collectionID) { [weak self] update in
                self?.progress = update
            }
            imported += result.imported.count
            duplicates += result.duplicates.count
            failures.append(contentsOf: result.failures)
            // Keep a failed payload for a day so the user can retry; then drop
            // it instead of alerting forever and growing the shared container.
            if result.failures.isEmpty || item.createdAt < Date().addingTimeInterval(-86_400) {
                SharedImportInbox.remove(item, root: root)
            }
        }

        if !failures.isEmpty {
            alert = LibraryAlert(
                title: imported > 0 ? "Shared documents imported with errors" : "Shared documents could not be imported",
                message: failures.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
            )
        } else if imported > 0 {
            let count = imported == 1 ? "1 shared document imported" : "\(imported) shared documents imported"
            show(toast: duplicates > 0 ? "\(count) · \(duplicates) already present" : count)
        } else if duplicates > 0 {
            show(toast: duplicates == 1 ? "That document is already in your library" : "Those documents are already in your library")
        }
    }

    private func show(toast message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
