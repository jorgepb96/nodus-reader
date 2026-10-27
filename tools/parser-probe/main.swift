import Foundation
import PDFKit

struct Options {
    var format: BookFormat
    var url: URL
    var pages: Int?
    var markdownPath: String?
    var reflow = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: probe <pdf|txt|md|html|rtf> <file> [--pages N] [--reflow] [--markdown out.md]

    Without --reflow the import extractor is used. With --reflow the PDF
    Intelligent Reading layout is printed and, with --markdown, written to a
    file. Nothing leaves the machine.

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let format = BookFormat(fileExtension: args[0]) else { usage() }
let url = URL(fileURLWithPath: args[1])
args.removeFirst(2)
var options = Options(format: format, url: url)
while !args.isEmpty {
    switch args.removeFirst() {
    case "--pages":
        guard !args.isEmpty, let value = Int(args.removeFirst()) else { usage() }
        options.pages = value
    case "--markdown":
        guard !args.isEmpty else { usage() }
        options.markdownPath = args.removeFirst()
    case "--reflow":
        options.reflow = true
    default:
        usage()
    }
}

func describe(_ document: PDFReflowDocument) -> String {
    var out: [String] = []
    for page in document.pages {
        out.append("=== page \(page.pageIndex + 1) (\(page.blocks.count) blocks)")
        for block in page.blocks {
            let flags = [
                block.isHeaderFooter ? "HEADER/FOOTER" : nil,
                block.isFootnote ? "FOOTNOTE" : nil,
                block.continuesPrevious ? "CONT" : nil,
                block.isCaption ? "CAPTION" : nil,
                block.usedOCR ? "OCR" : nil
            ].compactMap { $0 }.joined(separator: ",")
            let rect = block.rect
            out.append("[\(block.kind.rawValue)\(flags.isEmpty ? "" : " \(flags)")] "
                + "rect=(x:\(String(format: "%.3f", rect.minX)) "
                + "y:\(String(format: "%.3f", rect.minY)) "
                + "w:\(String(format: "%.3f", rect.width)) "
                + "h:\(String(format: "%.3f", rect.height))) \(block.text)")
        }
    }
    return out.joined(separator: "\n")
}

do {
    if options.format == .pdf, options.reflow {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-probe-store-\(UUID().uuidString)", isDirectory: true)
        let store = PDFReflowStore(fileStore: FileStore(root: root))
        let document = try PDFReflowExtractor.extract(
            url: options.url, bookID: UUID(), contentHash: "probe", store: store,
            maxPages: options.pages ?? 400
        )
        print(describe(document))
        if let path = options.markdownPath {
            try document.markdown().write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
        }
    } else {
        let extraction = try DocumentExtractor.extract(
            url: options.url, format: options.format, completeText: true
        )
        let chapters = options.pages.map { Array(extraction.chapters.prefix($0)) }
            ?? extraction.chapters
        print(chapters.map(\.text).joined(separator: "\n\n"))
        if let path = options.markdownPath {
            try chapters.map(\.text).joined(separator: "\n\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
