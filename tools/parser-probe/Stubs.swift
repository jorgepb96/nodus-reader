import AppKit
import Foundation

// Minimal stand-ins for the app-only types so the parser sources can be
// compiled into a small macOS command-line probe. Nothing here is shipped.
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor

public enum BookFormat: String, CaseIterable {
    case epub
    case pdf
    case txt
    case markdown
    case html
    case rtf

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "txt", "text": self = .txt
        case "md", "markdown", "mdown": self = .markdown
        case "html", "htm", "xhtml": self = .html
        case "rtf": self = .rtf
        default: return nil
        }
    }
}

final class FileStore {
    static let shared = FileStore()
    let root: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-probe-\(UUID().uuidString)", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
}

enum EPUBParser {
    static func parse(url: URL, fallbackTitle: String) throws -> DocumentExtraction {
        throw ImportError.unreadableDocument(url.lastPathComponent)
    }
}
