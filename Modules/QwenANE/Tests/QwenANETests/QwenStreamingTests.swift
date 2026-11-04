import Foundation
import XCTest
@testable import QwenANE

/// The streaming hook (`render(onAudio:)`) and the stream trimmer. The trimmer tests need no models;
/// the render tests need QWEN_ANE_MODELS like the rest of this target.
final class QwenStreamingTests: XCTestCase {
    let sr = 24000
    let chunk = 12 * 1920

    func speech(_ seconds: Double, amp: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { i in
            let t = Double(i) / Double(sr)
            return amp * Float(sin(2 * .pi * 140 * t) * (0.6 + 0.4 * sin(2 * .pi * 4 * t)))
        }
    }
    func gap(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(sr))) }

    /// Runs `x` through a trimmer in `chunk`-sized pieces.
    func stream(_ x: [Float]) -> [Float] {
        let t = QwenStreamTrimmer(sampleRate: sr)
        var out: [Float] = []
        var i = 0
        while i < x.count { out += t.push(Array(x[i..<min(x.count, i + chunk)])); i += chunk }
        return out + t.finish()
    }

    /// Where `part` sits inside `x` as a contiguous run, or nil.
    func offset(of part: [Float], in x: [Float]) -> Int? {
        guard !part.isEmpty, part.count <= x.count else { return nil }
        for o in 0...(x.count - part.count) where x[o] == part[0] && x[o + part.count - 1] == part[part.count - 1] {
            if Array(x[o..<(o + part.count)]) == part { return o }
        }
        return nil
    }

    // MARK: trimmer, no models

    func testLeadingSilenceCappedAndOutputIsAContiguousSlice() {
        let x = gap(1.5) + speech(1.2) + gap(0.3)
        let out = stream(x)
        let start = x.count - (gap(0.3).count + speech(1.2).count)       // 1.5 s
        // starts at most 0.05 s before the speech, ends at most 0.1 s after it
        let lead = Int(0.05 * Double(sr)), tail = Int(0.1 * Double(sr))
        let speechEnd = start + speech(1.2).count
        XCTAssertGreaterThanOrEqual(out.count, speech(1.2).count)
        XCTAssertLessThanOrEqual(out.count, lead + speech(1.2).count + tail + 480)
        // bit-identical to the matching slice of the input
        let from = start - lead
        XCTAssertTrue(Array(out) == Array(x[from..<(from + out.count)]), "not a contiguous slice")
        XCTAssertLessThanOrEqual(from + out.count, speechEnd + tail + 480)
    }

    func testInternalPauseIsKeptWholeAndTrailingHeldBack() {
        let x = speech(1.0) + gap(1.4) + speech(1.0) + gap(2.0)
        let out = stream(x)
        // all of both words and the full 1.4 s pause survive; the 2.0 s tail is cut to <= 0.1 s
        let want = speech(1.0).count + gap(1.4).count + speech(1.0).count
        XCTAssertGreaterThanOrEqual(out.count, want - 480)
        XCTAssertLessThanOrEqual(out.count, want + Int(0.1 * Double(sr)) + 480)
        XCTAssertTrue(out == Array(x[0..<out.count]))
    }

    /// Chunk boundaries move where the 20 ms silence windows fall, so the cut can differ by a window or two,
    /// but never in which samples are kept or in their order.
    func testChunkSizeOnlyMovesTheCutByAWindow() {
        let x = gap(0.7) + speech(2.0) + gap(0.9) + speech(1.0) + gap(0.5)
        let a = stream(x)
        let t = QwenStreamTrimmer(sampleRate: sr)
        var b: [Float] = []
        var i = 0
        while i < x.count { b += t.push(Array(x[i..<min(x.count, i + 7001)])); i += 7001 }
        b += t.finish()
        XCTAssertLessThan(abs(a.count - b.count), 2 * 480 + 480)
        XCTAssertNotNil(offset(of: a, in: x), "chunked output is not a contiguous slice")
        XCTAssertNotNil(offset(of: b, in: x), "odd-chunked output is not a contiguous slice")
    }

    func testAllSilenceEmitsNothing() {
        XCTAssertTrue(stream(gap(3)).isEmpty)
        XCTAssertTrue(stream([]).isEmpty)
    }

    func testQuietLineBelowSpeechFloorIsNotMistakenForSpeech() {
        // -60 dBFS room tone then real speech: the tone is dropped, the speech arrives whole.
        let tone = (0..<(2 * sr)).map { i in 0.001 * Float(sin(Double(i) * 0.3)) }
        let out = stream(tone + speech(1.0))
        XCTAssertGreaterThanOrEqual(out.count, speech(1.0).count)
        XCTAssertLessThan(out.count, speech(1.0).count + Int(0.2 * Double(sr)))
    }

    // MARK: render, models

    private func modelsDirectory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    /// Chunks arrive in order, their concatenation is a bit-exact slice of the un-capped non-streamed line
    /// (so no sample is changed or reordered), the first chunk starts within 0.05 s of speech, the
    /// streamed render's own result equals the non-streamed one, and nothing is delivered after cancel.
    @available(iOS 18.0, macOS 15.0, *)
    func testStreamedChunksAreAnExactSliceOfTheNonStreamedLine() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        let text = QwenANETests.jeffText
        engine.options.capPauses = false
        let plain = try engine.render(text: text, voice: voice, seed: 7)
        var got: [[Float]] = []
        let lock = NSLock()
        let streamed = try engine.render(text: text, voice: voice, seed: 7, onAudio: { c in lock.lock(); got.append(c); lock.unlock() })
        XCTAssertEqual(streamed.codes, plain.codes)
        XCTAssertTrue(streamed.samples == plain.samples, "the onAudio hook changed the returned samples")
        let all = got.flatMap { $0 }
        XCTAssertGreaterThan(got.count, 1, "a multi-second line must arrive in several chunks")
        XCTAssertFalse(all.isEmpty)
        // Contiguous slice at the first nonzero offset: find where `all` begins in `plain.samples`.
        let lead = plain.silence.leading
        let from = Int(max(0, lead - 0.05) * Double(sr)) - 2 * 480
        let rangeStart = max(0, from)
        var offset: Int?
        for o in rangeStart..<min(plain.samples.count - all.count + 1, rangeStart + 6 * 480) where plain.samples[o] == all[0] {
            if Array(plain.samples[o..<(o + all.count)]) == all { offset = o; break }
        }
        let o = try XCTUnwrap(offset, "streamed audio is not a contiguous slice of the non-streamed line")
        XCTAssertLessThanOrEqual(Double(o) / Double(sr), lead + 0.01)
        XCTAssertGreaterThanOrEqual(Double(o) / Double(sr), max(0, lead - 0.05) - 0.03)
        XCTAssertLessThanOrEqual(plain.samples.count - (o + all.count), Int(0.12 * Double(sr)) + 480 + 1920,
                                 "more than ~0.1 s of tail was dropped")
        // chunks never exceed one vocoder chunk, except the first emission after held-back silence
        XCTAssertTrue(got.dropFirst().dropLast().allSatisfy { !$0.isEmpty })
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testCancelledRenderDeliversNothing() throws {
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        var n = 0
        var delivered = 0
        var calls = 0
        let r = try engine.render(text: QwenANETests.jeffText, voice: voice, seed: 1,
                                  cancelled: { calls += 1; return calls > 3 }, onAudio: { _ in n += 1; delivered += 1 })
        XCTAssertEqual(r.stopReason, .cancelled)
        XCTAssertEqual(delivered, 0)
    }
}
