// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Models

struct PDFReflowDocument: Codable, Sendable {
    static let schemaVersion = 2

    var version: Int = PDFReflowDocument.schemaVersion
    var contentHash: String
    var pageCount: Int
    var totalPageCount: Int
    var pages: [PDFReflowPage]
    var usedOCR: Bool
    var generatedAt: Date
}

struct PDFReflowPage: Codable, Identifiable, Sendable {
    var pageIndex: Int
    var width: CGFloat
    var height: CGFloat
    var blocks: [PDFReflowBlock]
    var regions: [PDFReflowRegion]

    var id: Int { pageIndex }
}

struct PDFReflowBlock: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heading1
        case heading2
        case body
        case quote
        case list
        case figure
        case tableImage
    }

    var id: UUID
    var kind: Kind
    var text: String
    var rect: CGRect          // normalized, top-left origin
    var pageIndex: Int
    var imageFileName: String?
    var isHeaderFooter: Bool
    var usedOCR: Bool
}

struct PDFReflowRegion: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case heading
        case table
        case figure
        case headerFooter
        case narrating
    }

    var id: UUID
    var kind: Kind
    var rect: CGRect
    var label: String
}

// MARK: - Cache

struct PDFReflowStore {
    let root: URL

    init(fileStore: FileStore = .shared) {
        root = fileStore.root.appendingPathComponent("Reflow", isDirectory: true)
    }

    func directory(for bookID: UUID) -> URL {
        root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    func manifestURL(for bookID: UUID) -> URL {
        directory(for: bookID).appendingPathComponent("manifest.json")
    }

    func imagesDirectory(for bookID: UUID) -> URL {
        directory(for: bookID).appendingPathComponent("images", isDirectory: true)
    }

    func imageURL(for bookID: UUID, name: String) -> URL {
        imagesDirectory(for: bookID).appendingPathComponent(name)
    }

    func load(bookID: UUID, contentHash: String) -> PDFReflowDocument? {
        guard let data = try? Data(contentsOf: manifestURL(for: bookID)),
              let document = try? JSONDecoder().decode(PDFReflowDocument.self, from: data),
              document.version == PDFReflowDocument.schemaVersion,
              document.contentHash == contentHash else { return nil }
        let images = imagesDirectory(for: bookID)
        let referenced = document.pages
            .flatMap(\.blocks)
            .compactMap(\.imageFileName)
        for name in referenced where !FileManager.default.fileExists(
            atPath: images.appendingPathComponent(name).path
        ) {
            return nil
        }
        return document
    }

    func save(_ document: PDFReflowDocument, bookID: UUID) throws {
        let directory = directory(for: bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        try data.write(to: manifestURL(for: bookID), options: .atomic)
    }

    func remove(bookID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: bookID))
    }

    func size(bookID: UUID) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory(for: bookID),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - Extractor

enum PDFReflowExtractor {
    /// Extracts a reading-order representation without uploading the document.
    /// Text pages use PDFKit glyph bounds; scanned pages use Vision OCR.
    /// Tables and text-less pages are preserved as cropped images.
    static func extract(url: URL, bookID: UUID, contentHash: String,
                        store: PDFReflowStore,
                        maxPages: Int = 400,
                        progress: (@Sendable (Double) -> Void)? = nil) throws -> PDFReflowDocument {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }
        let limit = min(document.pageCount, max(1, maxPages))
        guard limit > 0 else { throw ImportError.emptyDocument(url.lastPathComponent) }

        let imagesDirectory = store.imagesDirectory(for: bookID)
        try? FileManager.default.removeItem(at: imagesDirectory)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        var pages: [PDFReflowPage] = []
        var usedOCR = false

        for index in 0..<limit {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 1, bounds.height > 1 else { continue }

            var lines = textLines(page: page, bounds: bounds)
            var ocrPage = false
            if lines.count < 3 {
                if let ocr = try? visionLines(page: page, bounds: bounds) {
                    if ocr.count > lines.count {
                        lines = ocr
                        ocrPage = true
                        usedOCR = true
                    }
                }
            }

            let pageResult = buildPage(index: index, bounds: bounds, lines: lines,
                                       usedOCR: ocrPage, page: page, document: document,
                                       bookID: bookID, imagesDirectory: imagesDirectory)
            pages.append(pageResult)
            progress?(Double(index + 1) / Double(limit))
        }

        markRepeatedHeaders(in: &pages)
        let result = PDFReflowDocument(contentHash: contentHash, pageCount: limit,
                                       totalPageCount: document.pageCount,
                                       pages: pages, usedOCR: usedOCR, generatedAt: Date())
        try store.save(result, bookID: bookID)
        return result
    }

    /// A running title or byline repeated at the top of several pages is a
    /// header, not content. Keep it on page one (where it is the title) and mark
    /// it as skippable on the remaining pages.
    private static func markRepeatedHeaders(in pages: inout [PDFReflowPage]) {
        var counts: [String: Int] = [:]
        for page in pages {
            for block in page.blocks where block.rect.minY < 0.18 && block.text.count < 140 {
                counts[block.text, default: 0] += 1
            }
        }
        for pageIndex in pages.indices where pages[pageIndex].pageIndex > 0 {
            for blockIndex in pages[pageIndex].blocks.indices {
                let block = pages[pageIndex].blocks[blockIndex]
                if block.rect.minY < 0.18, counts[block.text, default: 0] >= 2 {
                    pages[pageIndex].blocks[blockIndex].isHeaderFooter = true
                }
            }
        }
    }

    // MARK: Lines

    private struct Line {
        var text: String
        var rect: CGRect      // normalized, top-left origin
        var height: CGFloat   // normalized height
        var rawRect: CGRect   // page coordinates (points)
        var rawBounds: CGRect
    }

    private static func textLines(page: PDFPage, bounds: CGRect) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let ns = string as NSString
        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let text = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let selection = page.selection(for: range) else { return }
            let lineBounds = selection.bounds(for: page)
            guard lineBounds.width > 1, lineBounds.height > 1 else { return }
            let normalized = normalize(lineBounds, in: bounds)
            lines.append(Line(text: text, rect: normalized,
                              height: normalized.height,
                              rawRect: normalizeRaw(lineBounds, in: bounds),
                              rawBounds: lineBounds))
        }
        return lines
    }

    private static func visionLines(page: PDFPage, bounds: CGRect) throws -> [Line] {
        guard let image = render(page: page, bounds: bounds, scale: 2) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []

        return observations.compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox // normalized, bottom-left origin
            let normalized = CGRect(x: box.minX, y: 1 - box.maxY,
                                    width: box.width, height: box.height)
            let raw = CGRect(x: bounds.minX + box.minX * bounds.width,
                             y: bounds.minY + box.minY * bounds.height,
                             width: box.width * bounds.width,
                             height: box.height * bounds.height)
            return Line(text: text, rect: normalized, height: normalized.height,
                        rawRect: raw, rawBounds: raw)
        }
    }

    // MARK: Page → blocks

    private static func buildPage(index: Int, bounds: CGRect, lines: [Line],
                                  usedOCR: Bool, page: PDFPage, document: PDFDocument,
                                  bookID: UUID, imagesDirectory: URL) -> PDFReflowPage {
        var regions: [PDFReflowRegion] = []
        guard !lines.isEmpty else {
            // A pure image page: keep the original page appearance.
            let imageName = "page-\(index)-full.jpg"
            if let image = render(page: page, bounds: bounds, scale: 2),
               let data = jpegData(from: image) {
                try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
            }
            let block = PDFReflowBlock(
                id: UUID(), kind: .figure, text: "Page \(index + 1)", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                pageIndex: index, imageFileName: imageName, isHeaderFooter: false, usedOCR: usedOCR
            )
            regions.append(PDFReflowRegion(id: UUID(), kind: .figure,
                                           rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           label: "Scanned page"))
            return PDFReflowPage(pageIndex: index, width: bounds.width, height: bounds.height,
                                 blocks: [block], regions: regions)
        }

        let ordered = readingOrder(lines, pageWidth: bounds.width)
        let medianHeight = median(ordered.map(\.height).filter { $0 > 0 }) ?? 0.018
        let bodyThreshold = medianHeight * 1.22

        var blocks: [PDFReflowBlock] = []
        var currentLines: [Line] = []

        func flushCurrent() {
            guard !currentLines.isEmpty else { return }
            let text = merge(currentLines)
            guard !text.isEmpty else { currentLines = []; return }
            let rect = union(currentLines.map(\.rect))
            let isHeading = currentLines.count <= 2 &&
                (currentLines.first?.height ?? 0) > bodyThreshold
            let kind: PDFReflowBlock.Kind = isHeading ? .heading1 : .body
            let block = PDFReflowBlock(id: UUID(), kind: kind, text: text, rect: rect,
                                       pageIndex: index, imageFileName: nil,
                                       isHeaderFooter: isHeaderFooter(rect) && !isHeading,
                                       usedOCR: usedOCR)
            blocks.append(block)
            regions.append(PDFReflowRegion(id: UUID(), kind: isHeading ? .heading : .text,
                                           rect: rect, label: isHeading ? "Heading" : "Text"))
            currentLines = []
        }

        for line in ordered {
            if let previous = currentLines.last {
                let gap = line.rect.minY - previous.rect.maxY
                let sameHeading = (line.height > bodyThreshold) == (previous.height > bodyThreshold)
                let ratio = previous.height > 0 ? line.height / previous.height : 1
                let sameSize = ratio >= 0.88 && ratio <= 1.12
                if gap > max(0.012, medianHeight * 1.4) || !sameHeading || !sameSize ||
                    isHeaderFooter(line.rect) != isHeaderFooter(previous.rect) {
                    flushCurrent()
                }
            }
            currentLines.append(line)
        }
        flushCurrent()

        // Table heuristic: lines with several numeric/column runs become one image block.
        var tableLines: [Line] = []
        var tableCandidates = Set<UUID>()

        func flushTable() {
            guard tableLines.count >= 2 else { tableLines = []; return }
            let rect = union(tableLines.map(\.rect))
            let imageName = "page-\(index)-table-\(UUID().uuidString.prefix(6)).jpg"
            if let full = render(page: page, bounds: bounds, scale: 2),
               let cropped = crop(full, normalized: rect),
               let data = jpegData(from: cropped) {
                try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
            }
            let block = PDFReflowBlock(
                id: UUID(), kind: .tableImage,
                text: "Table on page \(index + 1) · Reconstructed from the original page",
                rect: rect, pageIndex: index, imageFileName: imageName,
                isHeaderFooter: false, usedOCR: usedOCR
            )
            blocks.append(block)
            regions.append(PDFReflowRegion(id: UUID(), kind: .table, rect: rect, label: "Table"))
            tableLines = []
        }

        var rebuilt: [PDFReflowBlock] = []
        for block in blocks {
            let linesInBlock = ordered.filter { block.rect.intersects($0.rect) && block.kind == .body }
            let tabular = linesInBlock.filter { looksTabular($0.text) }
            // Only replace a block when every line is tabular. Replacing a
            // mixed paragraph would silently drop its prose from the reflow.
            if !linesInBlock.isEmpty, tabular.count == linesInBlock.count, tabular.count >= 2 {
                tableLines.append(contentsOf: tabular)
                tableCandidates.insert(block.id)
            }
        }
        if !tableLines.isEmpty {
            // Replace the source text blocks that became a table with a single image block.
            rebuilt = blocks.filter { !tableCandidates.contains($0.id) }
            flushTable()
            rebuilt.append(contentsOf: blocks.filter { $0.kind == .tableImage })
            rebuilt.sort { $0.rect.minY < $1.rect.minY }
            blocks = rebuilt
        }

        return PDFReflowPage(pageIndex: index, width: bounds.width, height: bounds.height,
                             blocks: blocks, regions: regions)
    }

    // MARK: Reading order and merging

    private static func readingOrder(_ lines: [Line], pageWidth: CGFloat) -> [Line] {
        guard lines.count > 8 else { return lines.sorted { $0.rect.minY < $1.rect.minY } }
        let left = lines.filter { $0.rect.midX < 0.5 }
        let right = lines.filter { $0.rect.midX >= 0.5 }
        let fullWidth = lines.filter { $0.rect.width > 0.58 }
        guard left.count > 3, right.count > 3,
              fullWidth.count < max(2, lines.count / 6),
              let leftMax = left.map(\.rect.maxX).max(),
              let rightMin = right.map(\.rect.minX).min(),
              leftMax < rightMin - 0.02 else {
            return lines.sorted { $0.rect.minY < $1.rect.minY }
        }
        return left.sorted { $0.rect.minY < $1.rect.minY } + right.sorted { $0.rect.minY < $1.rect.minY }
    }

    private static func merge(_ lines: [Line]) -> String {
        var result = ""
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if result.isEmpty {
                result = text
            } else if result.hasSuffix("-") && text.first?.isLowercase == true {
                result.removeLast()
                result += text
            } else {
                result += " " + text
            }
        }
        return result
    }

    private static func looksTabular(_ text: String) -> Bool {
        let numeric = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .filter { token in token.rangeOfCharacter(from: .decimalDigits) != nil }
        let runs = text.components(separatedBy: "  ").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return numeric.count >= 3 || runs.count >= 4
    }

    private static func isHeaderFooter(_ rect: CGRect) -> Bool {
        rect.minY < 0.075 || rect.maxY > 0.94
    }

    // MARK: Geometry and images

    private static func normalize(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - bounds.minX) / bounds.width,
                      y: 1 - (rect.maxY - bounds.minY) / bounds.height,
                      width: rect.width / bounds.width,
                      height: rect.height / bounds.height)
    }

    private static func normalizeRaw(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - bounds.minX) / bounds.width,
                      y: (rect.minY - bounds.minY) / bounds.height,
                      width: rect.width / bounds.width,
                      height: rect.height / bounds.height)
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        guard var result = rects.first else { return .zero }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func render(page: PDFPage, bounds: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 1, height > 1,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    private static func crop(_ image: CGImage, normalized rect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let pixelRect = CGRect(x: rect.minX * width,
                               y: (1 - rect.maxY) * height,
                               width: max(1, rect.width * width),
                               height: max(1, rect.height * height))
        return image.cropping(to: pixelRect.integral)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Annotation anchoring

extension PDFReflowBlock {
    /// Blocks whose text can be selected, highlighted and annotated.
    var isAnnotatableText: Bool {
        switch kind {
        case .heading1, .heading2, .body, .quote, .list: !text.isEmpty
        case .figure, .tableImage: false
        }
    }
}

extension PDFReflowPage {
    /// The page's text blocks joined with blank lines, in reading order,
    /// headers and footers included, plus each block's UTF-16 start offset.
    /// Highlights in Intelligent Reading are stored as offsets into this text
    /// (`Annotation.chapterIndex` = original page index), so they do not depend
    /// on the "Show images" or "Skip headers" switches. Block UUIDs are not
    /// used: they change whenever the reflow cache is regenerated.
    var canonicalLayout: (text: String, bases: [UUID: Int]) {
        var text = ""
        var bases: [UUID: Int] = [:]
        for block in blocks where block.isAnnotatableText {
            if !text.isEmpty { text += "\n\n" }
            bases[block.id] = (text as NSString).length
            text += block.text
        }
        return (text, bases)
    }
}

/// Finds where a stored PDF highlight is in the current reflow text.
enum ReflowAnnotationAnchor {
    /// The stored range when it still covers `quote`; otherwise the occurrence
    /// of `quote` closest to the old position (the reflow cache may have been
    /// rebuilt with slightly different block boundaries); nil when the quote is
    /// no longer on the page.
    static func resolve(start: Int, end: Int, quote: String, in text: String) -> NSRange? {
        let ns = text as NSString
        let target = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let stored = NSRange(location: start, length: max(0, end - start))
        if stored.location >= 0, stored.length > 0, NSMaxRange(stored) <= ns.length,
           ns.substring(with: stored).trimmingCharacters(in: .whitespacesAndNewlines) == target {
            return stored
        }
        var best: NSRange?
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: target, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - start) < abs(best!.location - start) {
                best = found
            }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return best
    }
}
