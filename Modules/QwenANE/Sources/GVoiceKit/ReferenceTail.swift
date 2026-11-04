// ReferenceTail.swift
// EngineKit — a cloning reference must never end on a sound it cuts off.
//
// Qwen3-TTS clones by CONTINUING the reference audio: its first generated
// frame picks up wherever the clip stops. Jeff's starter pack was cut at a
// flat 15.0 s, 60 ms into a word (quiet at -66 dB, then -48, -30, -24, -17),
// so every part opened by finishing that word: a blip after each seam, junk
// heard as "At", "100", "2000" before the first real word, and 2 renders in
// 8 of "At the top, ..." stuck as "At at at at" (Mac probe 2026-09-24, iOS
// builds 18 and 19 alike). Backing the clip off to its last quiet stretch
// fixed all of it: 0/8 stuck, and every part starts from silence.
//
// So: when a clip ends on speech-loud sound that starts after a real quiet
// stretch, it ends at that quiet instead. A clip that ends quiet, or fades
// out with no quiet before the end, is left alone.
//
// Applied where a reference enters a voice library (beside RefLoudness, in
// both apps), by voice-level for packs and voices already on disk, and by
// the iOS Qwen engine when it loads a reference (voices saved before this).

import Foundation

public enum ReferenceTail {
    /// A 20 ms block at or under this is quiet. Below the -45 dB speech floor,
    /// so the soft start of a word is not taken for quiet.
    public static let quietDb: Float = -50
    /// Sound after the quiet counts as a new start only if some of it reaches
    /// speech level; a faint tail is room tone.
    public static let speechDb: Float = -45
    /// Shortest quiet worth cutting at; one quiet block is a gap inside speech.
    public static let minQuietSeconds = 0.06
    /// How far back from the end the cut may land.
    public static let searchSeconds = 0.5

    /// How many of `samples` (mono) to keep: all of them when nothing needs cutting.
    public static func end(of samples: [Float], sampleRate: Int) -> Int {
        let block = max(1, sampleRate / 50)
        let n = min(samples.count, Int(searchSeconds * Double(sampleRate))) / block
        guard n > 0 else { return samples.count }
        // Level per block, counting back from the end (0 = the last block).
        let db = (0 ..< n).map { k -> Float in
            let hi = samples.count - k * block
            var acc: Float = 0
            for i in (hi - block) ..< hi { acc += samples[i] * samples[i] }
            let rms = (acc / Float(block)).squareRoot()
            return rms > 1e-5 ? 20 * log10(rms) : -100
        }
        // The sound the clip ends on, back to the last quiet block.
        var k = 0
        while k < n, db[k] > quietDb { k += 1 }
        guard k > 0, k < n, db[..<k].contains(where: { $0 > speechDb }) else { return samples.count }
        var quiet = 0
        while k + quiet < n, db[k + quiet] <= quietDb { quiet += 1 }
        guard Double(quiet * block) >= minQuietSeconds * Double(sampleRate) else { return samples.count }
        return samples.count - k * block
    }

    /// `wav` cut to `end(of:)`, header sizes rewritten; any chunk after `data`
    /// is kept. Returns the input unchanged -- never throws -- when nothing
    /// needs cutting or the bytes are not a WAV `RefLoudness` can read: an
    /// uncut reference is still a usable one.
    public static func trimmed(wav: Data) -> Data {
        let wav = Data(wav)   // zero-based indices
        guard let chunk = RefLoudness.dataChunk(in: wav) else { return wav }
        let bytes = chunk.format == .pcm16 ? 2 : 4
        let frameBytes = bytes * chunk.channels
        let frames = chunk.length / frameBytes
        guard frames > 0 else { return wav }

        func sample(_ i: Int) -> Float {
            let at = chunk.offset + i * bytes
            if chunk.format == .pcm16 {
                return Float(Int16(bitPattern: UInt16(wav[at]) | (UInt16(wav[at + 1]) << 8))) / 32768
            }
            var bits: UInt32 = 0
            for b in 0 ..< 4 { bits |= UInt32(wav[at + b]) << (8 * UInt32(b)) }
            return Float(bitPattern: bits)
        }
        let mono = (0 ..< frames).map { f -> Float in
            var sum: Float = 0
            for c in 0 ..< chunk.channels { sum += sample(f * chunk.channels + c) }
            return sum / Float(chunk.channels)
        }
        let keep = end(of: mono, sampleRate: chunk.sampleRate)
        guard keep < frames else { return wav }

        let newLength = keep * frameBytes
        var out = Data(wav[0 ..< chunk.offset])
        func put32(_ value: Int, at: Int) {
            for b in 0 ..< 4 { out[at + b] = UInt8((value >> (8 * b)) & 0xFF) }
        }
        put32(newLength, at: chunk.offset - 4)
        out.append(wav[chunk.offset ..< chunk.offset + newLength])
        if newLength % 2 == 1 { out.append(0) }
        let after = chunk.offset + chunk.length + (chunk.length % 2)
        if after < wav.count { out.append(wav[after...]) }
        put32(out.count - 8, at: 4)
        return out
    }
}
