// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Speech

/// Word timings for neural narration, measured by Apple's on-device speech
/// recognition (`SpeechTranscriber`, iOS 26 / macOS 26) on the synthesized
/// sentence: each recognised word carries the time range where it is heard.
/// Recognised words are matched to the sentence's words; words it does not
/// recognise as written (numbers read out, names) are placed between their
/// matched neighbours. Measured against the pause-based estimate on Kokoro
/// Spanish: maximum error 0.24 s instead of 0.78 s. The audio never leaves the
/// device; the first time, the system may download its speech model for the
/// language.
enum SpeechWordAligner {
    static let enabledKey = "nodus.narration.preciseWordTiming"

    /// On unless the user turned it off in Voices & Models.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Longest a sentence may wait for recognition before playing with the
    /// estimate instead. Recognition normally takes 0.15–0.5 s.
    static let timeLimit: Duration = .milliseconds(2500)

    /// Timings for `text` spoken in `samples`, or nil when recognition is not
    /// available, not installed yet, too slow, or matched too few words.
    /// Narration never waits for the speech model to download: the download
    /// is requested in the background and used once it is installed.
    static func align(text: String, samples: [Float], sampleRate: Double,
                      language: String) async -> [NarrationWordTiming]? {
        guard #available(iOS 26.0, macOS 26.0, *), isEnabled, !samples.isEmpty else { return nil }
        let words = AudioWordAligner.words(in: text)
        guard words.count > 1 else { return nil }
        // Whichever comes first: the recognition or the time limit. A task
        // group would wait for a recognition that never ends; this does not.
        let recognized: [RecognizedWord]? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task.detached(priority: .userInitiated) {
                once.resume(try? await recognize(samples: samples, sampleRate: sampleRate, language: language))
            }
            Task.detached {
                try? await Task.sleep(for: timeLimit)
                work.cancel()
                once.resume(nil)
            }
        }
        guard let recognized, !recognized.isEmpty else { return nil }
        return place(words: words, recognized: recognized,
                     duration: Double(samples.count) / sampleRate)
    }

    struct RecognizedWord: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    // MARK: Matching

    /// Matches recognised words to the text's words in order (longest common
    /// subsequence of normalised words) and fills the gaps by word length.
    static func place(words: [AudioWordAligner.Word], recognized: [RecognizedWord],
                      duration: TimeInterval) -> [NarrationWordTiming]? {
        let textKeys = words.map { normalize($0.text) }
        let heardKeys = recognized.map { normalize($0.text) }
        let n = textKeys.count
        let m = heardKeys.count
        guard m > 0 else { return nil }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = !textKeys[i].isEmpty && textKeys[i] == heardKeys[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matched: [Int: RecognizedWord] = [:]
        var i = 0
        var j = 0
        while i < n, j < m {
            if !textKeys[i].isEmpty, textKeys[i] == heardKeys[j] {
                matched[i] = recognized[j]
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // Too few words heard as written: the estimate is safer.
        guard Double(matched.count) >= Double(n) * 0.5 else { return nil }

        var starts = [TimeInterval?](repeating: nil, count: n)
        var ends = [TimeInterval?](repeating: nil, count: n)
        for (index, word) in matched {
            starts[index] = word.start
            ends[index] = word.end
        }
        // Unmatched runs share the time between their matched neighbours in
        // proportion to their length.
        var index = 0
        while index < n {
            guard starts[index] == nil else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < n, starts[last + 1] == nil { last += 1 }
            let from = index > 0 ? (ends[index - 1] ?? 0) : (recognized.first.map { max(0, $0.start - 0.15) } ?? 0)
            let to = last + 1 < n ? (starts[last + 1] ?? duration) : duration
            let lengths = (index...last).map { Double(max(words[$0].text.count, 1)) }
            let total = lengths.reduce(0, +)
            var cursor = from
            for (offset, position) in (index...last).enumerated() {
                let span = max(to - from, 0) * lengths[offset] / total
                starts[position] = cursor
                ends[position] = cursor + span
                cursor += span
            }
            index = last + 1
        }

        var timings: [NarrationWordTiming] = []
        var previousStart: TimeInterval = 0
        for (position, word) in words.enumerated() {
            let start = max(starts[position] ?? previousStart, previousStart)
            // A word lasts until the next one starts (the highlight never goes
            // blank in a pause); the last one until the audio ends.
            let next = position + 1 < n ? (starts[position + 1] ?? ends[position] ?? start) : duration
            let end = min(max(next, start + 0.02), duration)
            timings.append(NarrationWordTiming(location: word.range.location, length: word.range.length,
                                               start: min(start, duration), end: max(end, min(start, duration))))
            previousStart = timings[position].start
        }
        return timings
    }

    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Resumes a continuation once; later results are dropped.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[RecognizedWord]?, Never>?

        init(_ continuation: CheckedContinuation<[RecognizedWord]?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: [RecognizedWord]?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    // MARK: Recognition

    private static let pendingInstalls = PendingInstalls()

    private final class PendingInstalls: @unchecked Sendable {
        let lock = NSLock()
        var locales: Set<String> = []
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func requestInstall(of transcriber: SpeechTranscriber, locale: Locale) {
        let key = locale.identifier(.bcp47)
        pendingInstalls.lock.lock()
        let isNew = pendingInstalls.locales.insert(key).inserted
        pendingInstalls.lock.unlock()
        guard isNew else { return }
        Task.detached(priority: .utility) {
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
            pendingInstalls.lock.lock()
            pendingInstalls.locales.remove(key)
            pendingInstalls.lock.unlock()
        }
    }

    /// The words recognized in `samples`, joined: a cloned voice's suggested
    /// transcript. Empty while the language's speech model is not installed.
    @available(iOS 26.0, macOS 26.0, *)
    static func recognizedText(samples: [Float], sampleRate: Double, language: String) async throws -> String {
        try await recognize(samples: samples, sampleRate: sampleRate, language: language)
            .map(\.text).joined(separator: " ")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func recognize(samples: [Float], sampleRate: Double,
                                  language: String) async throws -> [RecognizedWord] {
        let requested = Locale(identifier: language.replacingOccurrences(of: "_", with: "-"))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return [] }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The system's speech model for the language: requested once in the
        // background, used from the next sentence after it is installed.
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            requestInstall(of: transcriber, locale: locale)
            return []
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-align-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [RecognizedWord] in
            var words: [RecognizedWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let spoken = String(result.text[run.range].characters)
                    let parts = spoken.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard !parts.isEmpty else { continue }
                    // A run holding several words shares its time by length.
                    let start = range.start.seconds
                    let length = max(range.end.seconds - start, 0)
                    let total = Double(parts.reduce(0) { $0 + max($1.count, 1) })
                    var cursor = start
                    for part in parts {
                        let span = length * Double(max(part.count, 1)) / total
                        words.append(RecognizedWord(text: part, start: cursor, end: cursor + span))
                        cursor += span
                    }
                }
            }
            return words
        }
        let input = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: input, finishAfterFile: true)
        return try await collector.value
    }
}
