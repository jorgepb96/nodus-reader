// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation

/// What on-device analysis read in one window of text. Every value comes from
/// the normalised vocabulary; the two ordinals (0…3) are the model's own
/// coarse ratings, never probabilities.
struct SceneReading: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        /// `SystemLanguageModel(useCase: .contentTagging)`, structured output.
        case contentTagging
        /// The general model with permissive guardrails and a line format,
        /// used only when the first refused the passage.
        case generalFallback
    }

    var passageKind: PassageKind
    var setting: SceneSetting
    /// How clearly the place is established (0 none … 3 explicit).
    var settingClarity: Int
    var weather: SceneWeather
    var tone: SceneTone
    var action: SceneAction
    /// How intense the passage is (0 still … 3 climactic).
    var intensity: Int
    var sceneChange: SceneChange
    /// A short phrase the model quoted from the passage as its evidence.
    var evidence: String
    /// Whether `evidence` really occurs in the passage (checked, not trusted).
    var evidenceVerified: Bool
    var source: Source
}

/// A stretch of the book analysed as one unit: a few paragraphs, never
/// crossing a chapter start. Offsets are UTF-16, in `StoryText` coordinates.
struct SceneWindow: Codable, Hashable, Sendable {
    let index: Int
    let start: Int
    let end: Int
    let chapter: Int
    let startsChapter: Bool
    /// The window opens right after a scene-break line ("* * *", "#").
    let startsAfterSceneBreak: Bool

    var length: Int { end - start }
    func contains(_ offset: Int) -> Bool { offset >= start && offset < end }
}

enum WindowStatus: Codable, Hashable, Sendable {
    case analysed(SceneReading)
    /// The model refused the passage (both paths): no evidence either way.
    case declined
    case failed(String)

    var reading: SceneReading? {
        if case .analysed(let reading) = self { return reading }
        return nil
    }
}

/// The book-level decision: what kind of document this is, and how.
struct DocumentProfile: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case model
        /// No model: observable signals only (dialogue, citations, headings).
        case heuristics
    }

    var kind: DocumentKind
    var source: Source
    /// The model's answer for each sample, in order.
    var votes: [DocumentKind]
    var signals: TextSignals
}

/// Observable properties of a sample of text. Counts and ratios, nothing
/// inferred: they are combined with the model's votes, never presented as
/// a confidence.
struct TextSignals: Codable, Hashable, Sendable {
    /// Paragraphs that open with a quotation mark or a dialogue dash.
    var dialogueRatio: Double
    /// Citation-like markers ("[12]", "et al.", "(2019)", "Fig.") per 1,000 characters.
    var citationDensity: Double
    /// Short heading-like lines ("3.2 Results") per paragraph.
    var headingRatio: Double

    static let empty = TextSignals(dialogueRatio: 0, citationDensity: 0, headingRatio: 0)

    static func measure(_ text: String) -> TextSignals {
        let paragraphs = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return .empty }
        let openers: Set<Character> = ["\"", "“", "«", "—", "–", "‘", "'"]
        let dialogue = paragraphs.filter { $0.first.map(openers.contains) ?? false }.count
        let headings = paragraphs.filter { line in
            line.count < 60 && line.range(of: #"^\d+(\.\d+)+\s+\S"#, options: .regularExpression) != nil
        }.count
        let ns = text as NSString
        let citations = citationPattern.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
        return TextSignals(
            dialogueRatio: Double(dialogue) / Double(paragraphs.count),
            citationDensity: Double(citations) * 1_000 / Double(max(ns.length, 1)),
            headingRatio: Double(headings) / Double(paragraphs.count))
    }

    /// The document kind these signals alone point to; nil when they do not.
    var suggestedKind: DocumentKind? {
        if citationDensity >= 1.0 || headingRatio >= 0.15 { return .academic }
        if dialogueRatio >= 0.12 { return .fiction }
        return nil
    }

    private static let citationPattern = try! NSRegularExpression(
        pattern: #"\[\d{1,3}(?:[,–-]\d{1,3})*\]|\bet al\.|\(\d{4}[a-z]?\)|\b(?:Fig|Tab|Eq)\.\s*\d"#)
}

extension DocumentProfile {
    /// The kind from the model's votes (majority; ties go to the less
    /// dramatic kind), checked against the observable signals. Without votes,
    /// the signals decide; without either, the book is treated as `other`.
    static func resolve(votes: [DocumentKind], signals: TextSignals) -> DocumentProfile {
        guard !votes.isEmpty else {
            return DocumentProfile(kind: signals.suggestedKind ?? .other, source: .heuristics,
                                   votes: [], signals: signals)
        }
        var counts: [DocumentKind: Int] = [:]
        for vote in votes { counts[vote, default: 0] += 1 }
        let best = counts.values.max() ?? 0
        // Order of caution: a tie between fiction and non-fiction keeps the
        // steadier non-fiction atmosphere.
        let caution: [DocumentKind] = [.academic, .reference, .manual, .essay, .narrativeNonfiction,
                                       .poetry, .drama, .fiction, .other]
        var kind = caution.first { counts[$0] == best } ?? .other
        // Heavy citation apparatus outweighs a "fiction" vote.
        if kind == .fiction, signals.suggestedKind == .academic { kind = .narrativeNonfiction }
        return DocumentProfile(kind: kind, source: .model, votes: votes, signals: signals)
    }
}

/// Identifies one version of a book's text: the file's hash and a hash of the
/// text as extracted. A new file, a new extractor or a new OCR pass gives a
/// new key, and the scene map is rebuilt.
enum ImmersiveContentKey {
    static func make(contentHash: String, text: NSString) -> String {
        let digest = SHA256.hash(data: Data((text as String).utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(contentHash)-\(prefix)"
    }
}

/// Scene-break lines: "* * *", "***", "#", "⁂", "~", "—", "§" alone on a line.
enum SceneBreakDetector {
    static func isBreak(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return false }
        let marks: Set<Character> = ["*", "#", "⁂", "~", "—", "–", "-", "§", "•", "·", "◆", "❦", "✦", " "]
        return trimmed.allSatisfy { marks.contains($0) }
    }

    /// Whether the text between `from` and `to` has a scene break line.
    static func containsBreak(in text: NSString, from: Int, to: Int) -> Bool {
        guard to > from, from >= 0, to <= text.length else { return false }
        let slice = text.substring(with: NSRange(location: from, length: to - from))
        return slice.split(separator: "\n").contains(where: isBreak)
    }
}

/// Cuts a book into analysis windows of about `target` characters that end at
/// paragraph breaks and never cross a chapter start.
enum SceneSegmenter {
    static let target = 3_000
    static let minimum = 1_200
    static let maximum = 4_000

    static func windows(in story: StoryText, target: Int = target, minimum: Int = minimum,
                        maximum: Int = maximum) -> [SceneWindow] {
        let text = story.text
        var result: [SceneWindow] = []
        // Chapter boundaries inside the story.
        let starts = story.chapterStarts.filter { $0 > story.storyStart && $0 < story.storyEnd }
        var spans: [(Int, Int)] = []
        var cursor = story.storyStart
        for start in starts {
            spans.append((cursor, max(cursor, start - 2)))
            cursor = start
        }
        spans.append((cursor, story.storyEnd))
        for (spanStart, spanEnd) in spans where spanEnd > spanStart {
            var start = spanStart
            var first = true
            var afterBreak = false
            while start < spanEnd {
                var end = min(start + target, spanEnd)
                if spanEnd - end < minimum {
                    // Fold a short remainder into this window if it fits.
                    end = spanEnd - start <= maximum ? spanEnd : end
                }
                if end < spanEnd {
                    let low = start + minimum
                    let window = NSRange(location: low, length: max(min(start + maximum, spanEnd) - low, 0))
                    // Prefer a scene break, then the paragraph break nearest the target.
                    end = breakEnd(in: text, range: window, near: start + target) ?? end
                }
                let chapter = story.location(of: start).chapter
                let opensChapter = first && story.chapterStarts.contains(spanStart)
                result.append(SceneWindow(index: result.count, start: start, end: end, chapter: chapter,
                                          startsChapter: opensChapter, startsAfterSceneBreak: afterBreak))
                afterBreak = endsWithSceneBreak(text, from: start, to: end)
                first = false
                start = end
            }
        }
        return result
    }

    /// The best place to end a window inside `range`: just after a scene
    /// break line, otherwise after the newline closest to `target`.
    private static func breakEnd(in text: NSString, range: NSRange, near target: Int) -> Int? {
        guard range.length > 0 else { return nil }
        let slice = text.substring(with: range) as NSString
        var best: Int?
        var bestDistance = Int.max
        var sceneBreak: Int?
        var lineStart = 0
        while lineStart < slice.length {
            let newline = slice.range(of: "\n", range: NSRange(location: lineStart, length: slice.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? slice.length : newline.location
            let line = slice.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            if newline.location != NSNotFound {
                let absolute = range.location + NSMaxRange(newline)
                if SceneBreakDetector.isBreak(Substring(line)), sceneBreak == nil { sceneBreak = absolute }
                let distance = abs(absolute - target)
                if distance < bestDistance { best = absolute; bestDistance = distance }
            }
            lineStart = lineEnd + 1
        }
        return sceneBreak ?? best
    }

    private static func endsWithSceneBreak(_ text: NSString, from: Int, to: Int) -> Bool {
        let tail = max(from, to - 40)
        let slice = text.substring(with: NSRange(location: tail, length: to - tail))
        return slice.split(separator: "\n").last.map(SceneBreakDetector.isBreak) ?? false
    }
}

/// Everything analysis has worked out for one book. Derived data: stored on
/// the device, never synced.
struct SceneMap: Codable, Sendable {
    /// Bump when prompts, windows or parsing change meaning.
    static let analyzerVersion = 1

    var analyzerVersion = SceneMap.analyzerVersion
    var vocabularyVersion = SceneVocabulary.version
    var contentKey: String
    /// The book's language the analysis was run in ("en", "es").
    var language: String
    var profile: DocumentProfile?
    var windows: [SceneWindow]
    var status: [Int: WindowStatus] = [:]
    /// The OS that produced the readings, for diagnostics only: an OS update
    /// does not change a book's atmosphere.
    var modelEpoch = ""

    func windowIndex(containing offset: Int) -> Int? {
        guard !windows.isEmpty else { return nil }
        if offset < windows[0].start { return nil }
        var low = 0
        var high = windows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offset < windows[mid].start { high = mid - 1 }
            else if offset >= windows[mid].end { low = mid + 1 }
            else { return mid }
        }
        // Between windows (a chapter gap): the window before.
        return high >= 0 ? high : nil
    }

    func reading(_ index: Int) -> SceneReading? { status[index]?.reading }

    var analysedCount: Int { status.values.filter { $0.reading != nil }.count }

    /// This map when it still describes `contentKey` in `language` with the
    /// current analyzer and vocabulary; a fresh map otherwise.
    func adapted(contentKey: String, language: String, windows: [SceneWindow]) -> SceneMap {
        guard analyzerVersion == Self.analyzerVersion, vocabularyVersion == SceneVocabulary.version,
              self.contentKey == contentKey, self.language == language, self.windows == windows else {
            return SceneMap(contentKey: contentKey, language: language, windows: windows)
        }
        return self
    }
}
