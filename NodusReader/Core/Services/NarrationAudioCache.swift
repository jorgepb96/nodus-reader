// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CryptoKit
import Foundation

/// Word timing measured from synthesized audio. Offsets are UTF-16 positions
/// inside the sentence that produced the audio.
struct NarrationWordTiming: Codable, Sendable, Equatable {
    var location: Int
    var length: Int
    var start: TimeInterval
    var end: TimeInterval
}

struct CachedNarration: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var words: [NarrationWordTiming]
    var duration: TimeInterval
}

/// Sentence-level audio produced by the neural engines. Audio is cached only
/// after it has really been synthesized, so a book's cache grows as it is read
/// and can be deleted per book or as a whole. The cache never leaves the device.
actor NarrationAudioCache {
    private let fileManager: FileManager
    private let root: URL

    /// `root` is for tests, which run in parallel and must not share (or
    /// empty) the app's cache.
    init(fileManager: FileManager = .default, root: URL? = nil) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.root = root ?? base.appendingPathComponent("NodusReader/Audio", isDirectory: true)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = self.root
        try? mutable.setResourceValues(values)
    }

    nonisolated func key(text: String, engine: String, voice: String) -> String {
        // Regenerate audio made before chunk-padding removal and edge fades.
        let digest = SHA256.hash(data: Data("v3|\(engine)|\(voice)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func bookDirectory(bookID: UUID) -> URL {
        root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    func load(bookID: UUID, key: String) -> CachedNarration? {
        let directory = bookDirectory(bookID: bookID)
        let audioURL = directory.appendingPathComponent("\(key).caf")
        let metaURL = directory.appendingPathComponent("\(key).json")
        guard fileManager.fileExists(atPath: audioURL.path),
              fileManager.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              let file = try? AVAudioFile(forReading: audioURL),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return CachedNarration(buffer: buffer, words: meta.words, duration: meta.duration)
    }

    @discardableResult
    func save(bookID: UUID, key: String, buffer: AVAudioPCMBuffer,
              words: [NarrationWordTiming]) -> Int64 {
        let directory = bookDirectory(bookID: bookID)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)

        let audioURL = directory.appendingPathComponent("\(key).caf")
        let metaURL = directory.appendingPathComponent("\(key).json")
        let temporaryAudio = directory.appendingPathComponent("\(key).tmp.caf")
        let temporaryMeta = directory.appendingPathComponent("\(key).tmp.json")
        do {
            try? fileManager.removeItem(at: temporaryAudio)
            // AAC: speech at ~20 MB per hour instead of ~350 MB as float PCM.
            // The CAF container records encoder priming, so the decoded length
            // (and the word timings) match the original. Caches written as PCM
            // by earlier builds still read the same way.
            let file = try AVAudioFile(forWriting: temporaryAudio,
                                       settings: Self.compressedSettings(for: buffer.format),
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: buffer)
            // AVAudioFile closes when this scope ends, before the rename.
        } catch {
            try? fileManager.removeItem(at: temporaryAudio)
            return 0
        }
        let duration = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        let meta = Meta(duration: duration, words: words)
        guard let data = try? JSONEncoder().encode(meta) else {
            try? fileManager.removeItem(at: temporaryAudio)
            return 0
        }
        do {
            try data.write(to: temporaryMeta, options: .atomic)
            if fileManager.fileExists(atPath: audioURL.path) {
                try fileManager.removeItem(at: audioURL)
            }
            try fileManager.moveItem(at: temporaryAudio, to: audioURL)
            if fileManager.fileExists(atPath: metaURL.path) {
                try fileManager.removeItem(at: metaURL)
            }
            try fileManager.moveItem(at: temporaryMeta, to: metaURL)
        } catch {
            try? fileManager.removeItem(at: temporaryAudio)
            try? fileManager.removeItem(at: temporaryMeta)
            return 0
        }
        let audioSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let metaSize = (try? metaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(audioSize + metaSize)
    }

    nonisolated static func compressedSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    func deleteBook(bookID: UUID) {
        try? fileManager.removeItem(at: bookDirectory(bookID: bookID))
    }

    func deleteAll() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Books with a cache folder, including books no longer in the library.
    func cachedBookIDs() -> [UUID] {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    func totalBytes() -> Int64 {
        size(of: root)
    }

    func bytes(for bookID: UUID) -> Int64 {
        size(of: bookDirectory(bookID: bookID))
    }

    func hasAudio(bookID: UUID) -> Bool {
        guard let items = try? fileManager.contentsOfDirectory(atPath: bookDirectory(bookID: bookID).path) else {
            return false
        }
        return items.contains { $0.hasSuffix(".caf") }
    }

    private func size(of directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private struct Meta: Codable {
        var duration: TimeInterval
        var words: [NarrationWordTiming]
    }
}

/// PCM finishing shared by live narration, voice previews and cached audio.
enum NarrationPCM {
    /// A model-size split between words must not sound like punctuation.
    /// Closing quotes/brackets belong to the preceding punctuation.
    static func endsClause(_ text: String) -> Bool {
        let end = text.last { !$0.isWhitespace && !"\"'”’»)]}".contains($0) }
        return end.map { ",;:.!?…—–".contains($0) } ?? false
    }

    /// Remove only the quiet model padding at artificial chunk boundaries.
    /// Real punctuation and silence inside a chunk keep their original timing.
    static func kokoroChunk(_ samples: [Float], sampleRate: Double,
                            continuesPrevious: Bool, continuesNext: Bool) -> [Float] {
        guard !samples.isEmpty, continuesPrevious || continuesNext else { return samples }
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        guard peak > 0 else { return samples }
        let threshold = max(Float(0.0002), peak * 0.005)
        let window = max(1, Int(sampleRate * 0.002))
        let margin = max(1, Int(sampleRate * 0.020))
        func isQuiet(_ range: Range<Int>) -> Bool {
            let energy = range.reduce(Float.zero) { $0 + samples[$1] * samples[$1] }
            return energy / Float(range.count) < threshold * threshold
        }
        var first = 0
        if continuesPrevious {
            while first + window <= samples.count, isQuiet(first..<(first + window)) {
                first += window
            }
        }
        var last = samples.count
        if continuesNext {
            while last - window >= first, isQuiet((last - window)..<last) {
                last -= window
            }
        }
        guard first < last else { return samples }
        return Array(samples[max(0, first - margin)..<min(samples.count, last + margin)])
    }

    /// Join adjacent chunks with a short linear crossfade, avoiding a sample
    /// discontinuity after trimming. The overlap is too short to merge words.
    static func append(_ chunk: [Float], to output: inout [Float], sampleRate: Double) {
        let overlap = min(Int(sampleRate * 0.005), output.count, chunk.count)
        if overlap > 0 {
            let start = output.count - overlap
            for index in 0..<overlap {
                let gain = Float(index + 1) / Float(overlap + 1)
                output[start + index] = output[start + index] * (1 - gain) + chunk[index] * gain
            }
        }
        output.append(contentsOf: chunk.dropFirst(overlap))
    }

    /// A fresh decoder buffer can start/end away from zero. Ramp its outer
    /// edges without changing duration or any word-alignment offsets.
    static func fadeEdges(_ samples: inout [Float], sampleRate: Double) {
        let count = min(Int(sampleRate * 0.010), samples.count / 2)
        guard count > 1 else { return }
        for index in 0..<count {
            let phase = Double(index) / Double(count - 1)
            let gain = Float(0.5 - 0.5 * cos(.pi * phase))
            samples[index] *= gain
            samples[samples.count - 1 - index] *= gain
        }
    }
}

// MARK: - Alignment

/// Estimates word timings inside one synthesized sentence by pairing silence in
/// the waveform with the words of the text. No speech recognizer is needed and
/// no word is invented: the text and the audio are the only inputs.
///
/// The algorithm is deliberately conservative. It finds pauses longer than
/// 35 ms, weights word boundaries by syllables and punctuation, then uses
/// dynamic programming to choose the pause subset that best matches those
/// expected boundaries. Missing pauses fall back to the interpolated estimate.
enum AudioWordAligner {
    struct Word {
        var range: NSRange
        var text: String
    }

    static func words(in text: String) -> [Word] {
        let ns = text as NSString
        var result: [Word] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            result.append(Word(range: range, text: ns.substring(with: range)))
        }
        return result
    }

    static func align(text: String, samples: [Float], sampleRate: Double) -> [NarrationWordTiming] {
        let words = words(in: text)
        guard !words.isEmpty, !samples.isEmpty, sampleRate > 0 else { return [] }
        let duration = Double(samples.count) / sampleRate
        if words.count == 1 {
            return [NarrationWordTiming(location: words[0].range.location,
                                        length: words[0].range.length,
                                        start: 0,
                                        end: duration)]
        }

        let pauseCandidates = detectPauses(samples: samples, sampleRate: sampleRate)
        let expected = expectedBoundaries(words: words, speechStart: pauseCandidates.speechStart,
                                          speechEnd: pauseCandidates.speechEnd)
        // Pauses are matched by their centre, but the next word starts where
        // the voice resumes: highlighting at the centre runs half a pause early
        // and makes the highlight drift against the audio.
        let onsets = Dictionary(zip(pauseCandidates.centers, pauseCandidates.onsets),
                                uniquingKeysWith: { first, _ in first })
        // Moving a boundary to the onset can carry it past the next one (an
        // interpolated boundary inside that pause), so keep them increasing.
        var lastBoundary: TimeInterval = 0
        let chosen = chooseBoundaries(expected: expected, candidates: pauseCandidates.centers)
            .map { boundary -> TimeInterval in
                let onset = onsets[boundary] ?? boundary
                lastBoundary = min(max(onset, lastBoundary + 0.02), duration)
                return lastBoundary
            }

        var timings: [NarrationWordTiming] = []
        // The first word starts where the voice does, not at the leading
        // silence (Kokoro: about 0.2 s), or the highlight runs ahead.
        var previous: TimeInterval = min(pauseCandidates.speechStart, duration)
        for (index, word) in words.enumerated() {
            let start = previous
            let end = index == words.count - 1 ? duration : chosen[index]
            let timing = NarrationWordTiming(location: word.range.location,
                                             length: word.range.length,
                                             start: start,
                                             end: max(end, start + 0.02))
            timings.append(timing)
            previous = timing.end
        }
        return timings
    }

    private struct Pauses {
        var centers: [TimeInterval]
        /// Where speech resumes after each pause, parallel to `centers`.
        var onsets: [TimeInterval] = []
        var speechStart: TimeInterval
        var speechEnd: TimeInterval
    }

    private static func detectPauses(samples: [Float], sampleRate: Double) -> Pauses {
        let frame = max(1, Int(sampleRate * 0.02))
        var rms: [Float] = []
        rms.reserveCapacity(samples.count / frame + 1)
        var peak: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            var sum: Float = 0
            for value in samples[index..<end] { sum += value * value }
            let value = sqrt(sum / Float(max(end - index, 1)))
            peak = max(peak, value)
            rms.append(value)
            index = end
        }
        let threshold = max(0.004, peak * 0.06)
        let firstSpeech = rms.firstIndex { $0 > threshold }
        let lastSpeech = rms.lastIndex { $0 > threshold }
        guard let firstSpeech, let lastSpeech, lastSpeech > firstSpeech else {
            return Pauses(centers: [], speechStart: 0, speechEnd: Double(samples.count) / sampleRate)
        }

        var centers: [TimeInterval] = []
        var onsets: [TimeInterval] = []
        var runStart: Int?
        for frameIndex in firstSpeech...lastSpeech {
            let silent = rms[frameIndex] <= threshold
            if silent, runStart == nil {
                runStart = frameIndex
            } else if !silent, let start = runStart {
                appendPause(start: start, end: frameIndex, frame: frame, sampleRate: sampleRate,
                            centers: &centers, onsets: &onsets)
                runStart = nil
            }
        }
        if let start = runStart {
            appendPause(start: start, end: lastSpeech, frame: frame, sampleRate: sampleRate,
                        centers: &centers, onsets: &onsets)
        }

        return Pauses(centers: centers,
                      onsets: onsets,
                      speechStart: Double(firstSpeech * frame) / sampleRate,
                      speechEnd: Double(min((lastSpeech + 1) * frame, samples.count)) / sampleRate)
    }

    private static func appendPause(start: Int, end: Int, frame: Int, sampleRate: Double,
                                    centers: inout [TimeInterval], onsets: inout [TimeInterval]) {
        let seconds = Double((end - start) * frame) / sampleRate
        guard seconds >= 0.035 else { return }
        centers.append(Double(((start + end) * frame) / 2) / sampleRate)
        onsets.append(Double(end * frame) / sampleRate)
    }

    private static func expectedBoundaries(words: [Word], speechStart: TimeInterval,
                                           speechEnd: TimeInterval) -> [TimeInterval] {
        let weights = words.map(weight)
        let total = max(weights.reduce(0, +), 0.001)
        let span = max(speechEnd - speechStart, 0.05)
        var result: [TimeInterval] = []
        var cumulative: Double = 0
        for index in 0..<(words.count - 1) {
            cumulative += weights[index]
            result.append(speechStart + (cumulative / total) * span)
        }
        return result
    }

    private static func weight(_ word: Word) -> Double {
        let lower = word.text.lowercased()
        let vowels = CharacterSet(charactersIn: "aeiouyáéíóúàèìòùäëïöüâêîôûãõ")
        var syllables = 0
        var previousWasVowel = false
        for scalar in lower.unicodeScalars {
            let isVowel = vowels.contains(scalar)
            if isVowel, !previousWasVowel { syllables += 1 }
            previousWasVowel = isVowel
        }
        let base = Double(max(syllables, 1))
        let punctuation: Double
        if word.text.hasSuffix(".") || word.text.hasSuffix("!") || word.text.hasSuffix("?") {
            punctuation = 1.2
        } else if word.text.hasSuffix(",") || word.text.hasSuffix(";") || word.text.hasSuffix(":") {
            punctuation = 0.55
        } else {
            punctuation = 0
        }
        return base + punctuation
    }

    private static func chooseBoundaries(expected: [TimeInterval],
                                         candidates: [TimeInterval]) -> [TimeInterval] {
        guard !expected.isEmpty else { return [] }
        guard candidates.count >= expected.count else {
            return snap(expected: expected, candidates: candidates)
        }

        let n = expected.count
        let m = candidates.count
        var cost = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: m + 1)
        var take = Array(repeating: Array(repeating: false, count: n + 1), count: m + 1)
        for i in 0...m { cost[i][0] = 0 }
        for i in 1...m {
            for j in 1...min(i, n) {
                let skip = cost[i - 1][j]
                let use = cost[i - 1][j - 1] + abs(candidates[i - 1] - expected[j - 1])
                if use <= skip {
                    cost[i][j] = use
                    take[i][j] = true
                } else {
                    cost[i][j] = skip
                }
            }
        }

        var result: [TimeInterval] = []
        var j = n
        var i = m
        while j > 0, i > 0 {
            if take[i][j] {
                result.append(candidates[i - 1])
                j -= 1
            }
            i -= 1
        }
        return result.reversed()
    }

    private static func snap(expected: [TimeInterval],
                             candidates: [TimeInterval]) -> [TimeInterval] {
        guard !candidates.isEmpty else { return expected }
        var result: [TimeInterval] = []
        var last: TimeInterval = 0
        for value in expected {
            let nearest = candidates.min { abs($0 - value) < abs($1 - value) } ?? value
            let snapped = abs(nearest - value) <= 0.22 ? max(nearest, last + 0.02) : value
            result.append(snapped)
            last = snapped
        }
        return result
    }
}
