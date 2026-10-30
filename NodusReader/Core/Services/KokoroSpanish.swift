// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import KokoroTTS

/// Spanish phonemes for the Kokoro SDK's text processor.
struct KokoroSpanishPhonemizer: KokoroPhonemizer {
    func phonemize(_ text: String) throws -> KokoroPhonemeResult {
        let phonemes = SpanishG2P.phonemize(text)
        guard !phonemes.isEmpty else { throw KokoroPhonemizerError.emptyOutput }
        return KokoroPhonemeResult(phonemes: phonemes)
    }
}

/// Spanish narration on the installed Kokoro engine.
///
/// The SDK's raw-text path speaks English only and rejects other voices. The
/// model itself was trained on Spanish (voices `ef_dora`, `em_alex`,
/// `em_santa`), so Spanish text is phonemized with `SpanishG2P`, cut into
/// pieces that fit the runtime's 128-token shape, and run through the same
/// Core ML pipeline with `synthesizePrepared`.
enum KokoroSpanish {
    /// Kokoro's Spanish voice files: `e` = Spanish, `f`/`m` = female/male.
    static func isSpanishVoice(_ name: String) -> Bool {
        name.hasPrefix("ef_") || name.hasPrefix("em_")
    }

    /// Phonemes per piece: the duration stage takes 128 tokens, two of which
    /// frame the text.
    static let maxPhonemes = 120

    /// `text` cut at clause punctuation, then between words, into pieces whose
    /// phonemes fit one synthesis call.
    static func pieces(of text: String) -> [(text: String, phonemes: String)] {
        var clauses: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ",;:.!?…—".contains(character) {
                clauses.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { clauses.append(current) }

        var pieces: [(text: String, phonemes: String)] = []
        var pending = ""
        func flush() {
            let trimmed = pending.trimmingCharacters(in: .whitespaces)
            pending = ""
            guard !trimmed.isEmpty else { return }
            let phonemes = SpanishG2P.phonemize(trimmed)
            if !phonemes.isEmpty { pieces.append((trimmed, phonemes)) }
        }
        for clause in clauses {
            let candidate = pending + clause
            if SpanishG2P.phonemize(candidate).count <= maxPhonemes {
                pending = candidate
                continue
            }
            flush()
            if SpanishG2P.phonemize(clause).count <= maxPhonemes {
                pending = clause
                continue
            }
            // One clause longer than a piece: split between words.
            for word in clause.split(separator: " ", omittingEmptySubsequences: true) {
                let joined = pending.isEmpty ? String(word) : pending + " " + word
                if SpanishG2P.phonemize(joined).count > maxPhonemes, !pending.isEmpty {
                    flush()
                    pending = String(word)
                } else {
                    pending = joined
                }
            }
        }
        flush()
        return pieces
    }

    /// Mono 24 kHz samples for `text` in `voice` (for example `ef_dora`).
    static func synthesize(_ text: String, voice: String, engine: KokoroTTS,
                           bundle: URL) async throws -> [Float] {
        let processor = try textProcessor(bundle: bundle)
        let table = try voiceTable(voice, bundle: bundle)
        let rows = table.count / 256
        let inputs = try pieces(of: text).enumerated().map { index, piece in
            let result = KokoroPhonemeResult(phonemes: piece.phonemes)
            let row = max(0, min(rows - 1, result.utf16Count - 1))
            return try processor.prepare(
                text: piece.text,
                voice: KokoroVoiceID(voice),
                refS: Array(table[(row * 256)..<((row + 1) * 256)]),
                key: String(format: "chunk-%03d", index),
                phonemeResult: result
            )
        }
        guard !inputs.isEmpty else { throw KokoroError.emptyText }
        var samples: [Float] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let audio = try await engine.synthesizePrepared([input])
            let chunk = NarrationPCM.kokoroChunk(audio.samples, sampleRate: Double(audio.sampleRate),
                continuesPrevious: index > 0 && !NarrationPCM.endsClause(inputs[index - 1].text ?? ""),
                continuesNext: index + 1 < inputs.count && !NarrationPCM.endsClause(input.text ?? ""))
            NarrationPCM.append(chunk, to: &samples, sampleRate: Double(audio.sampleRate))
        }
        return samples
    }

    // MARK: Bundle files

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var processor: (bundle: URL, processor: KokoroTextProcessor)?
        var tables: [String: [Float]] = [:]
    }

    /// The text processor with the installed bundle's own vocabulary.
    private static func textProcessor(bundle: URL) throws -> KokoroTextProcessor {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let cached = cache.processor, cached.bundle == bundle { return cached.processor }
        let manifestURL = bundle.appendingPathComponent("KokoroRuntimeManifest.json")
        let vocab: [String: Int32]
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = manifest["runtime_assets"] as? [String: Any],
           let entry = assets["vocab"] as? [String: Any],
           let path = entry["path"] as? String,
           !path.hasPrefix("/"), !path.split(separator: "/").contains("..") {
            vocab = try KokoroTextProcessor.loadVocab(from: bundle.appendingPathComponent(path))
        } else {
            vocab = try KokoroTextProcessor.loadBundledVocab()
        }
        let processor = KokoroTextProcessor(phonemizer: KokoroSpanishPhonemizer(), vocab: vocab)
        cache.processor = (bundle, processor)
        return processor
    }

    /// A voice's style table: rows of 256 little-endian floats, one per
    /// phoneme count.
    private static func voiceTable(_ voice: String, bundle: URL) throws -> [Float] {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let cached = cache.tables[voice] { return cached }
        guard voice.allSatisfy({ $0.isLetter || $0 == "_" }) else { throw KokoroError.unsupportedVoice(voice) }
        let url = bundle.appendingPathComponent("voices/\(voice).bin")
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count % (256 * 4) == 0 else {
            throw KokoroError.unsupportedVoice(voice)
        }
        let floats = data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
        cache.tables[voice] = floats
        return floats
    }
}
