import Foundation
import XCTest
@testable import QwenANE

final class QwenSilenceTests: XCTestCase {
    let sr = 24000

    /// Speech-like burst: a few harmonics with a syllable-rate envelope, peak about `amp`.
    func speech(_ seconds: Double, amp: Float = 0.3, phase: Double = 0) -> [Float] {
        let n = Int(seconds * Double(sr))
        return (0..<n).map { i in
            let t = Double(i) / Double(sr) + phase
            let env = 0.6 + 0.4 * sin(2 * .pi * 4 * t)
            let s = sin(2 * .pi * 140 * t) + 0.5 * sin(2 * .pi * 420 * t) + 0.25 * sin(2 * .pi * 1100 * t)
            return amp * Float(env * s) / 1.75
        }
    }
    func gap(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(sr))) }
    func noiseGap(_ seconds: Double, amp: Float) -> [Float] {   // room tone, deterministic
        var g = SystemRandomNumberGeneratorStub(seed: 1)
        return (0..<Int(seconds * Double(sr))).map { _ in amp * (Float(g.next()) * 2 - 1) }
    }
    func maxJump(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($0 - $1) }.max() ?? 0 }

    func testLongInternalPauseIsCappedToKeep() {
        let x = speech(1.5) + gap(3.0) + speech(1.5)
        let rep = QwenSilence.analyze(samples: x, sampleRate: sr)
        XCTAssertEqual(rep.longestPause, 3.0, accuracy: 0.05)
        XCTAssertEqual(rep.longestPauseAt, 1.5, accuracy: 0.05)
        XCTAssertEqual(rep.pausesOverThreshold, 1)
        let c = QwenSilence.cap(samples: x, sampleRate: sr)
        XCTAssertEqual(c.pausesCapped, 1)
        let after = QwenSilence.analyze(samples: c.samples, sampleRate: sr)
        XCTAssertEqual(after.longestPause, 0.45, accuracy: 0.05)
        XCTAssertEqual(after.pausesOverThreshold, 0)
        XCTAssertEqual(Double(c.samples.count) / Double(sr), 3.45, accuracy: 0.05)
    }

    func testSpeechSamplesUntouched() {
        let a = speech(1.0), b = speech(1.0, phase: 0.3)
        let x = a + gap(2.0) + b
        let y = QwenSilence.capPauses(samples: x, sampleRate: sr)
        XCTAssertEqual(Array(y.prefix(a.count)), a)
        XCTAssertEqual(Array(y.suffix(b.count)), b)
    }

    func testLeadingAndTrailingTrimmed() {
        let x = gap(1.0) + speech(2.0) + gap(1.2)
        let rep = QwenSilence.analyze(samples: x, sampleRate: sr)
        XCTAssertEqual(rep.leading, 1.0, accuracy: 0.03)
        XCTAssertEqual(rep.trailing, 1.2, accuracy: 0.03)
        let y = QwenSilence.capPauses(samples: x, sampleRate: sr)
        let after = QwenSilence.analyze(samples: y, sampleRate: sr)
        XCTAssertLessThanOrEqual(after.leading, 0.07)
        XCTAssertLessThanOrEqual(after.trailing, 0.12)
        XCTAssertEqual(Double(y.count) / Double(sr), 2.0 + 0.05 + 0.1, accuracy: 0.04)
    }

    func testNothingToCutIsBitIdentical() {
        let x = gap(0.03) + speech(1.0) + gap(0.5) + speech(1.0, phase: 0.2) + gap(0.65) + speech(0.5) + gap(0.08)
        let c = QwenSilence.cap(samples: x, sampleRate: sr)
        XCTAssertEqual(c.samples, x)
        XCTAssertEqual(c.pausesCapped, 0)
    }

    func testNoClicksAtSplice() {
        // Silence with low room tone, so the splice joins two different noise stretches.
        let x = speech(1.0) + noiseGap(2.5, amp: 0.0004) + speech(1.0, phase: 0.1)
        let y = QwenSilence.capPauses(samples: x, sampleRate: sr)
        XCTAssertLessThan(y.count, x.count - sr)
        XCTAssertLessThanOrEqual(maxJump(y), maxJump(x) * 1.01 + 1e-6)
        // the splice region itself (inside the pause) stays at room-tone level
        let lo = sr + sr / 5, hi = y.count - sr - sr / 5
        XCTAssertLessThan(y[lo..<hi].map { abs($0) }.max() ?? 0, 0.002)
    }

    func testQuietVoiceStillDetected() {
        let amp = Float(0.01)                       // about -43 dBFS peak, quieter in RMS
        let x = speech(1.0, amp: amp) + gap(2.0) + speech(1.0, amp: amp)
        let rep = QwenSilence.analyze(samples: x, sampleRate: sr)
        XCTAssertEqual(rep.longestPause, 2.0, accuracy: 0.05)
        XCTAssertEqual(QwenSilence.cap(samples: x, sampleRate: sr).pausesCapped, 1)
    }

    func testBreathCountsAsSpeech() {
        // Speech at -20 dBFS-ish RMS, a breath 25 dB lower: not silence, so the "pause" is two short gaps.
        let breath = noiseGap(0.6, amp: 0.3 * 0.05)   // about -26 dB re the 0.3 speech peak
        let x = speech(1.0) + gap(0.4) + breath + gap(0.4) + speech(1.0)
        let rep = QwenSilence.analyze(samples: x, sampleRate: sr)
        XCTAssertLessThan(rep.longestPause, 0.5)
        XCTAssertEqual(QwenSilence.capPauses(samples: x, sampleRate: sr), x)
    }

    func testAllSilenceAndTinyInputUnchanged() {
        XCTAssertEqual(QwenSilence.capPauses(samples: gap(2), sampleRate: sr), gap(2))
        XCTAssertEqual(QwenSilence.capPauses(samples: [], sampleRate: sr), [])
        XCTAssertEqual(QwenSilence.capPauses(samples: [0.1, 0.2], sampleRate: sr), [0.1, 0.2])
    }
    // MARK: opt-in, real data

    /// 16-bit PCM mono WAV reader (scan helper).
    private func readWav(_ url: URL) -> ([Float], Int)? {
        guard let d = try? Data(contentsOf: url), d.count > 44 else { return nil }
        var o = 12, rate = 24000
        while o + 8 <= d.count {
            let id = String(decoding: d[o..<(o + 4)], as: UTF8.self)
            let len = Int(d[o + 4]) | Int(d[o + 5]) << 8 | Int(d[o + 6]) << 16 | Int(d[o + 7]) << 24
            if id == "fmt " { rate = Int(d[o + 12]) | Int(d[o + 13]) << 8 | Int(d[o + 14]) << 16 }
            if id == "data" {
                let body = d[(o + 8)..<min(d.count, o + 8 + len)]
                let v = body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                return (v.map { Float($0) / 32768 }, rate)
            }
            o += 8 + len + (len & 1)
        }
        return nil
    }

    /// `QWEN_SILENCE_SCAN=dir1:dir2 swift test --filter testScanDirectories` prints one line per wav.
    func testScanDirectories() throws {
        guard let v = ProcessInfo.processInfo.environment["QWEN_SILENCE_SCAN"], !v.isEmpty else {
            throw XCTSkip("QWEN_SILENCE_SCAN is not set")
        }
        var n = 0, p07 = 0, p15 = 0, l03 = 0
        for dir in v.split(separator: ":") {
            let e = FileManager.default.enumerator(atPath: String(dir))
            while let f = e?.nextObject() as? String {
                guard f.hasSuffix(".wav") else { continue }
                guard let (x, rate) = readWav(URL(fileURLWithPath: String(dir)).appendingPathComponent(f)) else { continue }
                let r = QwenSilence.analyze(samples: x, sampleRate: rate)
                n += 1
                if r.longestPause > 0.7 { p07 += 1 }
                if r.longestPause > 1.5 { p15 += 1 }
                if r.leading > 0.3 { l03 += 1 }
                print(String(format: "SCAN %@ dur=%.1f lead=%.2f trail=%.2f longest=%.2f@%.1f over0.7=%d", "\(dir)/\(f)",
                             Double(x.count) / Double(rate), r.leading, r.trailing, r.longestPause, r.longestPauseAt, r.pausesOverThreshold))
            }
        }
        print("SCAN TOTAL files=\(n) pause>0.7=\(p07) pause>1.5=\(p15) lead>0.3=\(l03)")
    }

    /// Model-backed: render the ad read that had dead air and report the silence.
    @available(macOS 15.0, iOS 18.0, *)
    func testRenderReportsSilence() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "benson")
        let text = "Visit tinytrashlabs.com today. Tune your dial to 104.9 for the best of Gloam F M, all night long."
        let r = try engine.render(text: text, voice: voice, seed: 7)
        print("SILENCE before=\(r.silenceBefore) after=\(r.silence) capped=\(r.pausesCapped) audio=\(r.audioSeconds)s")
        XCTAssertGreaterThan(r.samples.count, 0)
        XCTAssertLessThanOrEqual(r.silence.longestPause, max(0.75, r.silenceBefore.longestPause))
        XCTAssertLessThanOrEqual(r.silence.leading, 0.1)
    }
}

/// Small deterministic generator (xorshift) so the tests do not depend on system randomness.
struct SystemRandomNumberGeneratorStub {
    var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s % 1_000_000) / 1_000_000
    }
}
