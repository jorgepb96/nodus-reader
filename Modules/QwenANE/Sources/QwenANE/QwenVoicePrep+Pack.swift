import Foundation
import GVoiceKit

/// `engines/qwen3-0.6b/` (or `qwen3-1.7b/`, by `kind`) of a `.gvoice` pack (GVoiceKit's `QwenEngineFiles`; docs/gvoice-format.md):
/// a voice prepared once, on a Mac, so a phone skips the ~5 s on-device prep.
///
/// A pack's files are trusted only as far as they can be checked: the sha256 of the audio the reader
/// would otherwise prepare, the prep version and mel recipe, the transcript, and the shape of the
/// arrays. Anything that does not match is ignored and the voice is prepared as before, so a stale or
/// hostile folder can cost time but never changes what a voice sounds like.
extension QwenVoicePrep {
    /// What `QwenEngineFiles.derivedFrom.by` says for files made here.
    public static let packWriter = "QwenVoicePrep"

    /// Where a prepared voice came from.
    public enum Origin: Equatable, Sendable {
        /// This device's own prep cache.
        case cache
        /// The pack's `engines/qwen3-*/` (verified); the cache was seeded from it.
        case pack
        /// Computed with the encoders just now. The caller should write `enginePayload(...)` back
        /// into the pack / voice folder so the next device skips this.
        case computed
    }

    public struct Prepared: Sendable {
        public let files: QwenVoiceFiles
        public let origin: Origin
        /// sha256 of the reference WAV bytes these files were derived from.
        public let audioSHA256: String

        /// The pack folder for this voice. `audio` is the pack-relative path of the file that was
        /// prepared (`source/ref.wav`, or a window); `window` its span in the master when it is one.
        public func enginePayload(audio: String = "source/ref.wav",
                                  window: (start: Double, end: Double)? = nil,
                                  sourceSHA256: String? = nil,
                                  kind: QwenEngineFiles.Kind = .qwen06) throws -> QwenEngineFiles {
            try QwenVoicePrep.enginePayload(for: files, audioSHA256: audioSHA256, audio: audio, window: window,
                                            sourceSHA256: sourceSHA256, kind: kind)
        }
    }

    /// Cache, then the pack's files, then the encoders. Returns the voice and where it came from.
    /// `pack == nil` behaves exactly like `prepared(referenceWAV:transcript:cacheDirectory:modelsDirectory:)`.
    public static func prepared(fromPack pack: QwenEngineFiles?, referenceWAV: Data, transcript: String,
                                cacheDirectory: URL, modelsDirectory: URL, kind: QwenEngineFiles.Kind = .qwen06) throws -> Prepared {
        try prepared(fromPack: pack, referenceWAV: referenceWAV, transcript: transcript,
                     cacheDirectory: cacheDirectory, kind: kind,
                     encode: { try prepare(referenceWAV: $0, transcript: $1, modelsDirectory: modelsDirectory, kind: kind) })
    }

    /// Test seam: `encode` stands in for the Core ML encoders so a test can count their runs.
    static func prepared(fromPack pack: QwenEngineFiles?, referenceWAV: Data, transcript: String,
                         cacheDirectory: URL, kind: QwenEngineFiles.Kind = .qwen06,
                         encode: (Data, String) throws -> QwenVoiceFiles) throws -> Prepared {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = sha256Hex(referenceWAV)
        if let hit = cached(directory: cacheDirectory, sha: sha, text: text, kind: kind) {
            return Prepared(files: hit, origin: .cache, audioSHA256: sha)
        }
        if let pack, pack.kind == kind, let voice = voice(from: pack, referenceWAV: referenceWAV, transcript: text) {
            // The cache is a convenience: failing to seed it must not fail a voice we already have.
            try? write(voice, sha: sha, to: cacheDirectory)
            return Prepared(files: voice, origin: .pack, audioSHA256: sha)
        }
        let voice = try encode(referenceWAV, text)
        try write(voice, sha: sha, to: cacheDirectory)
        return Prepared(files: voice, origin: .computed, audioSHA256: sha)
    }

    /// The pack's voice when it is valid and describes exactly `referenceWAV` + `transcript`
    /// (already trimmed); nil otherwise.
    static func voice(from pack: QwenEngineFiles, referenceWAV: Data, transcript: String) -> QwenVoiceFiles? {
        guard pack.isCurrent(forAudio: referenceWAV, transcript: transcript, prepVersion: prepVersion, mel: melKind),
              let voice = try? voiceFiles(from: pack, refText: transcript),
              // Integrity: the frame count must be what these samples encode to.
              let all = try? samples(of: referenceWAV),
              voice.refCodes[0].count == codeFrames(samples: ReferenceTail.end(of: all, sampleRate: sampleRate))
        else { return nil }
        return voice
    }

    /// Decodes a pack folder into engine input. Validates shapes and code ranges; does NOT check
    /// staleness (use `prepared(fromPack:...)`).
    public static func voiceFiles(from pack: QwenEngineFiles, refText: String? = nil) throws -> QwenVoiceFiles {
        let codes = try pack.decodedRefCodes()
        let spk = try pack.decodedSpeakerEmbedding()
        try QwenVoiceFiles.validate(refCodes: codes)
        return QwenVoiceFiles(refText: refText ?? pack.text.trimmingCharacters(in: .whitespacesAndNewlines),
                              refCodes: codes, spkEmbedding: spk)
    }

    /// The `engines/qwen3-0.6b/` payload for a prepared voice. `audioSHA256` is the sha256 of the
    /// exact bytes of the file named by `audio`.
    public static func enginePayload(for voice: QwenVoiceFiles, audioSHA256: String, audio: String = "source/ref.wav",
                                     window: (start: Double, end: Double)? = nil,
                                     sourceSHA256: String? = nil,
                                     kind: QwenEngineFiles.Kind = .qwen06) throws -> QwenEngineFiles {
        try QwenVoiceFiles.validate(refCodes: voice.refCodes)
        guard voice.spkEmbedding.count == kind.speakerDimension else {
            throw QwenANEError.invalid("spkEmbedding must be \(kind.speakerDimension) floats for \(kind.engineID)")
        }
        let (codes, spk) = npyFiles(voice)
        let payload = QwenEngineFiles(
            text: voice.refText,
            derivedFrom: .init(audio: audio, sha256: audioSHA256, startSeconds: window?.start, endSeconds: window?.end,
                               by: packWriter, prepVersion: prepVersion, mel: melKind,
                               sourceSha256: window == nil ? nil : sourceSHA256),
            refCodes: codes, spkEmbedding: spk, kind: kind)
        try payload.validate()
        return payload
    }

    /// Convenience: payload for `voice` prepared from `referenceWAV`.
    public static func enginePayload(for voice: QwenVoiceFiles, referenceWAV: Data, audio: String = "source/ref.wav",
                                     window: (start: Double, end: Double)? = nil) throws -> QwenEngineFiles {
        try enginePayload(for: voice, audioSHA256: sha256Hex(referenceWAV), audio: audio, window: window)
    }
}
