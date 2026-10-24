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

struct CachedNarration: Sendable {
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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.root = base.appendingPathComponent("NodusReader/Audio", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = self.root
        try? mutable.setResourceValues(values)
    }

    nonisolated func key(text: String, engine: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(engine)|\(voice)|\(text)".utf8))
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
        do {
            let file = try AVAudioFile(forWriting: audioURL,
                                       settings: buffer.format.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: buffer)
        } catch {
            return 0
        }
        let duration = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        let meta = Meta(duration: duration, words: words)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
        }
        let audioSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let metaSize = (try? directory.appendingPathComponent("\(key).json")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(audioSize + metaSize)
    }

    func deleteBook(bookID: UUID) {
        try? fileManager.removeItem(at: bookDirectory(bookID: bookID))
    }

    func deleteAll() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
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
        let chosen = chooseBoundaries(expected: expected, candidates: pauseCandidates.centers)

        var timings: [NarrationWordTiming] = []
        var previous: TimeInterval = 0
        for (index, word) in words.enumerated() {
            let start = index == 0 ? 0 : previous
            let end = index == words.count - 1 ? duration : chosen[index]
            timings.append(NarrationWordTiming(location: word.range.location,
                                               length: word.range.length,
                                               start: start,
                                               end: max(end, start + 0.02)))
            previous = end
        }
        return timings
    }

    private struct Pauses {
        var centers: [TimeInterval]
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
        var runStart: Int?
        for frameIndex in firstSpeech...lastSpeech {
            let silent = rms[frameIndex] <= threshold
            if silent, runStart == nil {
                runStart = frameIndex
            } else if !silent, let start = runStart {
                appendPause(start: start, end: frameIndex, frame: frame, sampleRate: sampleRate, to: &centers)
                runStart = nil
            }
        }
        if let start = runStart {
            appendPause(start: start, end: lastSpeech, frame: frame, sampleRate: sampleRate, to: &centers)
        }

        return Pauses(centers: centers,
                      speechStart: Double(firstSpeech * frame) / sampleRate,
                      speechEnd: Double(min((lastSpeech + 1) * frame, samples.count)) / sampleRate)
    }

    private static func appendPause(start: Int, end: Int, frame: Int, sampleRate: Double,
                                    to centers: inout [TimeInterval]) {
        let seconds = Double((end - start) * frame) / sampleRate
        guard seconds >= 0.035 else { return }
        centers.append(Double(((start + end) * frame) / 2) / sampleRate)
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
