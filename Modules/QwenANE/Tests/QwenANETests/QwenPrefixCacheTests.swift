import Foundation
import XCTest
@testable import QwenANE

/// The per-voice prompt rows and the talker KV prefix cache. The cache must change nothing but the time:
/// the same seed has to give the same codes with it on (cold fill and warm hit) and off.
///   QWEN_ANE_MODELS=/path/to/Models swift test --filter QwenPrefixCacheTests
final class QwenPrefixCacheTests: XCTestCase {
    private func modelsDirectory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    static let lines = [
        "Hello there.",
        "Good evening, you are tuned in to Gloam F M. Up next, a slow burner.",
        "\nA line that starts with a newline.",          // its first token can merge with the role's last
        "Quick one!",
    ]

    /// `jeff` with a longer transcript (the same words repeated) so its voice-only prefix spans more than one
    /// 64-row prefill chunk. The audio and the text no longer match; for an identity test that is irrelevant.
    private func longVoice(_ base: QwenVoiceFiles, repeats: Int) -> QwenVoiceFiles {
        QwenVoiceFiles(refText: Array(repeating: base.refText, count: repeats).joined(separator: " "),
                       refCodes: base.refCodes, spkEmbedding: base.spkEmbedding)
    }

    /// The pre-cache construction, verbatim (one joint text projection for reference + line, everything per line).
    private func legacyPrompt(host: HostTables, voice: QwenVoiceFiles, text: String) -> [Float] {
        let c = host.cfg
        let H = host.hidden
        let refIds = host.tok.encode("<|im_start|>assistant\n\(voice.refText)<|im_end|>\n")
        let rs = min(3, refIds.count), re = max(rs, refIds.count - 2)
        let refTextIds = Array(refIds[rs..<re])
        let tgtIds = host.tok.encode("<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n")
        let ts = min(3, tgtIds.count), te = max(ts, tgtIds.count - 5)
        let textIds = Array(tgtIds[ts..<te])
        let tts = host.textProj([c.ttsBos, c.ttsEos, c.ttsPad])
        let ttsBos = Array(tts[0..<H]), ttsEos = Array(tts[H..<2 * H]), ttsPad = Array(tts[2 * H..<3 * H])
        var textEmbed = host.textProj(refTextIds + textIds) + ttsEos
        let nT = textEmbed.count / H
        let padRow = host.codecRow(c.codecPad)
        for r in 0..<nT { for j in 0..<H { textEmbed[r * H + j] += padRow[j] } }
        let Tref = voice.refCodes[0].count
        var codecIcl = [Float](repeating: 0, count: (Tref + 1) * H)
        let bosRow = host.codecRow(c.codecBos)
        for j in 0..<H { codecIcl[j] = bosRow[j] }
        for t in 0..<Tref {
            let r0 = host.codecRow(voice.refCodes[0][t])
            for j in 0..<H { codecIcl[(t + 1) * H + j] = r0[j] }
        }
        for i in 0..<(c.groups - 1) where i + 1 < voice.refCodes.count {
            for t in 0..<Tref {
                let row = host.cpRow(i, voice.refCodes[i + 1][t])
                for j in 0..<H { codecIcl[(t + 1) * H + j] += row[j] }
            }
        }
        for r in 0..<(Tref + 1) { for j in 0..<H { codecIcl[r * H + j] += ttsPad[j] } }
        var prefix: [Float] = []
        for id in [c.codecNothink, c.codecThinkBos, c.codecThinkEos] { prefix += host.codecRow(id) }
        prefix += voice.spkEmbedding
        for id in [c.codecPad, c.codecBos] { prefix += host.codecRow(id) }
        let pRows = prefix.count / H
        let role = host.textProj(Array(tgtIds[0..<3]))
        let padCount = pRows - 2
        var comb = [Float](repeating: 0, count: (padCount + 1) * H)
        for r in 0..<padCount { for j in 0..<H { comb[r * H + j] = ttsPad[j] + prefix[r * H + j] } }
        for j in 0..<H { comb[padCount * H + j] = ttsBos[j] + prefix[padCount * H + j] }
        return role + comb + textEmbed + codecIcl
    }

    // MARK: prompt rows

    /// The cached-rows construction gives exactly the embeddings the old one did (bit for bit), including for
    /// a line whose first token merges with the role tokens, and the shared prefix really is shared.
    func testPromptRowsAreBitIdenticalToTheLegacyConstruction() throws {
        let dir = try modelsDirectory()
        let host = try HostTables(dir: dir.appendingPathComponent("host").path)
        // Debug builds take ~40 s for the whole matrix: the default run checks one voice, QWEN_SLOW_TESTS=1 all of them.
        let full = ProcessInfo.processInfo.environment["QWEN_SLOW_TESTS"] == "1"
        for name in full ? ["jeff", "cruz", "benson"] : ["jeff"] {
            let base = try QwenVoiceFiles(directory: dir.appendingPathComponent("voices/\(name)"))
            for voice in full ? [base, longVoice(base, repeats: 3)] : [base] {
                let vp = VoicePrompt(host: host, voice: voice)
                var prefixes: [[Float]] = []
                for text in Self.lines {
                    let want = legacyPrompt(host: host, voice: voice, text: text)
                    let got = buildICLPrompt(host: host, voice: voice, text: text, voicePrompt: vp, keepVoicePrompt: true)
                    XCTAssertEqual(got.embeds.count, want.count, "\(name) '\(text.prefix(10))'")
                    XCTAssertTrue(got.embeds == want, "\(name) '\(text.prefix(10))': prompt rows differ from the legacy build")
                    // and the uncached call (no VoicePrompt passed) agrees too
                    XCTAssertTrue(buildICLPrompt(host: host, voice: voice, text: text).embeds == want)
                    if got.prefixRows > 0 {
                        prefixes.append(Array(got.embeds[0..<(got.prefixRows * host.hidden)]))
                        XCTAssertNotNil(got.voice)
                    }
                }
                XCTAssertGreaterThanOrEqual(prefixes.count, Self.lines.count - 1)
                XCTAssertTrue(prefixes.allSatisfy { $0 == prefixes[0] }, "\(name): the leading rows differ between lines")
            }
        }
    }

    // MARK: KV prefix (models)

    private struct Run { var codes: [Int64]; var samples: [Float]; var reused: Int; var promptPrefill: Double }

    @available(iOS 18.0, macOS 15.0, *)
    private func run(_ engine: QwenANEEngine, _ text: String, _ voice: QwenVoiceFiles, cache: Bool, seed: UInt64 = 7) throws -> Run {
        engine.options.prefixCache = cache
        let r = try engine.render(text: text, voice: voice, seed: seed)
        return Run(codes: r.codes, samples: r.samples, reused: r.prefixRowsReused, promptPrefill: r.timings.prompt + r.timings.prefill)
    }

    /// Free-running codes for the same seed are equal with the cache off, on (the fill) and on (the hit), for
    /// voices whose prefix covers one, two and no whole prefill chunk, over several lines, interleaved.
    @available(iOS 18.0, macOS 15.0, *)
    func testCachedPrefillGivesTheSameCodesAsUncached() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let jeff = try engine.loadVoice(named: "jeff")
        let voices: [(String, QwenVoiceFiles, Int)] = [
            ("jeff x1", jeff, 64), ("jeff x2", longVoice(jeff, repeats: 2), 64), ("jeff x3", longVoice(jeff, repeats: 3), 128),
            ("benson", try engine.loadVoice(named: "benson"), 0),
        ]
        for (label, voice, wantRows) in voices {
            let probe = buildICLPrompt(host: engine.host, voice: voice, text: Self.lines[0])
            XCTAssertEqual(ANETalkerEngine.cacheableRows(probe), wantRows, label)
            var baseline: [String: Run] = [:]
            for text in Self.lines {
                let a = try run(engine, text, voice, cache: false)
                let a2 = try run(engine, text, voice, cache: false)
                XCTAssertEqual(a.codes, a2.codes, "\(label): the uncached render is not even repeatable")
                XCTAssertEqual(a.reused, 0)
                baseline[text] = a
            }
            engine.dropCaches()
            for (i, text) in (Self.lines + Self.lines.reversed()).enumerated() {
                let b = try run(engine, text, voice, cache: true)
                let want = try XCTUnwrap(baseline[text])
                XCTAssertGreaterThan(b.codes.count, 0)
                XCTAssertEqual(b.codes, want.codes, "\(label) '\(text.prefix(10))' line \(i): codes differ with the cache")
                XCTAssertTrue(b.samples == want.samples, "\(label) '\(text.prefix(10))': samples differ with the cache")
                // line 0 fills the cache, every later line (but not the merged-token line) reuses it
                let expectReuse = (i == 0 || text.hasPrefix("\n")) ? 0 : wantRows
                XCTAssertEqual(b.reused, expectReuse, "\(label) line \(i) reused rows")
            }
        }
    }

    /// Teacher forcing: with the codes of an uncached line fed back frame by frame, the cached engine's own
    /// picks (sampler g0, code predictor sub-codes) are those same codes.
    @available(iOS 18.0, macOS 15.0, *)
    func testTeacherForcedPicksMatchWithTheCache() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = longVoice(try engine.loadVoice(named: "jeff"), repeats: 3)
        let text = Self.lines[1]
        let base = try run(engine, text, voice, cache: false)
        let frames = (0..<(base.codes.count / 16)).map { f in (0..<16).map { Int(base.codes[f * 16 + $0]) } }
        engine.talker.forced = frames
        defer { engine.talker.forced = nil }
        for pass in 0..<2 {                                   // pass 0 fills the cache, pass 1 hits it
            let r = try run(engine, text, voice, cache: true)
            XCTAssertEqual(r.reused, pass == 0 ? 0 : 128)
            XCTAssertEqual(engine.talker.forcedPicks, frames, "pass \(pass): forced picks differ")
        }
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testCacheIsBoundedAndDropCachesClearsIt() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let jeff = try engine.loadVoice(named: "jeff")
        for n in 1...(QwenANEEngine.maxCachedVoices + 2) {
            let v = QwenVoiceFiles(refText: jeff.refText + String(repeating: " word", count: n),
                                   refCodes: jeff.refCodes, spkEmbedding: jeff.spkEmbedding)
            _ = try engine.render(text: "Hi.", voice: v, seed: 1, maxFrames: 2)
            XCTAssertLessThanOrEqual(engine.cachedVoiceCount, QwenANEEngine.maxCachedVoices)
        }
        XCTAssertEqual(engine.cachedVoiceCount, QwenANEEngine.maxCachedVoices)
        let before = try run(engine, Self.lines[0], jeff, cache: true)
        engine.dropCaches()
        XCTAssertEqual(engine.cachedVoiceCount, 0)
        let after = try run(engine, Self.lines[0], jeff, cache: true)
        XCTAssertEqual(after.reused, 0, "dropCaches must also drop the KV prefix")
        XCTAssertEqual(before.codes, after.codes)
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testWarmFillsTheVoiceCache() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = longVoice(try engine.loadVoice(named: "jeff"), repeats: 3)
        engine.options.prefixCache = true
        let secs = try engine.warm(voice: voice)
        XCTAssertGreaterThan(secs, 0)
        XCTAssertEqual(engine.cachedVoiceCount, 1)
        XCTAssertEqual(try run(engine, Self.lines[0], voice, cache: true).reused, 128, "the first real line after warm() reuses the prefix")
    }

    /// Prompt + prefill wall, cache off vs on (printed; a measurement, not a gate).
    @available(iOS 18.0, macOS 15.0, *)
    func testMeasurePromptAndPrefill() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let jeff = try engine.loadVoice(named: "jeff")
        let cases: [(String, QwenVoiceFiles)] = [("jeff", jeff), ("cruz", try engine.loadVoice(named: "cruz")),
                                                 ("benson", try engine.loadVoice(named: "benson")),
                                                 ("jeff x2 (long transcript)", longVoice(jeff, repeats: 2)),
                                                 ("jeff x3 (long transcript)", longVoice(jeff, repeats: 3))]
        for (name, voice) in cases {
            _ = try run(engine, "Warm up.", voice, cache: true)
            for cache in [false, true] {
                var t: [Double] = []
                var reused = 0
                for _ in 0..<7 { let r = try run(engine, "Hello there.", voice, cache: cache); t.append(r.promptPrefill); reused = r.reused }
                t.sort()
                print("MEASURE \(name) cache=\(cache) reusedRows=\(reused) prompt+prefill median ms \(String(format: "%.1f", t[3] * 1000)) min \(String(format: "%.1f", t[0] * 1000))")
            }
        }
    }

    // MARK: chunk schedule

    /// A short first vocoder chunk moves the chunk boundaries, not the audio: the codes are identical and the samples
    /// agree to Neural Engine fp16 rounding (the padded window changes the ANE's tiling, so not bit for bit; the
    /// default whole-chunk path is the bit-exact one). Streamed pieces, concatenated, are the same line.
    @available(iOS 18.0, macOS 15.0, *)
    func testShortFirstChunkGivesTheSameAudioToRounding() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        for name in ["jeff", "cruz"] {
            let voice = try engine.loadVoice(named: name)
            for text in [Self.lines[1], "Hello there."] {
                let a = try engine.render(text: text, voice: voice, seed: 7, chunkFrames: [12])
                for schedule in [[4, 8, 12], [6, 12], [1, 2, 4, 8, 12]] {
                    var pieces = 0
                    let b = try engine.render(text: text, voice: voice, seed: 7, chunkFrames: schedule, onAudio: { _ in pieces += 1 })
                    XCTAssertEqual(a.codes, b.codes, "\(name) \(schedule): the codes are the talker's, chunking cannot change them")
                    XCTAssertEqual(a.samples.count, b.samples.count, "\(name) \(schedule)")
                    var maxd: Float = 0, err = 0.0, sig = 0.0
                    for i in 0..<min(a.samples.count, b.samples.count) {
                        let d = a.samples[i] - b.samples[i]
                        maxd = max(maxd, abs(d)); err += Double(d * d); sig += Double(a.samples[i] * a.samples[i])
                    }
                    let snr = 10 * log10(sig / max(err, 1e-30))
                    print("MEASURE chunk-diff \(name) \(schedule) '\(text.prefix(8))' maxAbs \(maxd) SNR \(String(format: "%.1f", snr)) dB pieces \(pieces)")
                    XCTAssertLessThan(maxd, 0.02, "\(name) \(schedule) '\(text.prefix(8))'")
                    XCTAssertGreaterThan(snr, 40, "\(name) \(schedule) '\(text.prefix(8))'")
                    XCTAssertGreaterThan(pieces, 1)
                }
            }
        }
    }

    /// First audio (render start to the first delivered chunk), cache on/off and chunk schedules (printed).
    @available(iOS 18.0, macOS 15.0, *)
    func testMeasureFirstAudio() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let jeff = try engine.loadVoice(named: "jeff")
        let voices: [(String, QwenVoiceFiles)] = [("jeff", jeff), ("cruz", try engine.loadVoice(named: "cruz")),
                                                  ("jeff x3", longVoice(jeff, repeats: 3))]
        let configs: [(String, Bool, [Int])] = [("no cache, 12", false, [12]), ("cache, 12", true, [12]),
                                                ("cache, 4-8-12", true, [4, 8, 12]), ("cache, 6-6-8-10-12", true, [6, 6, 8, 10, 12])]
        for (name, voice) in voices {
            _ = try run(engine, "Warm up.", voice, cache: true)
            for (label, cache, schedule) in configs {
                engine.options.prefixCache = cache; engine.options.chunkFrames = schedule
                var firsts: [Double] = []; var rtf: [Double] = []
                for _ in 0..<6 {
                    let t0 = Date(); var fa = 0.0
                    let r = try engine.render(text: "Good evening, you are tuned in to Gloam F M.", voice: voice, seed: 7,
                                              onAudio: { _ in if fa == 0 { fa = Date().timeIntervalSince(t0) } })
                    firsts.append(fa); rtf.append(r.timings.total / r.audioSeconds)
                }
                firsts.sort(); rtf.sort()
                print("MEASURE first-audio \(name) [\(label)] median ms \(String(format: "%.0f", firsts[3] * 1000)) min \(String(format: "%.0f", firsts[0] * 1000)) rtf \(String(format: "%.2f", rtf[3]))")
            }
        }
        engine.options.chunkFrames = [12]; engine.options.prefixCache = true
    }
}
