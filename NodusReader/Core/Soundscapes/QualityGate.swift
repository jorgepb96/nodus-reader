// SPDX-License-Identifier: AGPL-3.0-only
import Accelerate
import AVFoundation
import Foundation
import SoundAnalysis
import StableAudioMLX

enum QualityVerdict: Equatable, Sendable {
    case accept
    case reject(String)
}

/// What a generated piece must satisfy before it enters the cache. Everything runs on
/// the device; a rejected piece is discarded and planned again later.
enum QualityGate {
    /// Loudness targets shared with the catalog pipeline.
    static func target(for layer: CatalogTrack.Layer) -> (lufs: Double, truePeak: Double) {
        layer == .music ? (-20, -1.5) : (-28, -3)
    }

    /// More gain than this to reach the target means a near-silent piece whose noise
    /// would be raised with it.
    static let maximumGainDB = 15.0
    /// Ambience beds loop: a larger 1 s level spread means an event (a thunderclap) that
    /// would repeat audibly.
    static let maximumAmbienceSpreadDB = 10.0

    static func check(_ channels: [[Float]], sampleRate: Int, layer: CatalogTrack.Layer,
                      minimumUsefulSeconds: Double) -> QualityVerdict {
        guard !channels.isEmpty, channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            return .reject("non-finite samples")
        }
        let loudness = SA3Audio.integratedLoudness(channels, sampleRate: sampleRate)
        if target(for: layer).lufs - loudness > maximumGainDB { return .reject("too quiet") }
        let range = SA3Audio.loopableRange(channels, sampleRate: sampleRate)
        if layer == .ambience {
            let useful = channels.map { Array($0[range]) }
            if SA3Audio.levels(useful, sampleRate: sampleRate).oneSecondRMSSpreadDB > maximumAmbienceSpreadDB {
                return .reject("unsteady ambience")
            }
        }
        if Double(range.count) / Double(sampleRate) < minimumUsefulSeconds { return .reject("too short") }
        return .accept
    }

    // MARK: Seams

    /// A loop's seam is acceptable when the level does not jump across it (the second
    /// before and the second after within 3 dB), the sample step across it is smaller
    /// than the material's 99th-percentile step, and the spectral change across it is
    /// below 1.5× the median 20 ms change. Same measures as `audiotool seam`.
    static func seamAcceptable(_ loop: [[Float]], sampleRate: Int) -> Bool {
        let n = loop.first?.count ?? 0
        guard n > 4 * sampleRate else { return false }
        let tail = level(loop, (n - sampleRate) ..< n)
        let head = level(loop, 0 ..< sampleRate)
        guard abs(tail - head) <= 3 else { return false }
        return stepRatio(loop) < 1 && fluxRatio(loop, sampleRate: sampleRate) < 1.5
    }

    private static func level(_ channels: [[Float]], _ range: Range<Int>) -> Double {
        var sum = 0.0
        for channel in channels { for i in range { sum += Double(channel[i] * channel[i]) } }
        return 10 * log10(max(sum / Double(range.count * channels.count), 1e-12))
    }

    static func stepRatio(_ channels: [[Float]]) -> Double {
        var ratio = 0.0
        for channel in channels {
            let n = channel.count
            guard n > 2 else { continue }
            let seamStep = abs(channel[0] - channel[n - 1])
            var steps: [Float] = []
            var i = 1
            let stride = max(n / 20_000, 1)
            while i < n {
                steps.append(abs(channel[i] - channel[i - 1]))
                i += stride
            }
            steps.sort()
            let typical = max(steps[Int(Double(steps.count) * 0.99)], 1e-6)
            ratio = max(ratio, Double(seamStep / typical))
        }
        return ratio
    }

    static func fluxRatio(_ channels: [[Float]], sampleRate: Int) -> Double {
        let n = channels.first?.count ?? 0
        let log2n = 10
        let size = 1 << log2n
        guard n > 4 * size,
              let setup = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)
        else { return 0 }
        let mono = (0 ..< n).map { i in channels.reduce(0) { $0 + $1[i] } / Float(channels.count) }
        func spectrum(_ frame: ArraySlice<Float>) -> [Float] {
            let window = vDSP.multiply(Array(frame), vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                                                 count: size, isHalfWindow: false))
            var real = [Float](repeating: 0, count: size / 2)
            var imaginary = [Float](repeating: 0, count: size / 2)
            var magnitudes = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    window.withUnsafeBytes {
                        vDSP.convert(interleavedComplexVector: Array($0.bindMemory(to: DSPComplex.self)), toSplitComplexVector: &split)
                    }
                    setup.forward(input: split, output: &split)
                    vDSP.absolute(split, result: &magnitudes)
                }
            }
            return magnitudes.map { log10($0 + 1e-6) }
        }
        func flux(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
            vDSP.distanceSquared(spectrum(a), spectrum(b)).squareRoot()
        }
        let across = flux(mono[(n - size)...], mono[0 ..< size])
        var typical: [Float] = []
        var offset = size
        let hop = max((n - 2 * size) / 300, size)
        while offset + size <= n {
            typical.append(flux(mono[(offset - size) ..< offset], mono[offset ..< (offset + size)]))
            offset += hop
        }
        typical.sort()
        let median = typical.isEmpty ? 1 : typical[typical.count / 2]
        return Double(across / max(median, 1e-6))
    }

    // MARK: Voices

    /// Fraction of ~1.5 s windows that Apple's built-in sound classifier hears as speech
    /// or singing (confidence ≥ 0.5). Calibrated on 2026-11-06: 19 generated
    /// instrumentals and ambiences gave 0 % (highest confidence 0.08 speech, 0.37
    /// singing); a spoken sentence gave 100 % (0.88).
    static func voiceFraction(_ channels: [[Float]], sampleRate: Int) throws -> Double {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SA3Audio.writeWAV(channels, sampleRate: sampleRate, to: url)
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let observer = VoiceObserver()
        try analyzer.add(SNClassifySoundRequest(classifierIdentifier: .version1), withObserver: observer)
        analyzer.analyze()
        return observer.fraction
    }

    /// Rejection threshold for `voiceFraction`.
    static let maximumVoiceFraction = 0.1

    private final class VoiceObserver: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var windows = 0
        private var voiced = 0

        var fraction: Double {
            lock.lock(); defer { lock.unlock() }
            return windows == 0 ? 0 : Double(voiced) / Double(windows)
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
            let singing = result.classification(forIdentifier: "singing")?.confidence ?? 0
            lock.lock()
            windows += 1
            if speech >= 0.5 || singing >= 0.5 { voiced += 1 }
            lock.unlock()
        }
    }
}
