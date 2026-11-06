// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import StableAudioMLX
import Testing
@testable import Nodus_Reader

private let rate = 44_100

private func sine(_ frequency: Double, amplitude: Float, seconds: Double) -> [[Float]] {
    let n = Int(seconds * Double(rate))
    let x = (0 ..< n).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / Double(rate))) }
    return [x, x]
}

/// Deterministic broadband noise at a fixed level, `seconds` long.
private func noise(level: Float, seconds: Double, seed: UInt64 = 7) -> [[Float]] {
    var state = seed
    func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }
    let n = Int(seconds * Double(rate))
    return [(0 ..< n).map { _ in level * next() }, (0 ..< n).map { _ in level * next() }]
}

@Suite("Soundscape audio")
struct SoundscapeAudioTests {
    @Test func loudnessMatchesFFmpegReference() {
        // ffmpeg ebur128 on the same signals: 1 kHz → −20.0 LUFS, 100 Hz → −21.8 LUFS.
        #expect(abs(SA3Audio.integratedLoudness(sine(1_000, amplitude: 0.1, seconds: 10), sampleRate: rate) - -20.0) <= 0.1)
        #expect(abs(SA3Audio.integratedLoudness(sine(100, amplitude: 0.1, seconds: 10), sampleRate: rate) - -21.8) <= 0.1)
    }

    @Test func aacRoundTripKeepsExactLength() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aac-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try SA3Audio.writeAAC(noise(level: 0.1, seconds: 30), sampleRate: rate, bitRate: 128_000, to: url)
        #expect(frames == 1_323_000)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 1_323_000)
    }

    @Test func rejectsNonFinite() {
        var clip = noise(level: 0.1, seconds: 30)
        clip[0][100] = .nan
        #expect(QualityGate.check(clip, sampleRate: rate, layer: .ambience, minimumUsefulSeconds: 20) == .reject("non-finite samples"))
    }

    @Test func rejectsNearSilence() {
        // Ambience target −28 LUFS: a clip at about −50 LUFS needs more than +15 dB.
        let clip = noise(level: 0.004, seconds: 30)
        #expect(QualityGate.check(clip, sampleRate: rate, layer: .ambience, minimumUsefulSeconds: 20) == .reject("too quiet"))
    }

    @Test func acceptsSteadyAmbience() {
        #expect(QualityGate.check(noise(level: 0.05, seconds: 30), sampleRate: rate, layer: .ambience,
                                  minimumUsefulSeconds: 20) == .accept)
    }

    @Test func rejectsUnstableAmbience() {
        // Steady bed with a burst 30 dB louder: more than 10 dB of 1 s level spread.
        var clip = noise(level: 0.01, seconds: 30)
        for c in 0 ..< 2 { for i in (10 * rate) ..< (11 * rate) { clip[c][i] *= 31 } }
        #expect(QualityGate.check(clip, sampleRate: rate, layer: .ambience, minimumUsefulSeconds: 20) == .reject("unsteady ambience"))
    }

    @Test func rejectsShortMusic() {
        // 60 s of music whose last 30 s are silent: 30 useful seconds < 45.
        var clip = noise(level: 0.05, seconds: 60)
        for c in 0 ..< 2 { for i in (30 * rate) ..< clip[c].count { clip[c][i] = 0 } }
        #expect(QualityGate.check(clip, sampleRate: rate, layer: .music, minimumUsefulSeconds: 45) == .reject("too short"))
    }

    @Test func seamAcceptanceThresholds() {
        let steady = noise(level: 0.05, seconds: 20)
        #expect(QualityGate.seamAcceptable(steady, sampleRate: rate))
        // A loop whose last second is 20 dB quieter dips at the seam.
        var dipped = steady
        for c in 0 ..< 2 { for i in (19 * rate) ..< (20 * rate) { dipped[c][i] *= 0.1 } }
        #expect(!QualityGate.seamAcceptable(dipped, sampleRate: rate))
    }

    @Test func voiceFractionDetectsSpeech() throws {
        let speech = try SpeechFixture.clip()
        #expect(try QualityGate.voiceFraction(speech, sampleRate: rate) > 0.5)
    }

    @Test func instrumentalFixtureIsNotSpeech() throws {
        #expect(try QualityGate.voiceFraction(sine(220, amplitude: 0.1, seconds: 10), sampleRate: rate) < 0.1)
    }

    @Test func recipes() {
        #expect(GenerationRecipe.music.seconds == 60 && GenerationRecipe.music.continueTo == 120
                && GenerationRecipe.music.keepUntil == 55)
        #expect(GenerationRecipe.shortMusic.seconds == 60 && GenerationRecipe.shortMusic.continueTo == nil)
        #expect(GenerationRecipe.ambience.seconds == 60 && GenerationRecipe.shortAmbience.seconds == 30)
        #expect(GenerationRecipe.music.minimumUsefulSeconds == 90 && GenerationRecipe.shortMusic.minimumUsefulSeconds == 45)
    }
}

/// A spoken sentence rendered by the system voice, resampled to 44.1 kHz stereo.
enum SpeechFixture {
    static func clip() throws -> [[Float]] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "The ship sailed into the fog, and nobody on deck dared to speak until the lighthouse appeared over the rocks.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        var buffers: [AVAudioPCMBuffer] = []
        let done = DispatchSemaphore(value: 0)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { done.signal() } else { buffers.append(pcm) }
        }
        _ = done.wait(timeout: .now() + 30)
        guard let format = buffers.first?.format,
              let target = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let converter = AVAudioConverter(from: format, to: target) else { return [[], []] }
        var mono: [Float] = []
        for buffer in buffers {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Double(rate) / format.sampleRate) + 1_024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var fed = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            mono += Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        return [mono, mono]
    }
}
