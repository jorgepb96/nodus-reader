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
