// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import PDFKit
import ZIPFoundation

/// Older development builds shared the personal library. Recognize their exact
/// generated content, back it up, and remove only those fixtures. Titles alone
/// are never evidence: a real imported edition must survive this migration.
@MainActor
enum LegacySampleLibraryCleanup {
    private static let epubSignatures: Set<String> = [
        "bb8bd0aa0a20ceaf2985612c2c1f7d29c91d281c7d8bc7069985df063f242769",
        "743f920fac703348fb4a9a886eef259c38d3a7408ab69fef5b9a45299fee4688",
        "317fbd4c3ee358cbcc2d40bde8434d6dd597ed5858f81c5f5753eafc3c9dddb3",
        "0a535e16f86c348f1cbb0d86c8b51591172337b8b22e3f0bd29b75f9eddfa2f2",
        "024af8d8dbb97982de92e188affa4970961a64476c4563ee037373d59e6338de",
        "73ad39f0e5f03acff13ca26c2ddb00d9a239a5f29f4cd94832ddafe66586a7bf",
        "f5f1afcad1e7e485f75e134b76f9664f1007f00c11721a7891c710bbc0f6d3fb",
        "3c12a7f08d70dd7eace662ee0f0d6de3b663a0b9a07a7317ee22b2b5a1543e7f",
        "8325a651c6922fc9440384e34d8b701e19e8189e2ca2c0b31d2f209aa9c6b516",
        "8c54228b08dc5a373674b91b0bc4a2a47f80ff060a59042098f51644f51a33e5"
    ]

    static func isLegacySample(at url: URL) -> Bool {
        guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return false }
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String
                == "Nodus Reader sample library"
        }
        guard url.pathExtension.lowercased() == "epub",
              FileStore.fileSize(at: url) < 100_000,
              let archive = Archive(url: url, accessMode: .read) else { return false }
        let entries = archive.filter { $0.path.range(of: #"^OEBPS/chapter[0-9]+\.xhtml$"#,
                                                      options: .regularExpression) != nil }
            .sorted { $0.path < $1.path }
        guard (1...3).contains(entries.count), entries.allSatisfy({ $0.uncompressedSize < 100_000 }) else { return false }
        do {
            var digest = SHA256()
            for entry in entries {
                digest.update(data: Data(entry.path.utf8) + Data([0]))
                _ = try archive.extract(entry) { digest.update(data: $0) }
                digest.update(data: Data([0]))
            }
            return epubSignatures.contains(digest.finalize().map { String(format: "%02x", $0) }.joined())
        } catch { return false }
    }

    /// Fails closed: a failed backup leaves the live library untouched.
    /// The return value is useful for migration regression tests.
    @discardableResult
    static func run(library: LibraryService) throws -> Int {
        let samples = library.allBooks().filter { isLegacySample(at: library.fileStore.documentURL(for: $0)) }
        guard !samples.isEmpty else { return 0 }
        let sampleIDs = Set(samples.map(\.id))
        let collections = library.allCollections()
        let removable = sampleCollections(collections, samples: samples, sampleIDs: sampleIDs)
        let backup = library.fileStore.root.appendingPathComponent("LegacySamplesBackup", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var books: [[String: Any]] = []
        for book in samples {
            let directory = backup.appendingPathComponent(book.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: library.fileStore.documentURL(for: book),
                                            to: directory.appendingPathComponent(FileStore.sanitizedFileName(book.fileName)))
            if let cover = library.fileStore.coverForBook(book), FileManager.default.fileExists(atPath: cover.path) {
                try FileManager.default.copyItem(at: cover, to: directory.appendingPathComponent("cover.jpg"))
            }
            books.append([
                "id": book.id.uuidString, "title": book.title, "author": book.author,
                "format": book.formatRaw, "language": book.language, "description": book.bookDescription,
                "fileName": book.fileName, "contentHash": book.contentHash, "progress": book.progress,
                "locatorJSON": book.locatorJSON, "status": book.statusRaw, "favorite": book.isFavorite,
                "appearanceJSON": book.appearanceJSON, "preferredVoiceID": book.preferredVoiceID ?? "",
                "memberships": book.memberships.compactMap { $0.collection?.id.uuidString },
                "bookmarks": book.bookmarks.map { ["id": $0.id.uuidString, "title": $0.title,
                    "chapterTitle": $0.chapterTitle, "locatorJSON": $0.locatorJSON] },
                "annotations": book.annotations.map { ["id": $0.id.uuidString, "chapterIndex": $0.chapterIndex,
                    "startOffset": $0.startOffset, "endOffset": $0.endOffset, "quote": $0.quote,
                    "note": $0.note, "color": $0.colorRaw] as [String: Any] }
            ])
        }
        let manifest: [String: Any] = ["books": books, "collections": collections.map {
            ["id": $0.id.uuidString, "name": $0.name, "parentID": $0.parentID?.uuidString ?? "",
             "sortIndex": $0.sortIndex] as [String: Any]
        }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)
        library.deleteBooks(samples)
        // Only leaf collections may be removed; personal books or custom
        // descendants keep the entire ancestor chain intact.
        var pending = removable
        while let leaf = pending.first(where: { candidate in
            !library.allCollections().contains { $0.parentID == candidate.id }
        }) {
            pending.removeAll { $0.id == leaf.id }
            library.deleteCollection(leaf)
        }
        return samples.count
    }

    private static func sampleCollections(_ all: [LibraryCollection], samples: [Book],
                                          sampleIDs: Set<UUID>) -> [LibraryCollection] {
        // Require the original root set, original ancestry and creation window.
        // A user's independent collection named "History" is not sufficient.
        let roots: Set<String> = ["History", "Literature", "Academic Papers", "Audiobooks"]
        guard roots.isSubset(of: Set(all.filter { $0.parentID == nil }.map(\.name))),
              let first = samples.map(\.createdAt).min(), let last = samples.map(\.createdAt).max() else { return [] }
        let paths: Set<String> = ["History", "History/Contemporary History", "History/Contemporary History/Francoism",
            "History/Contemporary History/Travel Literature", "History/Ancient History", "Literature",
            "Literature/Novels", "Literature/Essays", "Academic Papers", "Audiobooks"]
        func path(_ item: LibraryCollection, visited: Set<UUID> = []) -> String {
            guard !visited.contains(item.id) else { return "" }
            guard let parentID = item.parentID else { return item.name }
            guard let parent = all.first(where: { $0.id == parentID }) else { return "" }
            return path(parent, visited: visited.union([item.id])) + "/" + item.name
        }
        return all.filter { item in
            item.createdAt >= first.addingTimeInterval(-5) && item.createdAt <= last.addingTimeInterval(60) &&
            paths.contains(path(item)) && item.memberships.allSatisfy { member in
                member.book.map { sampleIDs.contains($0.id) } ?? true
            }
        }
    }
}
