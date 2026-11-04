// ReferenceSection.swift
// GVoiceKit — the one place a long reference is cut down for an engine that
// conditions on less (docs/gvoice-format.md, "Engine sections").
//
// A voice's master (source/ref.wav + its full transcript) may be any length.
// An engine with a shorter limit does not pick a slice while it renders: the
// section is chosen ONCE, when the voice is prepared, and stored in the pack
// under that engine's folder (engines/<engine>/ref.wav plus its exact
// transcript and the span it covers). Renders only read what is stored.
//
// This file is the pure part (no frameworks, no engines): the cut, the
// transcript slice, hashes and the WAV bytes of a stored section. The
// engine-specific callers (EngineKit's LuxTTS/Pocket lanes, QwenANE's voice
// prep) all go through it, so macOS Studio and the iOS apps cut identically.

import CryptoKit
import Foundation

public enum ReferenceSection {
    public static let audioName = "ref.wav"

    /// SHA-256 of a file's bytes as 64 lowercase hex digits; nil when unreadable.
    /// Remembered per (path, size, mtime) so a render's staleness check does not
    /// re-hash a multi-megabyte master every line.
    public static func sha256Hex(ofFile url: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.standardizedFileURL.path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        hashLock.lock(); defer { hashLock.unlock() }
        if let hit = hashes[key] { return hit }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hex = sha256Hex(data)
        if hashes.count > 64 { hashes.removeAll() }
        hashes[key] = hex
        return hex
    }
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated(unsafe) private static var hashes: [String: String] = [:]
    private static let hashLock = NSLock()

    /// The bytes of a stored section: mono 16-bit PCM WAV, levelled to the
    /// reference standard. Writing the standard's own output means an export ->
    /// import round trip (which applies the standard to every engine wav) leaves
    /// the bytes alone, so the hashes recorded beside it stay true.
    public static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples { pcm += le(Int16(max(-1, min(1, s)) * 32767)) }
        var d = Data("RIFF".utf8); d += le(UInt32(36 + pcm.count)); d += Data("WAVEfmt ".utf8)
        d += le(UInt32(16)); d += le(UInt16(1)); d += le(UInt16(1)); d += le(UInt32(sampleRate))
        d += le(UInt32(sampleRate * 2)); d += le(UInt16(2)); d += le(UInt16(16))
        d += Data("data".utf8); d += le(UInt32(pcm.count)); d += pcm
        return ReferenceStandard.applied(to: d)
    }

    /// The share of `text` that sits under a cut of the master, by position in
    /// it, with each edge moved to the nearest sentence end when one is close —
    /// so the slice starts and stops on whole sentences, as the audio cut does
    /// in pauses. Used when no on-device transcription of the cut is available;
    /// a transcription of the cut itself is better. Stored like any other.
    public static func approximateText(_ text: String, windowStart: Int, windowCount: Int, totalCount: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, totalCount > 0 else { return text }
        var from = Int((Double(windowStart) / Double(totalCount) * Double(words.count)).rounded())
        var to = Int((Double(windowStart + windowCount) / Double(totalCount) * Double(words.count)).rounded())
        from = max(0, min(words.count - 1, from))
        to = max(from + 1, min(words.count, to))
        func isStart(_ i: Int) -> Bool {
            i == 0 || i == words.count || (words[i - 1].last.map { ".!?".contains($0) } ?? false)
        }
        let slack = max(2, (to - from) / 6)
        func snap(_ i: Int) -> Int {
            for d in 0 ... slack {
                if i + d <= words.count, isStart(i + d) { return i + d }
                if i - d >= 0, isStart(i - d) { return i - d }
            }
            return i
        }
        let a = snap(from), b = snap(to)
        return (b > a ? words[a ..< b] : words[from ..< to]).joined(separator: " ")
    }

    /// Plausible speech rates (words per second) for a transcript of a cut: a
    /// transcript that under-counts its audio inflates LuxTTS's frames-per-token
    /// ratio and the predicted duration runs away with it.
    public static let minWordsPerSecond = 1.0
    public static let maxWordsPerSecond = 6.0

    /// The text for a cut: `heard` (a transcription of the cut) when it reads at a
    /// plausible rate AND is in `language` (when known), else the master's own transcript sliced to the
    /// same span. A recogniser told the wrong language (or none) can hand back a TRANSLATION of the speech
    /// at a perfectly plausible rate; never store that. Returns whether it is the slice.
    public static func text(heard: String?, transcript: String, cutSeconds: Double,
                            start: Int, count: Int, total: Int,
                            language: String? = nil) -> (text: String, approximate: Bool) {
        if let heard, textIsPlausibleIn(language: language, heard) {
            let words = heard.split(whereSeparator: { $0.isWhitespace }).count
            let rate = Double(words) / max(0.1, cutSeconds)
            if rate >= minWordsPerSecond, rate <= maxWordsPerSecond { return (heard, false) }
        }
        return (approximateText(transcript, windowStart: start, windowCount: count, totalCount: total), true)
    }

    // MARK: language of a transcript

    private static let spanishWords: Set<String> = [
        "el", "los", "las", "una", "unos", "unas", "que", "de", "del", "y", "es", "por", "para", "con", "pero",
        "muy", "más", "mas", "hay", "nada", "yo", "tú", "usted", "ni", "lo", "esto", "eso", "está", "estoy",
        "gusta", "hablar", "cuando", "como", "cómo", "porque", "también", "ahí", "aquí", "qué", "sí", "su", "mi", "te",
    ]
    private static let englishWords: Set<String> = [
        "the", "and", "of", "to", "is", "are", "was", "were", "that", "this", "with", "for", "you", "your", "not",
        "there", "nothing", "anywhere", "can", "like", "speak", "private", "in", "or", "it", "on", "my", "have",
        "has", "be", "been", "what", "when", "very", "just", "about", "from", "they", "we", "i",
    ]

    /// Whether `text` could be in `language` (BCP-47, "es", "es-MX"). Only es and en are judged (stopword
    /// vote: a few unambiguous words of each); any other language, or none, passes. Short text with no clear
    /// vote passes. The failure this exists for: Spanish audio decoded as English by Whisper.
    public static func textIsPlausibleIn(language: String?, _ text: String) -> Bool {
        guard let lang = language?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased(),
              lang == "es" || lang == "en" else { return true }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let es = words.filter { spanishWords.contains($0) }.count
        let en = words.filter { englishWords.contains($0) }.count
        let spanishMarks = text.contains(where: { "ñ¿¡áéíóúü".contains($0) })
        if lang == "es" {
            if spanishMarks { return true }
            return !(en >= 3 && en > es)
        }
        if text.contains(where: { "ñ¿¡".contains($0) }) { return false }
        return !(es >= 3 && es > en)
    }

    /// Whether `text` has a plausible length for `seconds` of speech (words per second, wide bounds: a
    /// section stored with the wrong number of words makes Qwen hiss or run on).
    public static func lengthIsPlausible(_ text: String, seconds: Double) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let rate = Double(words) / max(0.1, seconds)
        return rate >= 0.25 && rate <= 8
    }

    /// The energy-based cut: start at the first speech (lead-in silence would
    /// otherwise eat the window), end in a pause near the tail where one is
    /// available so the reference doesn't stop mid-phoneme. Returns the whole
    /// clip when it already fits. Mirrors the web clone wizard's trimToWindow.
    public static func cut(
        samples: [Float], sampleRate: Int, maxSeconds: Double
    ) -> (samples: [Float], start: Int) {
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        guard samples.count > maxSamples, maxSamples > 0 else { return (samples, 0) }

        let frame = max(1, Int(Double(sampleRate) * 0.02))
        let frameCount = (samples.count + frame - 1) / frame
        var energy = [Float](repeating: 0, count: frameCount)
        var loudest: Float = 0
        for f in 0 ..< frameCount {
            let from = f * frame, to = min(from + frame, samples.count)
            var sumSq: Float = 0
            for i in from ..< to { sumSq += samples[i] * samples[i] }
            let e = (sumSq / Float(to - from)).squareRoot()
            energy[f] = e
            loudest = max(loudest, e)
        }
        let floor = max(loudest * 0.08, 0.008)

        // Skip lead-in silence, but only lead-in: search a bounded prefix. An
        // unbounded scan slides the whole window down the clip whenever a quiet
        // opening sits under a floor set by a loud passage later — on a 58s
        // reference that silently selected the LAST 30 seconds, a different
        // part of the recording than the stored transcript describes.
        //
        // Scoring candidate windows by speech DENSITY was tried and reverted
        // (2026-08-01). It measured no benefit — on a real 28.5s clone the
        // opening was already the densest 15s (60.9% speech vs 53-58% later) —
        // and it reproduced the sliding bug, because a quiet opening scores as
        // silence against a floor set by a louder passage. The pausiness it was
        // meant to fix was DRAWL, which density cannot see: that speaker had
        // high density and still read slow. Per-voice pace is the control for
        // that.
        let onsetLimit = min(frameCount, Int(5.0 / 0.02))
        var startFrame = 0
        while startFrame < onsetLimit, energy[startFrame] <= floor { startFrame += 1 }
        if startFrame >= onsetLimit { startFrame = 0 }
        var start = max(0, startFrame * frame - Int(Double(sampleRate) * 0.1))
        start = min(start, samples.count - maxSamples)
        var end = start + maxSamples

        let searchFloorFrame = (end - Int(Double(maxSamples) * 0.25)) / frame
        let minQuietFrames = 10  // 200 ms
        var quietRun = 0
        var f = end / frame - 1
        while f >= max(0, searchFloorFrame) {
            if energy[f] <= floor {
                quietRun += 1
            } else {
                if quietRun >= minQuietFrames {
                    let cut = min(end, (f + 1) * frame + Int(Double(sampleRate) * 0.08))
                    if cut - start >= Int(Double(maxSamples) * 0.6) { end = cut }
                    break
                }
                quietRun = 0
            }
            f -= 1
        }

        var out = Array(samples[start ..< end])
        let fade = min(out.count / 2, Int(Double(sampleRate) * 0.01))
        for i in 0 ..< fade {
            let ramp = Float(i) / Float(fade)
            out[i] *= ramp
            out[out.count - 1 - i] *= ramp
        }
        return (out, start)
    }

    /// Every way to end a cut at a sentence end, best guess first: for each sentence end in the back 60% of
    /// `text` (last first), the cut in each pause (a quiet run of 100 ms or more) within 2.5 s of where that
    /// sentence end falls by the character clock, nearest first, each keeping ~100 ms of its pause. The
    /// character clock is only an estimate (speech rate varies), so the caller transcribes the candidates
    /// and keeps the one whose words match (`wordDistance`). At most `limit` candidates; none under 5 s.
    public static func sentenceEndCandidates(samples: [Float], text: String, sampleRate: Int,
                                             limit: Int = 8) -> [(samples: [Float], text: String)] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 3 else { return [] }
        let weights = words.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        let frame = max(1, Int(Double(sampleRate) * 0.02))
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }
        var energy = [Float](repeating: 0, count: frameCount)
        var loudest: Float = 0
        for f in 0 ..< frameCount {
            var sumSq: Float = 0
            for i in (f * frame) ..< ((f + 1) * frame) { sumSq += samples[i] * samples[i] }
            energy[f] = (sumSq / Float(frame)).squareRoot()
            loudest = max(loudest, energy[f])
        }
        let floor = max(loudest * 0.08, 0.008)
        // pauses: (first quiet frame, length) of every quiet run of >= 5 frames
        var pauses: [(start: Int, length: Int)] = []
        var run = 0
        for f in 0 ... frameCount {
            if f < frameCount, energy[f] <= floor { run += 1; continue }
            if run >= 5 { pauses.append((f - run, run)) }
            run = 0
        }
        var out: [(samples: [Float], text: String)] = []
        var seenEnds = Set<Int>()
        var k = words.count
        while k > 0, out.count < limit {
            defer { k -= 1 }
            let endsHere = k == words.count ? endsSentence(text) : (words[k - 1].last.map { ".!?…".contains($0) } ?? false)
            guard endsHere, weights[..<k].reduce(0, +) >= total * 0.4 else { continue }
            let estimate = weights[..<k].reduce(0, +) / total * Double(frameCount)
            let near = pauses.filter { abs(Double($0.start) - estimate) <= 2.5 / 0.02 }
                .sorted { abs(Double($0.start) - estimate) < abs(Double($1.start) - estimate) }
            for p in near where out.count < limit {
                let end = min(samples.count, (p.start + min(p.length, 5)) * frame)
                guard end >= sampleRate * 5, seenEnds.insert(end * 31 + k).inserted else { continue }
                var cut = Array(samples[..<end])
                let fade = min(cut.count / 2, Int(Double(sampleRate) * 0.01))
                for i in 0 ..< fade { cut[cut.count - 1 - i] *= Float(i) / Float(fade) }
                out.append((cut, words[..<k].joined(separator: " ")))
            }
        }
        return out
    }

    /// Words of a transcript for comparison: lower case, diacritics and punctuation dropped.
    public static func comparableWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    /// Word-level edit distance between what a recogniser heard in a cut and the transcript stored for it.
    /// A cut whose audio runs past its transcript (or stops short of it) pays one per extra/missing word.
    public static func wordDistance(heard: String, text: String) -> Int {
        let a = comparableWords(text), b = comparableWords(heard)
        var d = Array(0 ... b.count)
        for i in 1 ... max(1, a.count) where !a.isEmpty {
            var prev = d[0]; d[0] = i
            for j in 1 ... max(1, b.count) where !b.isEmpty {
                let cur = d[j]
                d[j] = Swift.min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : d[b.count]
    }

    /// Whether `text` ends a sentence (`. ! ? …`, optionally followed by closing quotes/brackets).
    /// `text`, trimmed, with a full stop added unless it already ends a sentence. Qwen reads a reference
    /// transcript and the script as one stream, so one that stops mid-sentence ("...West Coast crew") runs
    /// into the script and every render opens with its last word.
    public static func endingASentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || endsSentence(t) ? t : t + "."
    }

    public static func endsSentence(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = t.last.map { "\"'”’»)]".contains($0) } == true ? String(t.dropLast()) : t
        return trimmed.last.map { ".!?…".contains($0) } ?? false
    }

    /// A reference that stops mid-sentence makes a continuing model (Qwen) carry on the sentence, so a
    /// cut's audio and transcript end at a sentence end. When `text` already does, both are returned
    /// as they are. Otherwise the transcript is cut back to its last sentence end and the audio to the
    /// pause nearest that point's estimated position (characters as the clock, then snapped to the
    /// longest quiet stretch within a second of it). Returns the input unchanged when there is no
    /// sentence end in the back 60% of the text or the result would be under 5 s.
    public static func endAtSentence(samples: [Float], text: String, sampleRate: Int) -> (samples: [Float], text: String) {
        guard !endsSentence(text) else { return (samples, text) }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 3 else { return (samples, text) }
        let weights = words.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var k = words.count - 1
        while k > 0, !(words[k - 1].last.map { ".!?…".contains($0) } ?? false) { k -= 1 }
        guard k > 0, weights[..<k].reduce(0, +) >= total * 0.4 else { return (samples, text) }
        let estimate = Int(weights[..<k].reduce(0, +) / total * Double(samples.count))

        let frame = max(1, Int(Double(sampleRate) * 0.02))
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return (samples, text) }
        var energy = [Float](repeating: 0, count: frameCount)
        var loudest: Float = 0
        for f in 0 ..< frameCount {
            var sumSq: Float = 0
            for i in (f * frame) ..< ((f + 1) * frame) { sumSq += samples[i] * samples[i] }
            energy[f] = (sumSq / Float(frame)).squareRoot()
            loudest = max(loudest, energy[f])
        }
        let floor = max(loudest * 0.08, 0.008)
        let radius = Int(1.0 / 0.02)
        let center = min(frameCount - 1, estimate / frame)
        let lo = max(0, center - radius), hi = min(frameCount - 1, center + radius)
        var best: (start: Int, length: Int)?
        var run = 0
        for f in lo ... hi {
            if energy[f] <= floor { run += 1 } else { run = 0 }
            if run >= 5, best == nil || run > best!.length || (run == best!.length && abs(f - center) < abs(best!.start + run / 2 - center)) {
                best = (f - run + 1, run)
            }
        }
        let end: Int
        if let b = best { end = min(samples.count, (b.start + min(b.length, 5)) * frame) }   // keep ~100 ms of the pause
        else {
            var m = lo
            for f in lo ... hi where energy[f] < energy[m] { m = f }
            end = (m + 1) * frame
        }
        guard end >= sampleRate * 5 else { return (samples, text) }
        var out = Array(samples[..<end])
        let fade = min(out.count / 2, Int(Double(sampleRate) * 0.01))
        for i in 0 ..< fade { out[out.count - 1 - i] *= Float(i) / Float(fade) }
        return (out, words[..<k].joined(separator: " "))
    }
}
