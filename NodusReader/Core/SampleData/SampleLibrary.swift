// SPDX-License-Identifier: AGPL-3.0-only
#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ZIPFoundation

/// Debug-only sample library. It builds real EPUB and PDF files, runs them
/// through the production import pipeline and seeds reading state so the UI can
/// be compared with design/screens/ without shipping made-up button handlers.
@MainActor
enum SampleLibrary {
    struct Chapter {
        var title: String
        var paragraphs: [String]
    }

    struct Spec {
        var title: String
        var author: String
        var language: String
        var description: String
        var asPDF: Bool
        var chapters: [Chapter]
    }

    /// Deterministic starting point for UI tests: the configured sample
    /// progress usually moves as tests read, which would make a test that
    /// expects a chapter opener depend on whatever ran before it.
    static func resetReadingState(library: LibraryService) {
        let books = library.allBooks()
        for book in books {
            for bookmark in Array(book.bookmarks) {
                library.deleteBookmark(bookmark)
            }
            book.locator = ReadingLocator()
            book.progress = 0
            book.lastOpenedAt = nil
            book.lastPositionDevice = ""
            book.lastPositionDate = nil
            book.status = .toRead
            book.appearance = nil
        }
        if let moby = books.first(where: { $0.title == "Moby-Dick" }) {
            moby.lastOpenedAt = Date()
            moby.lastPositionDevice = DeviceInfo.name
            moby.lastPositionDate = Date()
            moby.status = .inProgress
        }
        library.save()
    }

    static func seedIfNeeded(library: LibraryService) async {
        guard library.allBooks().isEmpty else { return }

        let specs = sampleSpecs()
        var urls: [URL] = []
        var temporaryURLs: [URL] = []
        for spec in specs {
            do {
                let url = spec.asPDF ? try makePDF(spec) : try makeEPUB(spec)
                urls.append(url)
                temporaryURLs.append(url)
            } catch {
                print("Sample document failed: \(spec.title): \(error)")
            }
        }

        let result = await library.importFiles(urls, into: nil) { _ in }
        for failure in result.failures {
            print("Sample import failed: \(failure.fileName): \(failure.message)")
        }
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }

        var byTitle: [String: Book] = [:]
        for book in result.imported {
            byTitle[book.title] = book
        }

        let history = library.createCollection(name: "History")
        let contemporary = history.flatMap {
            library.createCollection(name: "Contemporary History", parentID: $0.id)
        }
        let francoism = contemporary.flatMap {
            library.createCollection(name: "Francoism", parentID: $0.id)
        }
        let travel = contemporary.flatMap {
            library.createCollection(name: "Travel Literature", parentID: $0.id)
        }
        let ancient = history.flatMap {
            library.createCollection(name: "Ancient History", parentID: $0.id)
        }
        let literature = library.createCollection(name: "Literature")
        let novels = literature.flatMap {
            library.createCollection(name: "Novels", parentID: $0.id)
        }
        let essays = literature.flatMap {
            library.createCollection(name: "Essays", parentID: $0.id)
        }
        let papers = library.createCollection(name: "Academic Papers")
        _ = library.createCollection(name: "Audiobooks")

        func add(_ title: String, to collection: LibraryCollection?) {
            guard let book = byTitle[title], let collection else { return }
            library.add(book, to: collection)
        }

        add("The Odyssey", to: history)
        add("Moby-Dick", to: novels)
        add("Don Quijote de la Mancha", to: novels)
        add("Middlemarch", to: novels)
        add("The Odyssey", to: ancient)
        add("The Odyssey", to: novels)
        add("Meditations", to: ancient)
        add("Meditations", to: essays)
        add("Walden", to: essays)
        add("Homage to Catalonia", to: contemporary)
        add("Homage to Catalonia", to: travel)
        add("The Spanish Civil War", to: contemporary)
        add("The Spanish Labyrinth", to: francoism)
        add("Journey to the Alcarria", to: travel)
        add("Experiments in Plant Hybridization", to: papers)
        add("On the Origin of Species", to: papers)

        let now = Date()
        func configure(_ title: String, progress: Double, status: ReadingStatus,
                       favorite: Bool = false, lastOpenedDaysAgo: Double? = nil,
                       addedDaysAgo: Double, device: String? = nil) {
            guard let book = byTitle[title] else { return }
            book.progress = progress
            book.status = status
            book.isFavorite = favorite
            book.addedAt = now.addingTimeInterval(-addedDaysAgo * 86_400)
            if let days = lastOpenedDaysAgo {
                let date = now.addingTimeInterval(-days * 86_400)
                book.lastOpenedAt = date
                book.lastPositionDate = date
                book.lastPositionDevice = device ?? DeviceInfo.name
            }
            book.touch()
        }

        configure("Moby-Dick", progress: 0.12, status: .inProgress,
                  lastOpenedDaysAgo: 0.02, addedDaysAgo: 20, device: "Jorge's MacBook Pro")
        configure("Don Quijote de la Mancha", progress: 0.06, status: .inProgress,
                  lastOpenedDaysAgo: 2, addedDaysAgo: 34)
        configure("Experiments in Plant Hybridization", progress: 0.21, status: .inProgress,
                  lastOpenedDaysAgo: 1.2, addedDaysAgo: 18)
        configure("Walden", progress: 0.41, status: .inProgress,
                  lastOpenedDaysAgo: 5, addedDaysAgo: 41)
        configure("The Odyssey", progress: 0.64, status: .inProgress,
                  lastOpenedDaysAgo: 12, addedDaysAgo: 60)
        configure("Homage to Catalonia", progress: 1, status: .finished, favorite: true,
                  lastOpenedDaysAgo: 1, addedDaysAgo: 26)
        configure("On the Origin of Species", progress: 0.18, status: .inProgress,
                  lastOpenedDaysAgo: 15, addedDaysAgo: 55)
        configure("Meditations", progress: 0, status: .toRead, favorite: true, addedDaysAgo: 9)
        configure("Middlemarch", progress: 0, status: .toRead, favorite: true, addedDaysAgo: 13)
        configure("The Spanish Civil War", progress: 0, status: .toRead, addedDaysAgo: 7)
        configure("The Spanish Labyrinth", progress: 0.27, status: .inProgress,
                  lastOpenedDaysAgo: 8, addedDaysAgo: 30)
        configure("Journey to the Alcarria", progress: 0, status: .toRead, addedDaysAgo: 4)

        library.save()
    }

    /// Opt-in real EPUB fixture for fast contents scrolling and four-digit numbers.
    static func seedLongContentsIfNeeded(library: LibraryService) async {
        let title = "Long Contents Test"
        guard !library.allBooks().contains(where: { $0.title == title }) else { return }
        let chapters = (1...1200).map { number in
            Chapter(title: "Chapter \(number): A journey through the changing seasons",
                    paragraphs: ["This is chapter \(number) of the long contents navigation fixture."])
        }
        let spec = Spec(title: title, author: "Nodus Reader", language: "en",
                        description: "Long contents navigation test fixture.", asPDF: false,
                        chapters: chapters)
        do {
            let url = try makeEPUB(spec)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = await library.importFiles([url], into: nil) { _ in }
        } catch {
            print("Long contents fixture failed: \(error)")
        }
    }

    // MARK: - EPUB

    static func makeEPUB(_ spec: Spec) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodusSamples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).epub")
        try? FileManager.default.removeItem(at: url)

        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ string: String, compressed: Bool = true) throws {
            let data = Data(string.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: compressed ? .deflate : .none
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }

        try add("mimetype", "application/epub+zip", compressed: false)
        try add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """)

        let manifest = spec.chapters.enumerated().map { index, _ in
            "<item id=\"ch\(index + 1)\" href=\"chapter\(index + 1).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n    ")
        let spine = spec.chapters.indices.map { "<itemref idref=\"ch\($0 + 1)\"/>" }.joined(separator: "\n    ")
        let navLinks = spec.chapters.enumerated().map { index, chapter in
            "<li><a href=\"chapter\(index + 1).xhtml\">\(escape(chapter.title))</a></li>"
        }.joined(separator: "\n      ")

        try add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(escape(spec.title))</dc:title>
            <dc:creator>\(escape(spec.author))</dc:creator>
            <dc:language>\(spec.language)</dc:language>
            <dc:description>\(escape(spec.description))</dc:description>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifest)
          </manifest>
          <spine>
            \(spine)
          </spine>
        </package>
        """)

        try add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body>
          <nav epub:type="toc"><h1>Contents</h1><ol>
            \(navLinks)
          </ol></nav>
        </body>
        </html>
        """)

        for (index, chapter) in spec.chapters.enumerated() {
            let body = chapter.paragraphs.map { "<p>\(escape($0))</p>" }.joined(separator: "\n      ")
            try add("OEBPS/chapter\(index + 1).xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(escape(chapter.title))</title></head>
            <body>
              <h1>\(escape(chapter.title))</h1>
              \(body)
            </body>
            </html>
            """)
        }

        return url
    }

    /// A ZIP archive with the given entries in order, for EPUB fixtures that
    /// need a hand-written package (several chapters per file, NCX, etc.).
    static func makeArchive(_ entries: [(path: String, contents: String)],
                            pathExtension: String = "epub") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodusSamples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = Data(entry.contents.utf8)
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: entry.path == "mimetype" ? .none : .deflate) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        return url
    }

    // MARK: - PDF

    static func makePDF(_ spec: Spec) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodusSamples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw SampleError.pdf
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: spec.title,
            kCGPDFContextAuthor as String: spec.author,
            kCGPDFContextCreator as String: "Nodus Reader sample library"
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw SampleError.pdf
        }

        let pages = spec.chapters.flatMap { chapter in
            chapter.paragraphs.map { (chapter.title, $0) }
        }
        let pageCount = max(3, min(pages.count, 6))

        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()

            draw(text: spec.title, at: CGPoint(x: 72, y: mediaBox.height - 64),
                 font: CTFontCreateWithName("Georgia" as CFString, 20, nil),
                 in: context, width: 468)
            draw(text: spec.author, at: CGPoint(x: 72, y: mediaBox.height - 92),
                 font: CTFontCreateWithName("Georgia-Italic" as CFString, 11, nil),
                 in: context, width: 468)

            let bodyRect = CGRect(x: 72, y: 120, width: 468, height: 560)
            let text = page < pages.count ? pages[page].1 : "Sample page."
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: CTFontCreateWithName("Georgia" as CFString, 13, nil),
                    .foregroundColor: CGColor(gray: 0.12, alpha: 1)
                ]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: bodyRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)

            draw(text: "\(page + 1)", at: CGPoint(x: 296, y: 30),
                 font: CTFontCreateWithName("Georgia" as CFString, 10, nil),
                 in: context, width: 20)

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        try data.write(to: url, options: .atomic)
        return url
    }

    private static func draw(text: String, at point: CGPoint, font: CTFont,
                             in context: CGContext, width: CGFloat) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 0.08, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
        _ = width
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private enum SampleError: Error {
        case pdf
    }

    // MARK: - Specs

    static func sampleSpecs() -> [Spec] {
        [
            Spec(
                title: "Moby-Dick",
                author: "Herman Melville",
                language: "en",
                description: "A whaling voyage and the pursuit of the white whale.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Loomings", paragraphs: [
                        "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.",
                        "It is a way I have of driving off the spleen and regulating the circulation. Whenever I find myself growing grim about the mouth; whenever I find myself involuntarily pausing before coffin warehouses, and bringing up the rear of every funeral I meet; and especially whenever my hypos get such an upper hand of me, that it requires a strong moral principle to prevent me from deliberately stepping into the street, and methodically knocking people’s hats off—then, I account it high time to get to sea as soon as I can.",
                        "There now is your insular city of the Manhattoes, belted round by wharves as Indian isles by coral reefs—commerce surrounds it with her surf."
                    ]),
                    Chapter(title: "The Carpet-Bag", paragraphs: [
                        "I stuffed a shirt or two into my old carpet-bag, tucked it under my arm, and started for Cape Horn and the Pacific.",
                        "Quitting the good city of old Manhatto, I duly arrived in New Bedford. It was a Saturday night in December. Much was I disappointed upon learning that the little packet for Nantucket had already sailed, and that no way of reaching that place would offer, till the following Monday."
                    ]),
                    Chapter(title: "The Spouter-Inn", paragraphs: [
                        "Entering that gable-ended Spouter-Inn, you found yourself in a wide, low, straggling entry with old-fashioned wainscots, reminding one of the bulwarks of some condemned old craft.",
                        "On one side hung a very large oilpainting so thoroughly besmoked, and every way defaced, that in the unequal crosslights by which you viewed it, it was only by diligent study and a series of systematic visitings of the spot, that you could arrive at any sort of understanding of its meaning."
                    ])
                ]
            ),
            Spec(
                title: "Don Quijote de la Mancha",
                author: "Miguel de Cervantes",
                language: "es",
                description: "Las aventuras del ingenioso hidalgo y su escudero.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Capítulo I", paragraphs: [
                        "En un lugar de la Mancha, de cuyo nombre no quiero acordarme, no ha mucho tiempo que vivía un hidalgo de los de lanza en astillero, adarga antigua, rocín flaco y galgo corredor.",
                        "Una olla de algo más vaca que carnero, salpicón las más noches, duelos y quebrantos los sábados, lantejas los viernes, algún palomino de añadidura los domingos, consumían las tres partes de su hacienda.",
                        "Frisaba la edad de nuestro hidalgo con los cincuenta años; era de complexión recia, seco de carnes, enjuto de rostro, gran madrugador y amigo de la caza."
                    ]),
                    Chapter(title: "Capítulo II", paragraphs: [
                        "Hechas estas reflexiones, quiso poner luego en ejecución lo que deseaba, dando principio a la orden de caballería que había de profesar.",
                        "Y así, sin dar parte a persona alguna de su intención, se levantó un día antes del amanecer y se puso a caminar por el campo."
                    ])
                ]
            ),
            Spec(
                title: "Meditations",
                author: "Marcus Aurelius",
                language: "en",
                description: "Notes to himself on duty, discipline and the good life.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Book I", paragraphs: [
                        "From my grandfather Verus I learned good morals and the government of my temper.",
                        "From my father, modesty and a manly character.",
                        "From my mother, piety and beneficence, and abstinence, not only from evil deeds, but even from evil thoughts."
                    ]),
                    Chapter(title: "Book II", paragraphs: [
                        "Begin the morning by saying to thyself, I shall meet with the busy-body, the ungrateful, arrogant, deceitful, envious, unsocial.",
                        "All these things happen to them by reason of their ignorance of what is good and evil. But I who have seen the nature of the good that it is beautiful, and of the bad that it is ugly, can neither be injured by any of them, nor be angry with my kinsman, nor hate him."
                    ])
                ]
            ),
            Spec(
                title: "Walden",
                author: "Henry David Thoreau",
                language: "en",
                description: "Life in the woods at Walden Pond.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Economy", paragraphs: [
                        "When I wrote the following pages, or rather the bulk of them, I lived alone, in the woods, a mile from any neighbor, in a house which I had built myself, on the shore of Walden Pond, in Concord, Massachusetts, and earned my living by the labor of my hands only.",
                        "I lived there two years and two months. At present I am a sojourner in civilized life again."
                    ]),
                    Chapter(title: "Where I Lived, and What I Lived For", paragraphs: [
                        "I went to the woods because I wished to live deliberately, to front only the essential facts of life, and see if I could not learn what it had to teach, and not, when I came to die, discover that I had not lived.",
                        "I did not wish to live what was not life, living is so dear; nor did I wish to practise resignation, unless it was quite necessary."
                    ])
                ]
            ),
            Spec(
                title: "The Odyssey",
                author: "Homer",
                language: "en",
                description: "The long voyage home from Troy.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Book I", paragraphs: [
                        "Tell me, O muse, of that ingenious hero who travelled far and wide after he had sacked the famous town of Troy.",
                        "Many cities did he visit, and many were the nations with whose manners and customs he was acquainted; moreover he suffered much by sea while trying to save his own life and bring his men safely home."
                    ]),
                    Chapter(title: "Book II", paragraphs: [
                        "Now when the child of morning, rosy-fingered Dawn, appeared, Telemachus rose and dressed himself.",
                        "He bound his sandals on to his comely feet, girded his sword about his shoulder, and left his room looking like an immortal god."
                    ])
                ]
            ),
            Spec(
                title: "Middlemarch",
                author: "George Eliot",
                language: "en",
                description: "A study of provincial life.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Prelude", paragraphs: [
                        "Who that cares much to know the history of man, and how the mysterious mixture behaves under the varying experiments of Time, has not dwelt, at least briefly, on the life of Saint Theresa?",
                        "Many Theresas have been born who found for themselves no epic life wherein there was a constant unfolding of far-resonant action."
                    ]),
                    Chapter(title: "Chapter I", paragraphs: [
                        "Miss Brooke had that kind of beauty which seems to be thrown into relief by poor dress.",
                        "Her hand and wrist were so finely formed that she could wear sleeves not less bare of style than those in which the Blessed Virgin appeared to Italian painters."
                    ])
                ]
            ),
            Spec(
                title: "Homage to Catalonia",
                author: "George Orwell",
                language: "en",
                description: "Sample chapter prepared for interface testing.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Chapter I", paragraphs: [
                        "In the Lenin Barracks in Barcelona, the day before I joined the militia, I saw an Italian militiaman standing in front of the officers’ table.",
                        "This sample document contains original placeholder prose built for testing Nodus Reader’s layout, narration and annotations. It is not an excerpt from the published book."
                    ]),
                    Chapter(title: "Chapter II", paragraphs: [
                        "The barracks were full of the noise of men cleaning rifles and arguing about the coming offensive.",
                        "A cold wind came through the windows, and the whole city seemed to be waiting."
                    ])
                ]
            ),
            Spec(
                title: "The Spanish Civil War",
                author: "Hugh Thomas",
                language: "en",
                description: "Sample chapter prepared for interface testing.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Chapter I", paragraphs: [
                        "The war began with a military rising that failed in the great cities and succeeded in much of the countryside.",
                        "This sample document contains original placeholder prose built for testing Nodus Reader’s library, collections and PDF workflows."
                    ])
                ]
            ),
            Spec(
                title: "The Spanish Labyrinth",
                author: "Gerald Brenan",
                language: "en",
                description: "Sample chapter prepared for interface testing.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Chapter I", paragraphs: [
                        "To understand Spain one must begin with the land: the high meseta, the dry rivers and the long roads between villages.",
                        "This sample document contains original placeholder prose built for testing Nodus Reader."
                    ])
                ]
            ),
            Spec(
                title: "Journey to the Alcarria",
                author: "Camilo José Cela",
                language: "en",
                description: "Sample chapter prepared for interface testing.",
                asPDF: false,
                chapters: [
                    Chapter(title: "Chapter I", paragraphs: [
                        "The road leaves the city and climbs slowly between fields of wheat and stone walls.",
                        "This sample document contains original placeholder prose built for testing Nodus Reader."
                    ])
                ]
            ),
            Spec(
                title: "Experiments in Plant Hybridization",
                author: "Gregor Mendel",
                language: "en",
                description: "The paper that founded modern genetics.",
                asPDF: true,
                chapters: [
                    Chapter(title: "Introduction", paragraphs: [
                        "The interest taken in the hybridisation of plants has increased in a remarkable manner during the last few years. The experiments which are now described were undertaken with the object of following the development of the hybrids in their progeny.",
                        "It is not easy to determine with certainty the number of experiments that have been made; but it may be stated that the results obtained were in all cases consistent with the principles here developed.",
                        "The paper is presented as a sample PDF for Nodus Reader. It preserves the original reading order, page navigation and extraction path used by the app."
                    ]),
                    Chapter(title: "Selection of Experimental Plants", paragraphs: [
                        "The value and utility of any experiment are determined by the fitness of the material to the purpose for which it is used.",
                        "The experiments were made with peas. The choice of this plant was determined by the circumstance that its flowers are normally self-fertilising, and that the hybrids are perfectly fertile.",
                        "Several distinct forms of peas were selected for the experiments, and their differences were followed through successive generations."
                    ]),
                    Chapter(title: "Division of the Experiments", paragraphs: [
                        "The experiments were divided into several groups, according to the characters which were followed.",
                        "The first group dealt with the form of the seed, the second with the colour of the albumen, the third with the colour of the seed-coat.",
                        "The results showed a regular numerical relation in the distribution of the characters in the offspring."
                    ])
                ]
            ),
            Spec(
                title: "On the Origin of Species",
                author: "Charles Darwin",
                language: "en",
                description: "The origin of species by means of natural selection.",
                asPDF: true,
                chapters: [
                    Chapter(title: "Introduction", paragraphs: [
                        "When on board H.M.S. Beagle, as naturalist, I was much struck with certain facts in the distribution of the inhabitants of South America, and in the geological relations of the present to the past inhabitants of that continent.",
                        "These facts seemed to me to throw some light on the origin of species—that mystery of mysteries, as it has been called by one of our greatest philosophers.",
                        "This sample PDF is used to exercise Nodus Reader’s PDF import, page thumbnails and reading progress."
                    ]),
                    Chapter(title: "Variation under Domestication", paragraphs: [
                        "The large number of cultivated plants and animals, and their great differences from their wild prototypes, have long attracted attention.",
                        "The most important point is that the accumulated effects of selection, whether methodical or unconscious, have produced the wonderful results which we see.",
                        "The subject is presented here in a short sample document for interface testing."
                    ]),
                    Chapter(title: "Struggle for Existence", paragraphs: [
                        "Nothing is easier than to admit in words the truth of the universal struggle for life, or more difficult—at least I have found it so—than constantly to bear this conclusion in mind.",
                        "Yet unless it be thoroughly engrained in the mind, the whole economy of nature will be dimly seen or quite misunderstood.",
                        "The struggle for existence follows from the high rate at which all organic beings tend to increase."
                    ])
                ]
            )
        ]
    }
}
#endif
