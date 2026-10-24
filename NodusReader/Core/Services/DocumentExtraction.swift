// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct ExtractedChapter: Codable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var text: String

    public init(id: Int, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

public struct DocumentExtraction: Sendable {
    public var title: String
    public var author: String
    public var language: String
    public var published: String
    public var summary: String
    public var chapters: [ExtractedChapter]
    public var coverData: Data?
    public var searchText: String

    public init(title: String, author: String, language: String = "", published: String = "",
                summary: String = "", chapters: [ExtractedChapter], coverData: Data? = nil,
                searchText: String? = nil) {
        self.title = title
        self.author = author
        self.language = language
        self.published = published
        self.summary = summary
        self.chapters = chapters
        self.coverData = coverData
        let joined = chapters.map(\.text).joined(separator: "\n\n")
        self.searchText = searchText ?? String(joined.prefix(500_000))
    }

    public var chapterTitles: [String] {
        chapters.map(\.title)
    }
}
