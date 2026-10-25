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
        // Encrypted chapters mean DRM (font obfuscation only covers fonts).
        // Nodus Reader does not remove DRM, so say so instead of importing
        // ciphertext as text.
        if let encryption = try data("META-INF/encryption.xml"), encryptsText(encryption) {
            throw ImportError.drmProtected(url.lastPathComponent)
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

        var navigationPoints: [NavigationPoint] = []
        if let navItem = package.navigationItem {
            let navPath = resolve(navItem.href, relativeTo: baseDirectory)
            let navDirectory = (navPath as NSString).deletingLastPathComponent
            if let navData = try? data(navPath) {
                if navItem.mediaType.contains("dtbncx") {
                    navigationPoints = NCXParser.points(from: navData, relativeTo: navDirectory)
                } else {
                    navigationPoints = NavigationDocumentParser.points(from: navData, relativeTo: navDirectory)
                }
            }
        }

        var spineItems: [OPFManifestItem] = package.spineIDs.compactMap { package.manifest[$0] }
        if spineItems.isEmpty {
            spineItems = package.manifest.values
                .filter { $0.mediaType.contains("html") }
                .sorted { $0.href.localizedStandardCompare($1.href) == .orderedAscending }
        }

        var builder = ChapterBuilder(hasNavigation: !navigationPoints.isEmpty)
        for item in spineItems {
            guard item.mediaType.contains("html") || item.href.lowercased().hasSuffix(".xhtml") else { continue }
            let path = resolve(item.href, relativeTo: baseDirectory)
            guard let chapterData = try? data(path) else { continue }
            let raw = String(data: chapterData, encoding: .utf8)
                ?? String(data: chapterData, encoding: .isoLatin1)
                ?? ""
            let conversion = HTMLText.convert(raw)
            let points = navigationPoints.filter { $0.path.caseInsensitiveCompare(path) == .orderedSame }
            builder.add(conversion, points: points, heading: HTMLText.firstHeading(from: chapterData),
                        documentTitle: HTMLText.documentTitle(from: chapterData),
                        hasSectionHeading: HTMLText.hasSectionHeading(raw))
            if builder.chapters.count >= 500 { break }
        }
        let chapters = builder.chapters

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

    static func encryptsText(_ encryptionXML: Data) -> Bool {
        let xml = String(data: encryptionXML, encoding: .utf8) ?? ""
        guard let regex = try? NSRegularExpression(pattern: "(?i)URI\\s*=\\s*[\"']([^\"']+)[\"']") else { return false }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: range).contains { match in
            guard let uri = Range(match.range(at: 1), in: xml) else { return false }
            let path = xml[uri].lowercased()
            return path.hasSuffix(".xhtml") || path.hasSuffix(".html") || path.hasSuffix(".htm")
        }
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

    static func navigationPoint(_ href: String, title: String, relativeTo base: String) -> NavigationPoint {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : nil
        return NavigationPoint(path: resolve(href, relativeTo: base), fragment: fragment, title: title)
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

// MARK: - Chapters

/// One table-of-contents entry: a spine file, an optional element id inside
/// it and the label the book gives that place.
struct NavigationPoint: Equatable, Sendable {
    var path: String
    var fragment: String?
    var title: String
}

/// Turns spine documents into reading chapters that follow the book's own
/// table of contents: a file holding several chapters is split at the anchors
/// the contents point to, and a file the contents never mention (a split
/// continuation, a page with no heading) continues the previous chapter
/// instead of becoming a chapter of its own.
struct ChapterBuilder {
    private(set) var chapters: [ExtractedChapter] = []
    let hasNavigation: Bool

    init(hasNavigation: Bool) {
        self.hasNavigation = hasNavigation
    }

    mutating func add(_ conversion: HTMLText.Conversion, points: [NavigationPoint],
                      heading: String?, documentTitle: String?, hasSectionHeading: Bool) {
        let text = conversion.text as NSString
        // Contents entries resolved to offsets in this file, in reading
        // order. Entries sharing an offset (a part and its first chapter)
        // keep the most specific, the last one listed.
        var starts: [(offset: Int, title: String)] = []
        for point in points {
            let offset: Int
            if let fragment = point.fragment, !fragment.isEmpty {
                guard let anchor = conversion.anchors[fragment] else { continue }
                offset = anchor
            } else {
                offset = 0
            }
            if let index = starts.firstIndex(where: { $0.offset == offset }) {
                starts[index].title = point.title
            } else {
                starts.append((offset, point.title))
            }
        }
        starts.sort { $0.offset < $1.offset }

        let leadingEnd = starts.first?.offset ?? text.length
        if leadingEnd > 0 {
            let leading = Self.slice(text, from: 0, to: leadingEnd)
            if starts.isEmpty, !(hasNavigation && !hasSectionHeading && !chapters.isEmpty) {
                // Without contents (or with a real heading) a file is a chapter.
                append(title: heading, text: leading)
            } else {
                // Text before the first contents entry: its headings belong to
                // later sections, so an opening chunk is named by the page.
                continuePrevious(with: leading,
                                 fallbackTitle: starts.isEmpty ? heading : Self.pageTitle(documentTitle, text: leading))
            }
        }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].offset : text.length
            append(title: start.title, text: Self.slice(text, from: start.offset, to: end))
        }
    }

    private mutating func append(title: String?, text: String) {
        let title = title.map(HTMLText.normalize) ?? ""
        let body = Self.removingHeading(title, from: text)
        guard body.count > 10 else { return }
        chapters.append(ExtractedChapter(id: chapters.count,
                                         title: title.isEmpty ? "Chapter \(chapters.count + 1)" : title,
                                         text: body))
    }

    private mutating func continuePrevious(with text: String, fallbackTitle: String?) {
        guard !text.isEmpty else { return }
        guard let last = chapters.indices.last else {
            append(title: fallbackTitle, text: text)
            return
        }
        chapters[last].text += "\n\n" + text
    }

    /// A page's `<title>` unless it is only a file name ("content.html"),
    /// otherwise its first line when that line is short enough to be one.
    private static func pageTitle(_ documentTitle: String?, text: String) -> String? {
        if let documentTitle,
           !documentTitle.lowercased().hasSuffix(".html"), !documentTitle.lowercased().hasSuffix(".xhtml"),
           !documentTitle.lowercased().hasSuffix(".htm") {
            return documentTitle
        }
        let firstLine = text.prefix { $0 != "\n" }
        return firstLine.count <= 80 ? String(firstLine) : nil
    }

    private static func slice(_ text: NSString, from start: Int, to end: Int) -> String {
        let lower = min(max(0, start), text.length)
        let upper = min(max(lower, end), text.length)
        return text.substring(with: NSRange(location: lower, length: upper - lower))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the chapter label when the text opens with it, so the heading is
    /// not shown (or narrated) twice. Only a whole heading line is removed: a
    /// title such as "I" or "A" must not eat the first letter of "It was…",
    /// and a heading that continues on the next line is kept whole.
    static func removingHeading(_ title: String, from text: String) -> String {
        guard !title.isEmpty,
              let range = text.range(of: title, options: [.anchored, .caseInsensitive]) else { return text }
        let remainder = text[range.upperBound...]
        guard remainder.isEmpty || remainder.hasPrefix("\n\n") else { return text }
        return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Navigation

private enum NCXParser {
    static func points(from data: Data, relativeTo base: String) -> [NavigationPoint] {
        let delegate = NCXDelegate(baseDirectory: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    private final class NCXDelegate: NSObject, XMLParserDelegate {
        var points: [NavigationPoint] = []
        private let baseDirectory: String
        private var inNavMap = false
        private var inLabel = false
        private var label = ""

        init(baseDirectory: String) {
            self.baseDirectory = baseDirectory
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = localName(elementName)
            if local == "navMap" {
                inNavMap = true
            } else if local == "text" {
                inLabel = true
                label = ""
            } else if inNavMap, local == "content", let src = attributeDict["src"] {
                let title = HTMLText.normalize(label)
                if !title.isEmpty {
                    points.append(EPUBParser.navigationPoint(src, title: title, relativeTo: baseDirectory))
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inLabel { label += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch localName(elementName) {
            case "text": inLabel = false
            case "navMap": inNavMap = false
            default: break
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
    static func points(from data: Data, relativeTo base: String) -> [NavigationPoint] {
        var html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        // Only the table of contents: a nav document also lists landmarks and
        // page lists, whose links must not become chapters.
        if let toc = firstCapture("(?is)<nav[^>]*epub:type\\s*=\\s*[\"'][^\"']*\\btoc\\b[^\"']*[\"'][^>]*>(.*?)</nav>", in: html) {
            html = toc
        }
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<a[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        ) else { return [] }
        var result: [NavigationPoint] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 2,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            let title = HTMLText.normalize(HTMLText.plainText(from: String(html[textRange])))
            guard !title.isEmpty else { continue }
            result.append(EPUBParser.navigationPoint(String(html[hrefRange]), title: title, relativeTo: base))
        }
        return result
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}
