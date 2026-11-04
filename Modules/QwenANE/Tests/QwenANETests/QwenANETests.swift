import Foundation
import XCTest
@testable import QwenANE

/// Model-backed tests need the compiled Core ML models (see Sources/QwenANE/README.md):
///   QWEN_ANE_MODELS=/path/to/Models swift test --filter QwenANETests
/// They are skipped when the variable is unset, so CI stays green.
final class QwenANETests: XCTestCase {
    static let jeffText = "Good evening, you are tuned in to Gloam F M. Up next, a slow burner to take us into the night."

    /// Minimal reader for the little-endian int16 .npy fixtures (shape from the header).
    private func loadInt16(_ name: String) throws -> (values: [Int16], shape: [Int]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "npy", subdirectory: "Fixtures"))
        let d = try Data(contentsOf: url)
        let hlen = Int(d[8]) | Int(d[9]) << 8
        let header = String(decoding: d[10..<(10 + hlen)], as: UTF8.self)
        XCTAssertTrue(header.contains("<i2"))
        let inner = header.components(separatedBy: "'shape': (")[1].components(separatedBy: ")")[0]
        let shape = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let body = d.dropFirst(10 + hlen)
        let v = body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return (v, shape)
    }

    private func modelsDirectory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    // MARK: no models needed

    /// Values from numpy: `[np.random.default_rng(s).random() for _ in range(3)]`.
    func testRNGMatchesNumpy() {
        let cases: [(UInt64, [Double])] = [
            (0, [0.6369616873214543, 0.2697867137638703, 0.04097352393619469]),
            (7919, [0.6217577535206225, 0.3207553454347807, 0.5626704668174459]),
            (123456789012, [0.5660646750946614, 0.08367085961515452, 0.27992288213578664]),
        ]
        for (seed, want) in cases {
            var r = NumpyPCG64(seed: seed)
            XCTAssertEqual((0..<3).map { _ in r.uniform() }, want, "seed \(seed)")
        }
    }

    // MARK: with models

    private func frames(_ v: [Int16]) -> [[Int]] {
        (0..<(v.count / 16)).map { f in (0..<16).map { Int(v[f * 16 + $0]) } }
    }

    /// Teacher-forced parity: Swift is fed the Python reference's own codes frame by frame (same
    /// history on both sides) and must pick the same g0 (the seeded sampler stream) and the same 15
    /// sub-codes. This is the meaningful per-frame check: free-running, one fp16 near-tie flip
    /// (host fp32 sums differ from numpy in the last ulp) sends the two trajectories apart for good.
    @available(iOS 18.0, macOS 15.0, *)
    func testForcedParityWithPythonCodes() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        let ref = frames(try loadInt16("jeff_codes").values)
        engine.talker.forced = ref
        defer { engine.talker.forced = nil }
        _ = try engine.render(text: Self.jeffText, voice: voice, seed: 7)
        let picks = engine.talker.forcedPicks
        XCTAssertEqual(picks.count, ref.count)
        let same = zip(picks, ref).filter { $0 == $1 }.count
        let g0 = zip(picks, ref).filter { $0[0] == $1[0] }.count
        let subs = zip(picks, ref).reduce(0) { $0 + zip($1.0, $1.1).dropFirst().filter { $0 == $1 }.count }
        let pct = 100 * Double(same) / Double(ref.count)
        if ProcessInfo.processInfo.environment["QWEN_ANE_DEBUG"] != nil {
            for (f, (a, b)) in zip(picks, ref).enumerated() where a != b {
                let k = (0..<16).first { a[$0] != b[$0] }!
                print("DIFF frame \(f) first sub \(k): swift \(a[k]) py \(b[k])  n_diff \((0..<16).filter { a[$0] != b[$0] }.count)")
            }
        }
        print("QwenANE forced parity: \(same)/\(ref.count) frames identical (\(pct)%), g0 \(g0)/\(ref.count), sub-codes \(subs)/\(ref.count * 15)")
        // The sampled first codebook must match (seeded stream + talker logits). The 15 greedy sub-codes of the
        // code predictor flip on fp16 near-ties: nudging 3 speaker-embedding values by 0.05% already drops
        // whole-frame agreement to ~67%, so frame-exact equality is not a meaningful gate.
        XCTAssertGreaterThanOrEqual(100 * Double(g0) / Double(ref.count), 95)
        XCTAssertGreaterThanOrEqual(100 * Double(subs) / Double(ref.count * 15), 90)
        XCTAssertGreaterThanOrEqual(pct, 60)
    }

    /// Free-running render: same seed, same line. Reports how far it tracks the Python run; also checks
    /// the shape of the result, pacing, and that a re-run with the same seed is identical.
    @available(iOS 18.0, macOS 15.0, *)
    func testRenderIsDeterministicAndTracksPython() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        let ref = frames(try loadInt16("jeff_codes").values)
        var paced = 0
        let r = try engine.render(text: Self.jeffText, voice: voice, seed: 7, pace: { paced += 1 })
        let got = (0..<r.frames).map { f in (0..<16).map { Int(r.codes[f * 16 + $0]) } }
        var prefix = 0
        while prefix < min(got.count, ref.count), got[prefix] == ref[prefix] { prefix += 1 }
        let same = zip(got, ref).filter { $0 == $1 }.count
        print("QwenANE free-run: \(same)/\(ref.count) frames identical, first \(prefix) frames match, frames \(r.frames) (python \(ref.count)), stop \(r.stopReason)")
        print(String(format: "QwenANE timing: audio %.2fs total %.2fs (rtf %.2f) prompt %.2f prefill %.2f loop %.2f vocoder %.2f wait %.2f",
                     r.audioSeconds, r.timings.total, r.timings.total / r.audioSeconds,
                     r.timings.prompt, r.timings.prefill, r.timings.loop, r.timings.vocoder, r.timings.vocoderWait))
        XCTAssertGreaterThanOrEqual(prefix, 2)
        XCTAssertEqual(r.samples.count, r.frames * 1920)
        XCTAssertEqual(r.stopReason, .eos)
        XCTAssertGreaterThan(paced, r.frames)
        let again = try engine.render(text: Self.jeffText, voice: voice, seed: 7)
        XCTAssertEqual(again.codes, r.codes)
    }

    /// The overlapped vocoder must return exactly the samples of the inline path, for a primed
    /// voice, a cold start (no context), and a whole render.
    @available(iOS 18.0, macOS 15.0, *)
    func testOverlappedVocoderIsBitIdenticalToInline() throws {
        try QwenTestModels.requireSlow()
        let dir = try modelsDirectory()
        let codes = try loadInt16("jeff_codes")
        let frames = codes.values.count / 16
        let voc = try ANEVocoder(modelsDirectory: dir)
        let voice = try QwenVoiceFiles(directory: dir.appendingPathComponent("voices/jeff"))
        let c = codes.values.map { Int64($0) }
        for ctx in [voice.referenceFrames, nil] {
            voc.overlap = false
            let inline = try voc.decode(codes: c, frames: frames, context: ctx)
            voc.overlap = true
            let over = try voc.decode(codes: c, frames: frames, context: ctx)
            XCTAssertEqual(inline.count, frames * 1920)
            XCTAssertTrue(inline == over, "overlapped decode differs from inline (context \(ctx != nil))")
            // a partial last chunk (frames not a multiple of 12)
            let n = frames - 5
            voc.overlap = false
            let a = try voc.decode(codes: c, frames: n, context: ctx)
            voc.overlap = true
            let b = try voc.decode(codes: c, frames: n, context: ctx)
            XCTAssertTrue(a == b)
        }
        let engine = try QwenTestModels.engine()
        let v = try engine.loadVoice(named: "jeff")
        engine.options.overlapVocoder = false
        let r0 = try engine.render(text: Self.jeffText, voice: v, seed: 7)
        engine.options.overlapVocoder = true
        let r1 = try engine.render(text: Self.jeffText, voice: v, seed: 7)
        XCTAssertEqual(r0.codes, r1.codes)
        XCTAssertTrue(r0.samples == r1.samples, "render samples differ between inline and overlapped")
    }

    /// Prints per-stage timings for a short and a long line, inline vs overlapped, 2 runs each.
    @available(iOS 18.0, macOS 15.0, *)
    func testOverlapTimings() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        let long = Self.jeffText + " Stay with us. We have an hour of warm bass, soft keys, and a few voices you might not have heard in a while. The night is long, the dial is low, and nobody is in any kind of hurry. So settle in, and let the music find you."
        for (name, text) in [("short", Self.jeffText), ("long", long)] {
            for overlap in [false, true, false, true] {
                engine.options.overlapVocoder = overlap
                let r = try engine.render(text: text, voice: voice, seed: 7)
                let t = r.timings
                print(String(format: "QwenANE overlap=%@ %@: audio %.2fs wall %.2fs rtf %.2f | prompt %.2f prefill %.2f loop %.2f vocoder %.2f wait %.2f",
                             overlap ? "on " : "off", name, r.audioSeconds, t.total, t.total / r.audioSeconds,
                             t.prompt, t.prefill, t.loop, t.vocoder, t.vocoderWait))
            }
        }
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testCancelReturnsNoSamples() throws {
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        var calls = 0
        let r = try engine.render(text: Self.jeffText, voice: voice, seed: 1, cancelled: { calls += 1; return calls > 3 })
        XCTAssertEqual(r.stopReason, .cancelled)
        XCTAssertTrue(r.samples.isEmpty)
    }

    /// Fixed codes through the primed ANE vocoder vs the ORT full-reference decode (reference
    /// codes ahead of the line, their audio dropped).
    @available(iOS 18.0, macOS 15.0, *)
    func testPrimedVocoderMatchesORT() throws {
        try QwenTestModels.requireSlow()
        let dir = try modelsDirectory()
        let codes = try loadInt16("jeff_codes"), want = try loadInt16("jeff_vocoder_ref")
        let frames = want.values.count / 1920
        let voc = try ANEVocoder(modelsDirectory: dir)
        let voice = try QwenVoiceFiles(directory: dir.appendingPathComponent("voices/jeff"))
        let c = (0..<(frames * 16)).map { Int64(codes.values[$0]) }
        let got = try voc.decode(codes: c, frames: frames, context: voice.referenceFrames)
        XCTAssertEqual(got.count, want.values.count)
        var sig = 0.0, err = 0.0
        for i in 0..<min(got.count, want.values.count) {
            let w = Double(want.values[i]) / 32767
            sig += w * w; err += (Double(got[i]) - w) * (Double(got[i]) - w)
        }
        let snr = 10 * log10(sig / max(err, 1e-30))
        // unprimed (cold) start, to show what priming fixes
        let cold = try voc.decode(codes: c, frames: frames, context: nil)
        var errCold = 0.0
        for i in 0..<min(cold.count, want.values.count) { let w = Double(want.values[i]) / 32767; errCold += (Double(cold[i]) - w) * (Double(cold[i]) - w) }
        print(String(format: "QwenANE vocoder SNR primed %.1f dB, cold %.1f dB", snr, 10 * log10(sig / max(errCold, 1e-30))))
        XCTAssertGreaterThanOrEqual(snr, 40)
    }
}
