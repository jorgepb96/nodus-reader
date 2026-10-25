// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import ZIPFoundation

/// Minimal, read-only EPUB 2/3 package parser.
///
/// It extracts package metadata, the cover image, spine text and navigation
/// labels. Layout, CFI and rendering belong to the EPUBReader module in
/// The parser deliberately has no opinion about presentation.
public enum EPUBParser {
    private static let maximumEntryBytes = 64 * 1024 * 1024
    private static let maximumExtractedBytes = 256 * 1024 * 1024

    public static func parse(url: URL, fallbackTitle: String) throws -> DocumentExtraction {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }

        var entries: [String: Entry] = [:]
        for entry in archive where entry.type == .file {
            let normalized = normalize(entry.path)
            entries[normalized] = entry
            if let decoded = normalized.removingPercentEncoding {
                entries[decoded] = entry
            }
        }

        func entry(_ path: String) -> Entry? {
            if let exact = entries[path] { return exact }
            return entries.first { $0.key.caseInsensitiveCompare(path) == .orderedSame }?.value
        }

        var extractedBytes = 0
        func data(_ path: String) throws -> Data? {
            guard let item = entry(path) else { return nil }
            guard item.uncompressedSize <= UInt64(maximumEntryBytes),
                  extractedBytes + Int(item.uncompressedSize) <= maximumExtractedBytes else {
                throw ImportError.fileTooLarge(url.lastPathComponent)
            }
            var output = Data()
            _ = try archive.extract(item) { chunk in output.append(chunk) }
            extractedBytes += output.count
            return output
        }

        guard let containerData = try data("META-INF/container.xml") else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }

        let container = ContainerParser()
        let containerXML = XMLParser(data: containerData)
        containerXML.delegate = container
        containerXML.parse()

        guard let packagePath = container.rootPath else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }
        guard let packageData = try data(normalize(packagePath)) else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }

        let package = OPFParser()
        let packageXML = XMLParser(data: packageData)
        packageXML.shouldProcessNamespaces = true
        packageXML.delegate = package
        packageXML.parse()

        let baseDirectory = (normalize(packagePath) as NSString).deletingLastPathComponent

        var navigationTitles: [String: String] = [:]
        if let navItem = package.navigationItem {
            let navPath = resolve(navItem.href, relativeTo: baseDirectory)
            if let navData = try? data(navPath) {
                if navItem.mediaType.contains("dtbncx") {
                    navigationTitles = NCXParser.titles(from: navData, relativeTo: baseDirectory)
                } else {
                    navigationTitles = NavigationDocumentParser.titles(from: navData, relativeTo: baseDirectory)
                }
            }
        }

        var chapters: [ExtractedChapter] = []
        var spineItems: [OPFManifestItem] = package.spineIDs.compactMap { package.manifest[$0] }
        if spineItems.isEmpty {
            spineItems = package.manifest.values
                .filter { $0.mediaType.contains("html") }
                .sorted { $0.href.localizedStandardCompare($1.href) == .orderedAscending }
        }

        for (index, item) in spineItems.enumerated() {
            guard item.mediaType.contains("html") || item.href.lowercased().hasSuffix(".xhtml") else { continue }
            let path = resolve(item.href, relativeTo: baseDirectory)
            guard let chapterData = try? data(path) else { continue }

            var text = HTMLText.plainText(from: chapterData)

            let pathKey = normalize(path)
            let title = navigationTitles[pathKey]
                ?? navigationTitles[item.href]
                ?? HTMLText.firstHeading(from: chapterData)
                ?? "Chapter \(chapters.count + 1)"

            if text.hasPrefix(title) {
                let remainder = text.dropFirst(title.count)
                // Only strip a real heading line. A title such as "I" or "A"
                // must not eat the first letter of the body ("It was…").
                if remainder.isEmpty || remainder.first?.isWhitespace == true {
                    text = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard text.count > 10 else { continue }

            chapters.append(ExtractedChapter(id: chapters.count, title: title, text: text))
            if chapters.count >= 500 { break }
            _ = index
        }

        guard !chapters.isEmpty else {
            throw ImportError.emptyDocument(url.lastPathComponent)
        }

        var coverData: Data?
        if let coverItem = package.coverItem, !coverItem.mediaType.contains("svg") {
            let coverPath = resolve(coverItem.href, relativeTo: baseDirectory)
            coverData = try? data(coverPath)
        }

        let title = package.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackTitle
            : package.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = package.creators
            .joined(separator: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = HTMLText.plainText(from: package.summary)
        let published = package.date.isEmpty ? "" : String(package.date.prefix(4))
        let detectedLanguage = LanguageDetector.resolve(
            declared: package.language,
            text: chapters.map(\.text).joined(separator: "\n\n")
        )

        return DocumentExtraction(
            title: title,
            author: author,
            language: detectedLanguage,
            published: published,
            summary: summary,
            chapters: chapters,
            coverData: coverData
        )
    }

    // MARK: - Paths

    static func normalize(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(part))
        }
        return components.joined(separator: "/")
    }

    static func resolve(_ href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let pathOnly = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? decoded
        let combined = base.isEmpty ? pathOnly : base + "/" + pathOnly
        return normalize(combined)
    }
}

// MARK: - Container

private final class ContainerParser: NSObject, XMLParserDelegate {
    var rootPath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile" || qName == "rootfile" {
            rootPath = attributeDict["full-path"]
        }
    }
}

// MARK: - OPF

struct OPFManifestItem: Sendable {
    var id: String
    var href: String
    var mediaType: String
    var properties: String

    var isNavigation: Bool {
        properties.split(separator: " ").contains("nav") || mediaType.contains("dtbncx")
    }

    var isCoverImage: Bool {
        properties.split(separator: " ").contains("cover-image")
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    var title = ""
    var creators: [String] = []
    var language = ""
    var date = ""
    var summary = ""
    var manifest: [String: OPFManifestItem] = [:]
    var spineIDs: [String] = []
    var spineTOC: String?
    var coverID: String?

    private var captureElement: String?
    private var captureBuffer = ""

    var navigationItem: OPFManifestItem? {
        if let toc = spineTOC, let item = manifest[toc], item.isNavigation { return item }
        return manifest.values.first(where: \.isNavigation)
    }

    var coverItem: OPFManifestItem? {
        if let coverID, let item = manifest[coverID] { return item }
        if let item = manifest.values.first(where: \.isCoverImage) { return item }
        return manifest.values.first {
            $0.mediaType.hasPrefix("image/") &&
            ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover"))
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName, qName: qName)

        switch local {
        case "title", "creator", "language", "date", "description":
            captureElement = local
            captureBuffer = ""
        case "meta":
            if attributeDict["name"]?.lowercased() == "cover", let content = attributeDict["content"] {
                coverID = content
            }
        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else { break }
            let mediaType = attributeDict["media-type"] ?? ""
            let properties = attributeDict["properties"] ?? ""
            manifest[id] = OPFManifestItem(id: id, href: href, mediaType: mediaType, properties: properties)
        case "spine":
            if let toc = attributeDict["toc"] { spineTOC = toc }
        case "itemref":
            if let idref = attributeDict["idref"], attributeDict["linear"] != "no" {
                spineIDs.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureElement != nil {
            captureBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let local = localName(elementName, qName: qName)
        guard local == captureElement else { return }
        let value = captureBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "title": if title.isEmpty { title = value }
        case "creator": if !value.isEmpty { creators.append(value) }
        case "language": if language.isEmpty { language = value }
        case "date": if date.isEmpty { date = value }
        case "description": if summary.isEmpty { summary = value }
        default: break
        }
        captureElement = nil
        captureBuffer = ""
    }

    private func localName(_ elementName: String, qName: String?) -> String {
        let value = qName ?? elementName
        if let colon = value.firstIndex(of: ":") {
            return String(value[value.index(after: colon)...])
        }
        return value
    }
}

// MARK: - Navigation labels

private enum NCXParser {
    static func titles(from data: Data, relativeTo base: String) -> [String: String] {
        let delegate = NCXDelegate(baseDirectory: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.titles
    }

    private final class NCXDelegate: NSObject, XMLParserDelegate {
        var titles: [String: String] = [:]
        private let baseDirectory: String
        private var inLabel = false
        private var label = ""

        init(baseDirectory: String) {
            self.baseDirectory = baseDirectory
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = localName(elementName)
            if local == "text" {
                inLabel = true
                label = ""
            } else if local == "content", let src = attributeDict["src"] {
                let path = EPUBParser.resolve(src, relativeTo: baseDirectory)
                if !label.isEmpty {
                    titles[path] = label
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inLabel { label += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if localName(elementName) == "text" {
                inLabel = false
                label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        private func localName(_ name: String) -> String {
            if let colon = name.firstIndex(of: ":") {
                return String(name[name.index(after: colon)...])
            }
            return name
        }
    }
}

private enum NavigationDocumentParser {
    static func titles(from data: Data, relativeTo base: String) -> [String: String] {
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        ) else { return result }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 2,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange])
            let title = HTMLText.normalize(
                HTMLText.plainText(from: String(html[textRange]))
            )
            guard !title.isEmpty else { continue }
            let path = EPUBParser.resolve(href, relativeTo: base)
            result[path] = title
        }
        return result
    }
}
