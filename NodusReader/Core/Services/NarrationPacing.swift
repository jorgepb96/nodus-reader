// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation

/// How narration moves from one sentence to the next (Settings › Voices &
/// Models › Narration pace). Natural, the default, keeps the silence each voice
/// leaves around its sentences: in a blind test it was preferred to a tighter
/// rhythm. Brisk is for readers who want that tighter rhythm.
public enum NarrationPace: String, CaseIterable, Identifiable, Sendable {
    case natural
    case brisk

    static let preferenceKey = "nodus.narration.pace"

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: String(localized: "Natural")
        case .brisk: String(localized: "Brisk")
        }
    }

    /// Very short sentences are spoken together with a neighbour.
    var joinsShortSentences: Bool { self == .brisk }
}

/// The rules behind the Brisk pace: which sentences are spoken together, how
/// much of each voice's own silence is kept and the pause punctuation asks for.
enum NarrationPacing {
    /// A sentence of this many words or fewer ("No one answered.") is spoken
    /// with the next one, or with the previous one when it ends its paragraph,
    /// so it keeps the intonation of what surrounds it.
    static let shortSentenceWords = 5
    static let maximumJoinedLength = 240

    /// Sentence ranges with each very short sentence joined to a neighbour in
    /// the same paragraph. The joined range covers both sentences and the
    /// space between them, so the reader still highlights the original text.
    static func joiningShortSentences(_ ranges: [NSRange], in text: NSString) -> [NSRange] {
        func isShort(_ range: NSRange) -> Bool {
            text.substring(with: range).split(whereSeparator: \.isWhitespace).count <= shortSentenceWords
        }
        func sameParagraph(_ first: NSRange, _ second: NSRange) -> Bool {
            let start = NSMaxRange(first)
            guard second.location >= start else { return false }
            let gap = text.substring(with: NSRange(location: start, length: second.location - start))
            return !gap.contains(where: \.isNewline)
        }
        func joined(_ first: NSRange, _ second: NSRange) -> NSRange? {
            let union = NSRange(location: first.location, length: NSMaxRange(second) - first.location)
            return sameParagraph(first, second) && union.length <= maximumJoinedLength ? union : nil
        }

        var result: [NSRange] = []
        var index = 0
        while index < ranges.count {
            let range = ranges[index]
            if isShort(range), index + 1 < ranges.count, let union = joined(range, ranges[index + 1]) {
                result.append(union)
                index += 2
                continue
            }
            if isShort(range), let previous = result.last, let union = joined(previous, range) {
                result[result.count - 1] = union
            } else {
                result.append(range)
            }
            index += 1
        }
        return result
    }

    /// The pause a reader leaves after this punctuation, a little more when
    /// the dialogue changes speaker and most at a new paragraph.
    static func pause(after current: String, before next: String, newParagraph: Bool) -> TimeInterval {
        if newParagraph { return 0.55 }
        let closers: Set<Character> = ["\u{201D}", "\u{2019}", "\u{BB}", "\"", "'", ")", "]"]
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsInQuote = trimmed.last.map { closers.contains($0) } ?? false
        let core = String(trimmed.reversed().drop { closers.contains($0) }.reversed())
        var pause: TimeInterval
        if core.hasSuffix("\u{2026}") || core.hasSuffix("...") { pause = 0.50 }
        else if core.hasSuffix("?") { pause = 0.38 }
        else if core.hasSuffix("!") { pause = 0.36 }
        else if core.hasSuffix(":") || core.hasSuffix(";") { pause = 0.25 }
        else if core.hasSuffix(",") { pause = 0.18 }
        else { pause = 0.30 }
        let opensQuote = next.trimmingCharacters(in: .whitespacesAndNewlines).first
            .map { "\u{201C}\u{AB}\"".contains($0) } ?? false
        if endsInQuote && opensQuote { pause += 0.10 }
        return pause
    }

    /// Where the voice starts and stops in a sentence's audio, in seconds,
    /// with 40 ms before it and 80 ms after it (the last word decays). Speech
    /// is any 10 ms frame louder than −34 dB below the peak, and above a floor
    /// for near-silent output. The whole buffer when nothing is that loud.
    static func speechBounds(of buffer: AVAudioPCMBuffer) -> (start: TimeInterval, end: TimeInterval) {
        let rate = buffer.format.sampleRate
        let count = Int(buffer.frameLength)
        let whole = (start: 0.0, end: Double(count) / max(rate, 1))
        guard count > 0, rate > 0, let channel = buffer.floatChannelData?[0] else { return whole }
        let frame = max(1, Int(rate * 0.010))
        var peak: Float = 0
        for index in 0..<count { peak = max(peak, abs(channel[index])) }
        let threshold = max(peak * 0.02, 0.003)
        var first: Int?
        var last: Int?
        var start = 0
        while start < count {
            let end = min(start + frame, count)
            var energy: Float = 0
            for index in start..<end { energy += channel[index] * channel[index] }
            if (energy / Float(end - start)).squareRoot() > threshold {
                if first == nil { first = start }
                last = end
            }
            start = end
        }
        guard let first, let last else { return whole }
        let lead = max(0, first - Int(rate * 0.040))
        let tail = min(count, last + Int(rate * 0.080))
        return (Double(lead) / rate, Double(tail) / rate)
    }
}
