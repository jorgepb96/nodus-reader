// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Previously in…" recaps and a character list built only from the text before
/// the reader's position, with Apple Intelligence's on-device model. Nothing is
/// sent anywhere: `SystemLanguageModel` runs on the device, and the private
/// cloud model is never used.
///
/// The model reads about 4,000 tokens at a time, so the read text is cut into
/// passages of `StoryText.passageLength` characters, each summarised once and
/// cached. A recap combines the most recent passages with a sample of earlier
/// ones; characters are found with NaturalLanguage's name tagger (fast, no
/// model) and described from excerpts that mention them.
/// The text is an immutable NSString, read but never changed, so sharing it
/// across tasks is safe; UTF-16 offsets match the reader's.
public struct StoryText: @unchecked Sendable {
    public static let passageLength = 6_000
    /// A passage ends at a paragraph break when one is this close to its end.
    static let boundarySlack = 1_500

    public let text: NSString
    /// UTF-16 offset of each chapter in `text`.
    public let chapterStarts: [Int]
    /// Where the story begins: after the licence, contents, prefaces and
    /// other front matter, which often give away the plot.
    public let storyStart: Int
    /// Where it ends: before a Project Gutenberg licence, or the end.
    public let storyEnd: Int
    /// Start offsets of the passages; passage `i` is `starts[i]..<starts[i + 1]`.
    public let passageStarts: [Int]

    /// `titles` are the chapters' titles where the reader keeps headings
    /// apart from the text; a first chapter is then found by its title.
    public init(chapters: [String], titles: [String] = []) {
        var starts: [Int] = []
        var location = 0
        for (index, chapter) in chapters.enumerated() {
            if index > 0 { location += 2 }
            starts.append(location)
            location += (chapter as NSString).length
        }
        let joined = chapters.joined(separator: "\n\n") as NSString
        text = joined
        chapterStarts = starts
        storyStart = Self.firstChapterByTitle(titles: titles, chapters: chapters, starts: starts,
                                              within: joined.length / 3)
            ?? Self.storyStart(in: joined)
        let marker = joined.range(of: "*** END OF", options: [.caseInsensitive, .backwards])
        storyEnd = marker.location != NSNotFound && marker.location > storyStart ? marker.location : joined.length
        passageStarts = Self.boundaries(in: joined, from: storyStart, to: storyEnd)
    }

    public var length: Int { text.length }

    public func offset(chapter: Int, characterOffset: Int) -> Int {
        guard chapterStarts.indices.contains(chapter) else { return chapter < 0 ? 0 : length }
        let end = chapterStarts.indices.contains(chapter + 1) ? chapterStarts[chapter + 1] - 2 : length
        return min(chapterStarts[chapter] + max(characterOffset, 0), end)
    }

    public func location(of offset: Int) -> (chapter: Int, characterOffset: Int) {
        let chapter = max((chapterStarts.lastIndex { $0 <= offset }) ?? 0, 0)
        return (chapter, offset - (chapterStarts.indices.contains(chapter) ? chapterStarts[chapter] : 0))
    }

    func passageRange(_ index: Int) -> NSRange {
        let start = passageStarts[index]
        let end = passageStarts.indices.contains(index + 1) ? passageStarts[index + 1] : storyEnd
        return NSRange(location: start, length: end - start)
    }

    /// Passages that end at or before `offset`.
    func completePassages(before offset: Int) -> Int {
        var count = 0
        while count < passageStarts.count, NSMaxRange(passageRange(count)) <= offset { count += 1 }
        return count
    }

    /// The first chapter in the first third of the book titled like a first
    /// chapter ("Chapter 1", "Capítulo primero", "I") and opening with prose.
    static func firstChapterByTitle(titles: [String], chapters: [String], starts: [Int], within limit: Int) -> Int? {
        for (index, title) in titles.enumerated() where index < chapters.count && starts[index] <= limit {
            let line = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard firstChapterHeading.firstMatch(in: line, range: range)?.range == range else { continue }
            let lines = chapters[index].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(4)
            if lines.contains(where: { $0.count >= 120 }) { return starts[index] }
        }
        return nil
    }

    /// The heading of the first chapter in the first third of the book that
    /// is followed by prose, not by the short lines of a table of contents.
    /// Without one, the end of a Project Gutenberg header, or 0.
    static func storyStart(in text: NSString) -> Int {
        let head = NSRange(location: 0, length: min(text.length, max(text.length / 3, 20_000)))
        var start = 0
        let marker = text.range(of: "*** START OF", options: [.caseInsensitive], range: head)
        if marker.location != NSNotFound {
            let line = text.range(of: "\n", range: NSRange(location: NSMaxRange(marker), length: NSMaxRange(head) - NSMaxRange(marker)))
            if line.location != NSNotFound { start = NSMaxRange(line) }
        }
        let searchRange = NSRange(location: start, length: NSMaxRange(head) - start)
        for match in firstChapterHeading.matches(in: text as String, range: searchRange) {
            let after = text.substring(with: NSRange(location: NSMaxRange(match.range),
                                                     length: min(2_000, text.length - NSMaxRange(match.range))))
            // A heading is followed within a few lines (a subtitle, a
            // section number) by a paragraph; a contents entry by more entries.
            let lines = after.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(4)
            if lines.contains(where: { $0.count >= 120 }) {
                return match.range.location
            }
        }
        return start
    }

    /// "Chapter 1", "CHAPTER I.", "Capítulo primero", "-I-", "1."…
    private static let firstChapterHeading = try! NSRegularExpression(
        pattern: #"^[ \t\p{P}]*(?:(?:chapter|cap[ií]tulo|chapitre|kapitel|capitolo|book|libro|part|parte)[ \t]+(?:1|i|one|first|the first|primero|uno|premier|eins|primo)\b[^\n]{0,160}|(?:i|1)[ \t\p{P}]*)$"#,
        options: [.caseInsensitive, .anchorsMatchLines])

    private static func boundaries(in text: NSString, from storyStart: Int, to storyEnd: Int) -> [Int] {
        var result: [Int] = []
        var start = storyStart
        while start < storyEnd {
            result.append(start)
            let target = start + passageLength
            guard target < storyEnd else { break }
            let window = NSRange(location: target - boundarySlack, length: boundarySlack)
            let paragraph = text.range(of: "\n", options: .backwards, range: window)
            start = paragraph.location == NSNotFound ? target : NSMaxRange(paragraph)
        }
        return result
    }
}

/// Everything the companion has worked out for one book, saved so a recap is
/// immediate the next time. Derived data: it stays on the device. Passage
/// summaries are kept while the text is the same; the recap and descriptions
/// are written in the interface language and go when it changes.
public struct StoryCompanionCache: Codable, Sendable, Equatable {
    public static let version = 1

    public var version = StoryCompanionCache.version
    public var contentKey = ""
    public var language = ""
    /// Passage summaries, in English, by passage index; "" marks front matter.
    public var digests: [Int: String] = [:]
    public var whereYouLeftOff: StoryRecapPart?
    public var storySoFar: StoryRecapPart?
    public var descriptions: [String: StoryCharacterDescription] = [:]

    public init() {}

    public init(contentKey: String, language: String) {
        self.contentKey = contentKey
        self.language = language
    }

    /// This cache for `contentKey` in `language`: empty for other text, and
    /// without the recap and descriptions written in another language.
    public func adapted(contentKey: String, language: String) -> StoryCompanionCache {
        guard version == Self.version, self.contentKey == contentKey else {
            return StoryCompanionCache(contentKey: contentKey, language: language)
        }
        guard self.language != language else { return self }
        var adapted = StoryCompanionCache(contentKey: contentKey, language: language)
        adapted.digests = digests
        return adapted
    }
}

public struct StoryRecapPart: Codable, Sendable, Equatable {
    /// Offset in the book's text the part was written for.
    public var position: Int
    public var text: String
    public var createdAt: Date
}

public struct StoryCharacterDescription: Codable, Sendable, Equatable {
    public var position: Int
    /// nil when the model said the name is not a character (a place, a ship…).
    public var text: String?
}

public struct StoryCharacter: Identifiable, Sendable, Equatable {
    public var id: String { name }
    /// The most frequent spelling.
    public var name: String
    public var variants: [String]
    public var mentions: Int
    /// Offsets of the mentions in the book's text, in reading order.
    public var occurrences: [Int]
    public var firstOffset: Int { occurrences.first ?? 0 }
}

public enum StoryCompanionError: Error, Equatable {
    case notEnoughText
    case unavailable
    case unsupportedLanguage
    case blocked
}

/// Finds the people named in the read text with NaturalLanguage's name tagger.
public enum StoryCharacterFinder {
    public static func characters(in story: StoryText, upTo offset: Int, limit: Int = 12) -> [StoryCharacter] {
        let end = min(max(offset, 0), story.storyEnd)
        guard end > story.storyStart else { return [] }
        let read = story.text.substring(with: NSRange(location: story.storyStart, length: end - story.storyStart))
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = read
        var found: [String: [Int]] = [:]
        tagger.enumerateTags(in: read.startIndex..<read.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard tag == .personalName else { return true }
            let name = read[range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if name.count > 1, name.first?.isUppercase == true {
                found[name, default: []].append(story.storyStart + NSRange(range, in: read).location)
            }
            return true
        }
        let readText = read as NSString
        // Without the tagger's name model for this language (the Simulator
        // has none), capitalised words in mid-sentence stand in for it; the
        // model then drops those that are not people.
        let tagged = !found.isEmpty
        if !tagged {
            found = capitalisedWords(in: readText, offset: story.storyStart)
        }
        return group(found)
            .filter { $0.mentions >= 3 && !isCommonNoun($0, in: readText) }
            // Room for the places the fallback also finds.
            .prefix(tagged ? limit : limit + 4).map { $0 }
    }

    /// Runs of capitalised words not at the start of a sentence or a line,
    /// with their offsets.
    static func capitalisedWords(in text: NSString, offset: Int) -> [String: [Int]] {
        var found: [String: [Int]] = [:]
        var run: [String] = []
        var runStart = 0
        var runEnd = 0
        var sentenceStart = true
        func close() {
            // The text itself, so "Mr. Darcy" keeps its full stop.
            if !run.isEmpty {
                let name = text.substring(with: NSRange(location: runStart, length: runEnd - runStart))
                found[name, default: []].append(offset + runStart)
            }
            run = []
        }
        (text as String).enumerateSubstrings(in: (text as String).startIndex..<(text as String).endIndex,
                                             options: .byWords) { word, range, enclosing, _ in
            guard let word, let first = word.first else { return }
            let location = NSRange(range, in: text as String).location
            if first.isUppercase, !sentenceStart, word.count > 1, !(word.uppercased() == word && word.count > 3) {
                if run.isEmpty { runStart = location }
                run.append(word)
                runEnd = NSMaxRange(NSRange(range, in: text as String))
            } else {
                close()
            }
            // What follows the word decides whether the next one starts a
            // sentence; the full stop of "Mr." or "Sra." does not end one.
            let tail = (text as String)[range.upperBound..<enclosing.upperBound]
            let abbreviation = titles.contains(word.lowercased())
                && tail.trimmingCharacters(in: .whitespaces) == "."
            sentenceStart = !abbreviation && tail.contains { ".!?\n«“\"—:".contains($0) }
            if sentenceStart { close() }
        }
        close()
        return found
    }

    /// The tagger takes a capitalised "Horn", "Woe" or "Sperm Whale" for a
    /// name; written mostly in lower case, it is a word, not a person.
    static func isCommonNoun(_ character: StoryCharacter, in text: NSString) -> Bool {
        let lower = character.name.lowercased()
        guard lower != character.name else { return false }
        var count = 0
        var range = NSRange(location: 0, length: text.length)
        while count <= character.mentions {
            let found = text.range(of: lower, options: [.literal], range: range)
            guard found.location != NSNotFound else { break }
            let before = found.location > 0 ? text.character(at: found.location - 1) : 32
            let after = NSMaxRange(found) < text.length ? text.character(at: NSMaxRange(found)) : 32
            if !Self.isLetter(before), !Self.isLetter(after) { count += 1 }
            range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        return count > character.mentions
    }

    private static func isLetter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.letters.contains(scalar)
    }

    /// Courtesy titles: a name made only of these ("Mrs", "Don") is not a name.
    static let titles: Set<String> = [
        "mr", "mrs", "miss", "ms", "dr", "sir", "lady", "lord", "captain", "capt", "colonel", "father",
        "don", "doña", "d", "dña", "señor", "señora", "señorita", "sr", "sra", "srta", "fray", "padre", "tío", "tía",
        "monsieur", "madame", "mademoiselle", "mme", "mlle", "herr", "frau", "signor", "signora", "dom", "dona",
    ]

    /// Joins the spellings of one person: "don Quijote" and "Don Quijote",
    /// "Starbuck" and "Mr. Starbuck". A shorter name joins a longer one when
    /// that is the only longer name containing it that recurs; a shared surname
    /// ("Bennet", with Mr., Mrs. and Elizabeth Bennet) stays apart, and is
    /// dropped when the full names are used more than it is.
    static func group(_ found: [String: [Int]]) -> [StoryCharacter] {
        func words(_ name: String) -> [String] {
            name.lowercased().split { !$0.isLetter }.map(String.init)
        }
        // Same words, same person: merge case and punctuation variants first.
        var spellings: [String: [String]] = [:]
        for name in found.keys {
            let key = words(name)
            guard !key.isEmpty, !key.allSatisfy(titles.contains) else { continue }
            spellings[Set(key).sorted().joined(separator: " "), default: []].append(name)
        }
        let keys = Array(spellings.keys)
        let wordSets = Dictionary(uniqueKeysWithValues: keys.map { ($0, Set($0.split(separator: " ").map(String.init))) })
        let counts = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, spellings[key]!.reduce(0) { $0 + (found[$1]?.count ?? 0) })
        })

        var parent = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })
        func root(_ key: String) -> String {
            var current = key
            while let next = parent[current], next != current { current = next }
            return current
        }
        var dropped: Set<String> = []
        for key in keys {
            let own = wordSets[key]!
            // Longer names that contain this one and recur.
            let containers = keys.filter { other in
                other != key && (counts[other] ?? 0) >= 2 && wordSets[other]!.count > own.count
                    && own.isSubset(of: wordSets[other]!)
            }
            // The nearest of them: in Ahab ⊂ Captain Ahab ⊂ Old Captain Ahab,
            // Ahab joins Captain Ahab.
            let nearest = containers.filter { container in
                !containers.contains { $0 != container && wordSets[$0]!.isSubset(of: wordSets[container]!) }
            }
            let ranked = nearest.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
            if let target = ranked.first,
               ranked.count == 1 || (counts[target] ?? 0) >= 3 * (counts[ranked[1]] ?? 0) {
                // One longer name, or one far more used than the others:
                // "Sancho" with "Sancho Panza" rather than a passing
                // "Sancho Rocinante".
                parent[root(key)] = root(target)
            } else if nearest.count > 1,
                      nearest.reduce(0, { $0 + (counts[$1] ?? 0) }) > (counts[key] ?? 0) {
                dropped.insert(key)
            }
        }

        var groups: [String: [String]] = [:]
        for key in keys where !dropped.contains(key) {
            groups[root(key), default: []].append(contentsOf: spellings[key]!)
        }
        return groups.values.map { members in
            let sorted = members.sorted { (found[$0]?.count ?? 0) > (found[$1]?.count ?? 0) }
            let occurrences = members.flatMap { found[$0] ?? [] }.sorted()
            return StoryCharacter(name: sorted[0], variants: sorted, mentions: occurrences.count,
                                  occurrences: occurrences)
        }
        .sorted { $0.mentions == $1.mentions ? $0.name < $1.name : $0.mentions > $1.mentions }
    }

    /// Short excerpts around a character's mentions: the first two and the
    /// most recent ones, which say who they are now.
    static func excerpts(for character: StoryCharacter, in story: StoryText, upTo offset: Int,
                         budget: Int = 4_800) -> [String] {
        let occurrences = character.occurrences.filter { $0 < offset }
        guard !occurrences.isEmpty else { return [] }
        var picked: [Int] = Array(occurrences.prefix(2))
        let recent = occurrences.dropFirst(2).suffix(8)
        let middle = occurrences.dropFirst(2).dropLast(recent.count)
        if !middle.isEmpty { picked.append(middle[middle.startIndex + middle.count / 2]) }
        picked.append(contentsOf: recent)
        var ranges: [NSRange] = []
        for location in picked {
            let range = sentence(around: location, in: story.text, limit: offset)
            if let last = ranges.last, NSIntersectionRange(last, range).length > 0 || NSMaxRange(last) == range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        var result: [String] = []
        var total = 0
        // Keep the first mention and as many recent excerpts as fit.
        for (index, range) in ranges.enumerated().reversed() where index > 0 {
            let excerpt = clean(story.text.substring(with: range))
            guard total + excerpt.count <= budget - 400 else { break }
            result.insert(excerpt, at: 0)
            total += excerpt.count
        }
        if let first = ranges.first {
            result.insert(clean(story.text.substring(with: first)), at: 0)
        }
        return result
    }

    /// The sentence with the mention and the one before it, which often says
    /// who is speaking or acting. NLTokenizer knows "Mr." does not end one.
    private static func sentence(around location: Int, in text: NSString, limit: Int) -> NSRange {
        let window = NSRange(location: max(location - 600, 0), length: 0)
        let upper = min(location + 400, limit)
        let slice = text.substring(with: NSRange(location: window.location, length: upper - window.location))
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = slice
        let target = location - window.location
        var sentences: [NSRange] = []
        tokenizer.enumerateTokens(in: slice.startIndex..<slice.endIndex) { range, _ in
            sentences.append(NSRange(range, in: slice))
            return true
        }
        guard let hit = sentences.firstIndex(where: { NSLocationInRange(target, $0) }) else {
            return NSRange(location: max(location - 200, 0), length: min(400, limit - max(location - 200, 0)))
        }
        var range = sentences[hit]
        // The sentence before, unless it starts outside the window.
        if hit > 1 { range = NSUnionRange(sentences[hit - 1], range) }
        if range.length > 700 { range = NSIntersectionRange(range, NSRange(location: target - 350, length: 700)) }
        return NSRange(location: window.location + range.location, length: range.length)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Small text helpers for the companion, kept apart from the engine so they
/// run on any system.
enum StoryAnswers {
    /// 0..<count ordered by successive halving: count/2, count/4, 3count/4…
    static func refinementOrder(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var order: [Int] = []
        var seen = Set<Int>()
        var step = 1
        while step < count * 2 {
            for k in 0..<step {
                let index = (2 * k + 1) * count / (2 * step)
                if index < count, seen.insert(index).inserted { order.append(index) }
            }
            step *= 2
        }
        order += (0..<count).filter { !seen.contains($0) }
        return order
    }

    /// At most `count` sentences: the model sometimes writes on past the
    /// length it was asked for.
    static func firstSentences(_ text: String, _ count: Int) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var end = text.startIndex
        var taken = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            end = range.upperBound
            taken += 1
            return taken < count
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first paragraph, without Markdown emphasis, ending at
    /// the last full sentence when the length limit cut it short.
    static func plainText(_ text: String) -> String {
        // Markdown emphasis (**bold**, *italic*, __bold__) shows as symbols.
        var result = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "__", with: "")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let blank = result.range(of: "\n\n") { result = String(result[..<blank.lowerBound]) }
        result = result.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = result.last, !".!?…»”\"".contains(last),
           let stop = result.lastIndex(where: { ".!?…".contains($0) }) {
            result = String(result[...stop])
        }
        return result
    }
}

#if canImport(FoundationModels)
/// Runs the on-device model. One request at a time: the system model refuses
/// concurrent requests from the same app.
@available(iOS 26.0, macOS 26.0, *)
public actor StoryCompanionEngine {
    public enum Availability: Equatable, Sendable {
        case available
        case deviceNotEligible
        case notEnabled
        case notReady
    }

    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable: return .notReady
        }
    }

    /// Whether the model reads and writes `languageCode` (for example "es").
    public static func supports(languageCode: String) -> Bool {
        let code = Locale.Language(identifier: languageCode).languageCode
        return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode == code }
    }

    /// Recaps need at least this much read text.
    public static let minimumReadLength = 2_000
    /// Stretches of the book the story so far is written from; at most half
    /// of them are summarised on demand.
    static let storyNotes = 16
    /// A saved part is reused until the reader moves this far.
    static let reuseDistance = StoryText.passageLength / 2

    let story: StoryText
    /// English name of the language recaps are written in ("Spanish").
    let outputLanguage: String
    public private(set) var cache: StoryCompanionCache
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    public init(story: StoryText, outputLanguageCode: String, cache: StoryCompanionCache) {
        self.story = story
        self.outputLanguage = Locale(identifier: "en").localizedString(forLanguageCode: outputLanguageCode) ?? "English"
        self.cache = cache
    }

    // MARK: Recap

    /// Two or three sentences on the last pages before `offset`.
    public func whereYouLeftOff(upTo offset: Int) async throws -> StoryRecapPart {
        let end = try readEnd(offset)
        if let saved = cache.whereYouLeftOff, abs(saved.position - end) < Self.reuseDistance { return saved }
        let complete = story.completePassages(before: end)
        let tailStart = complete > 0 ? NSMaxRange(story.passageRange(complete - 1)) : story.storyStart
        var notes: [String] = []
        // The passage before the unfinished one, and the unfinished one when
        // there is enough of it; two whole passages otherwise.
        let longTail = end - tailStart >= 1_200 || complete == 0
        for index in max(complete - (longTail ? 1 : 2), 0)..<complete {
            if let digest = try await digest(passage: index), !digest.isEmpty { notes.append(digest) }
        }
        if longTail, let digest = try await summarize(story.text.substring(with: NSRange(location: tailStart, length: end - tailStart))),
           !digest.isEmpty {
            notes.append(digest)
        }
        guard !notes.isEmpty else { throw StoryCompanionError.notEnoughText }
        let text = try await write(
            notes: notes,
            task: "In two or three sentences, remind the reader where they left off: what was happening at the end and who was involved.",
            sentences: 3)
        let part = StoryRecapPart(position: end, text: text, createdAt: Date())
        cache.whereYouLeftOff = part
        return part
    }

    /// Three or four sentences on the story before the last pages, or nil
    /// when the reader is still near the beginning. `progress` reports the
    /// passages summarised so far out of those needed.
    public func storySoFar(upTo offset: Int,
                           progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> StoryRecapPart? {
        let end = try readEnd(offset)
        if let saved = cache.storySoFar, abs(saved.position - end) < Self.reuseDistance { return saved }
        // Everything before the passages "where you left off" covers.
        let earlier = max(story.completePassages(before: end) - 2, 0)
        guard earlier >= 2 else { return nil }
        let needed = notesIndices(before: earlier)
        var notes: [String] = []
        for (done, index) in needed.enumerated() {
            progress(done, needed.count)
            if let digest = try await digest(passage: index), !digest.isEmpty { notes.append(digest) }
        }
        progress(needed.count, needed.count)
        guard notes.count >= 2 else { return nil }
        let text = try await write(
            notes: notes,
            task: "The notes come from points spread evenly through the book. In four sentences, recount the story so far for a reader returning to it: who the main people are, what they want and the key events. Give one sentence to how it began and the rest to the later notes, which lead to where the reader is now. Leave out notes that do not belong to the main thread, such as quotations or digressions.",
            sentences: 4)
        let part = StoryRecapPart(position: end, text: text, createdAt: Date())
        cache.storySoFar = part
        return part
    }

    /// Passage indices the story so far is written from, spread evenly over
    /// the book: `storyNotes` stretches, each giving a summary already made;
    /// every other stretch without one gets a summary made now, so no long
    /// part of the book is missing however few were prepared.
    func notesIndices(before count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > Self.storyNotes else { return Array(0..<count) }
        var chosen: [Int] = []
        for bucket in 0..<Self.storyNotes {
            let lower = bucket * count / Self.storyNotes
            let upper = (bucket + 1) * count / Self.storyNotes
            let middle = (lower + upper) / 2
            let made = (lower..<upper).filter { cache.digests[$0]?.isEmpty == false }
            if let nearest = made.min(by: { abs($0 - middle) < abs($1 - middle) }) {
                chosen.append(nearest)
            } else if bucket.isMultiple(of: 2) || bucket == Self.storyNotes - 1 {
                chosen.append(middle)
            }
        }
        return chosen
    }

    /// Summarises one read passage not yet summarised, spreading out first
    /// (the middle, then the quarters…) so that a recap asked for halfway
    /// through already covers the whole book. False when there is none left.
    public func prepareNext(upTo offset: Int) async throws -> Bool {
        let count = story.completePassages(before: min(max(offset, 0), story.storyEnd))
        guard let index = StoryAnswers.refinementOrder(count).first(where: { cache.digests[$0] == nil }) else {
            return false
        }
        _ = try await digest(passage: index)
        // A declined passage is marked so the loop moves on.
        if cache.digests[index] == nil { cache.digests[index] = "" }
        return true
    }

    private func readEnd(_ offset: Int) throws -> Int {
        let end = min(max(offset, 0), story.storyEnd)
        guard end - story.storyStart >= Self.minimumReadLength else { throw StoryCompanionError.notEnoughText }
        return end
    }

    /// A passage's summary, from the cache or the model. "" is front matter.
    func digest(passage index: Int) async throws -> String? {
        if let saved = cache.digests[index] { return saved }
        let summary = try await summarize(story.text.substring(with: story.passageRange(index)))
        if let summary { cache.digests[index] = summary }
        return summary
    }

    /// nil when the model declined this passage; the recap goes on without it.
    private func summarize(_ passage: String) async throws -> String? {
        do {
            let text = try await respond(
                instructions: "You summarise passages of a book for its reader. Use only what the passage says.",
                prompt: """
                Passage:
                \(passage)

                Summarise what happens in this passage in two sentences, in English, naming the people involved. If the passage is not part of the story itself (a title page, licence, table of contents, preface by an editor, or a collection of quotations from other works), answer exactly: NONE
                """,
                limit: 140)
            return text.uppercased().hasPrefix("NONE") ? "" : text
        } catch StoryCompanionError.blocked {
            return nil
        }
    }

    private func write(notes: [String], task: String, sentences: Int) async throws -> String {
        let text = try await respond(
            instructions: "You help a reader remember a book they are reading. Use only the notes you are given and never guess what happens later.",
            prompt: """
            Notes on the book, in reading order:
            \(notes.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

            \(task) Write in \(outputLanguage), in the past tense, as plain prose. Do not mention the notes.
            """,
            limit: 260)
        return StoryAnswers.firstSentences(text, sentences)
    }

    // MARK: Characters

    /// One or two sentences on who `character` is so far, or nil when the
    /// name turned out not to be a character.
    public func describe(_ character: StoryCharacter, upTo offset: Int) async throws -> String? {
        let newMentions = { (saved: StoryCharacterDescription) in
            character.occurrences.filter { $0 > saved.position && $0 < offset }.count
        }
        if let saved = cache.descriptions[character.name], saved.position <= offset, newMentions(saved) < 5 {
            return saved.text
        }
        let excerpts = StoryCharacterFinder.excerpts(for: character, in: story, upTo: offset)
        guard !excerpts.isEmpty else { return nil }
        let names = character.variants.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        // Summaries already made that name them say who they are with whom;
        // the most recent four, before the reader's position.
        let read = story.completePassages(before: offset)
        let summaries = cache.digests.filter { index, digest in
            index < read && character.variants.contains { digest.contains($0) }
        }
        .sorted { $0.key < $1.key }.suffix(4).map(\.value)
        let context = summaries.isEmpty ? "" : """
            Summaries of earlier parts that mention them:
            \(summaries.map { "- \($0)" }.joined(separator: "\n"))

            """
        let text: String
        do {
            text = try await respond(
                instructions: "You write the character list of an e-book reader. Use only the text you are given and never guess what happens later.",
                prompt: """
                \(context)Excerpts from the book, in reading order, mentioning \(names):
                \(excerpts.map { "- \($0)" }.joined(separator: "\n"))

                Describe \(character.name) for the reader in one or two short sentences: who they are, their relationships and what they have done so far. Say only what this text states; leave out anything it does not. Write only in \(outputLanguage), translating anything you use from the summaries. Answer with the description only: no title, list or quotations. If \(character.name) is not a character in this story (for example a place, a ship, a god, or a writer or figure only cited in passing), answer exactly: NOT A CHARACTER
                """,
                limit: 90)
        } catch StoryCompanionError.blocked {
            return nil
        }
        let description = text.uppercased().contains("NOT A CHARACTER") ? nil : text
        cache.descriptions[character.name] = StoryCharacterDescription(position: offset, text: description)
        return description
    }

    // MARK: Model

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Requests take turns: a recap asked for while a passage is being
    /// prepared in the background waits for that one passage.
    private func respond(instructions: String, prompt: String, limit: Int) async throws -> String {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: limit))
            return StoryAnswers.plainText(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: throw StoryCompanionError.blocked
            case .unsupportedLanguageOrLocale: throw StoryCompanionError.unsupportedLanguage
            case .assetsUnavailable: throw StoryCompanionError.unavailable
            default: throw error
            }
        }
    }
}
#endif
