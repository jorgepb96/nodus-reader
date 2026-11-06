import Accelerate
import AVFoundation
import Foundation

public enum SA3Audio {
    /// An AVAudioPCMBuffer (non-interleaved float32) holding `channels`.
    public static func buffer(_ channels: [[Float]], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let first = channels.first,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(first.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(first.count)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { source in
                buffer.floatChannelData![index].update(from: source.baseAddress!, count: channel.count)
            }
        }
        return buffer
    }

    /// Writes AAC-LC (variable bit rate around `bitRate`) in an `.m4a`. The encoder's
    /// priming is recorded in the file, so decoding returns exactly the written frames,
    /// which seamless loops depend on. Returns the frame count.
    @discardableResult
    public static func writeAAC(_ channels: [[Float]], sampleRate: Int, bitRate: Int, to url: URL) throws -> Int64 {
        guard let buffer = buffer(channels, sampleRate: sampleRate) else { return 0 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count, AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained,
        ]
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return Int64(buffer.frameLength)
    }

    /// Writes 32-bit float WAV (lossless, so the loop seam is not altered by a codec).
    public static func writeWAV(_ channels: [[Float]], sampleRate: Int, to url: URL) throws {
        guard let buffer = buffer(channels, sampleRate: sampleRate) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// The part of a clip worth looping: Stable Audio composes a whole piece for the
    /// requested length, so music usually fades out over its last seconds and some
    /// effects start with a quiet lead-in. Leading and trailing 0.5 s windows more than
    /// `dropDB` below the median level are cut. Returns sample indices.
    public static func loopableRange(_ channels: [[Float]], sampleRate: Int, dropDB: Double = 9) -> Range<Int> {
        let window = sampleRate / 2
        let n = channels.first?.count ?? 0
        guard n >= window * 4 else { return 0 ..< n }
        var levels: [Double] = []
        var start = 0
        while start + window <= n {
            let sum = channels.reduce(0.0) { $0 + Double(vDSP.sumOfSquares($1[start ..< (start + window)])) }
            levels.append(10 * log10(max(sum / Double(window * channels.count), 1e-12)))
            start += window
        }
        let median = levels.sorted()[levels.count / 2]
        let floor = median - dropDB
        let first = levels.firstIndex { $0 >= floor } ?? 0
        let last = levels.lastIndex { $0 >= floor } ?? (levels.count - 1)
        return (first * window) ..< min((last + 1) * window, n)
    }

    /// A seamless loop: inside the loopable range, the region after `seam` seconds, whose
    /// last `seam` seconds are crossfaded (equal power) with the `seam` seconds that
    /// precede the region. The end then flows sample-exactly into the beginning. Same
    /// method as `tools/immersive-audio/audiotool loop`. Returns nil when the clip is too
    /// short.
    public static func loop(_ channels: [[Float]], sampleRate: Int, seam: Double, trim: Bool = true) -> [[Float]]? {
        let range = trim ? loopableRange(channels, sampleRate: sampleRate) : 0 ..< (channels.first?.count ?? 0)
        let f = Int(seam * Double(sampleRate))
        let start = range.lowerBound + f
        let length = range.upperBound - start
        guard f > 0, length > 2 * f else { return nil }
        return channels.map { channel in
            var out = Array(channel[start ..< (start + length)])
            for i in 0 ..< f {
                let x = (Double(i) + 0.5) / Double(f)
                let tail = channel[start + length - f + i]
                let lead = channel[start - f + i]
                out[length - f + i] = Float(cos(x * .pi / 2)) * tail + Float(sin(x * .pi / 2)) * lead
            }
            return out
        }
    }

    /// Level of the `seconds` around the loop point (end + start) relative to the
    /// clip's median 0.5 s level, in dB. Near 0 means no audible dip or bump at the seam.
    public static func seamLevelDelta(_ channels: [[Float]], sampleRate: Int, seconds: Double = 1) -> Double {
        let n = channels.first?.count ?? 0
        let k = min(Int(seconds * Double(sampleRate)), n / 4)
        guard k > 0 else { return 0 }
        func level(_ ranges: [Range<Int>]) -> Double {
            var sum: Double = 0
            var count = 0
            for channel in channels {
                for range in ranges {
                    sum += Double(vDSP.sumOfSquares(channel[range]))
                    count += range.count
                }
            }
            return 10 * log10(max(sum / Double(max(count, 1)), 1e-12))
        }
        let window = sampleRate / 2
        var levels: [Double] = []
        var start = 0
        while start + window <= n {
            levels.append(level([start ..< (start + window)]))
            start += window
        }
        let median = levels.isEmpty ? 0 : levels.sorted()[levels.count / 2]
        return level([(n - k / 2) ..< n, 0 ..< (k / 2)]) - median
    }

    /// Peak and RMS (dBFS) over the whole clip, and the spread of 1 s RMS values (dB):
    /// a large spread means the level drifts, which a looped bed should not do.
    public static func levels(_ channels: [[Float]], sampleRate: Int) -> (peakDB: Double, rmsDB: Double, oneSecondRMSSpreadDB: Double) {
        var peak: Float = 0
        var sum: Double = 0
        var count = 0
        var windows: [Double] = []
        let n = channels.first?.count ?? 0
        var start = 0
        while start < n {
            let end = min(start + sampleRate, n)
            var windowSum: Double = 0
            for channel in channels {
                let slice = channel[start ..< end]
                peak = max(peak, vDSP.maximumMagnitude(slice))
                windowSum += Double(vDSP.sumOfSquares(slice))
            }
            sum += windowSum
            count += (end - start) * channels.count
            if end - start == sampleRate {
                windows.append(10 * log10(max(windowSum / Double((end - start) * channels.count), 1e-12)))
            }
            start = end
        }
        let rms = 10 * log10(max(sum / Double(max(count, 1)), 1e-12))
        let spread = (windows.max() ?? 0) - (windows.min() ?? 0)
        return (20 * log10(max(Double(peak), 1e-9)), rms, spread)
    }
}

// MARK: - Loudness (ITU-R BS.1770-4)

public extension SA3Audio {
    /// Integrated loudness in LUFS: K-weighting, 400 ms blocks with 75 % overlap,
    /// absolute gate at −70 LUFS and relative gate at −10 LU. Front channels weigh 1.
    static func integratedLoudness(_ channels: [[Float]], sampleRate: Int) -> Double {
        let weighted = channels.map { kWeighted($0, sampleRate: Double(sampleRate)) }
        let n = weighted.first?.count ?? 0
        let block = Int(0.4 * Double(sampleRate))
        let hop = block / 4
        guard n >= block else { return -70 }
        var energies: [Double] = []
        var start = 0
        while start + block <= n {
            var z = 0.0
            for channel in weighted {
                z += Double(vDSP.sumOfSquares(channel[start ..< (start + block)])) / Double(block)
            }
            energies.append(z)
            start += hop
        }
        func loudness(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let absolute = energies.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return -70 }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        return loudness(gated.reduce(0, +) / Double(max(gated.count, 1)))
    }

    /// True peak in dBTP, estimated with 4× windowed-sinc oversampling (Accelerate, so
    /// it stays fast in unoptimised builds too).
    static func truePeak(_ channels: [[Float]]) -> Double {
        let taps = 12 // per phase, each side
        var peak: Float = 0
        for channel in channels where !channel.isEmpty {
            peak = max(peak, vDSP.maximumMagnitude(channel))
            guard channel.count > 2 * taps else { continue }
            for phase in 1 ..< 4 {
                let frac = Double(phase) / 4
                let kernel: [Float] = (-taps + 1 ... taps).map { k in
                    let x = Double(k) - frac
                    let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                    return Float(sinc * (0.5 + 0.5 * cos(.pi * x / Double(taps))))
                }
                // correlate: out[n] = Σ_k channel[n + k] · kernel[k], the value between
                // samples n + taps − 1 and n + taps.
                peak = max(peak, vDSP.maximumMagnitude(vDSP.correlate(channel, withKernel: kernel)))
            }
        }
        return 20 * log10(max(Double(peak), 1e-9))
    }

    /// One fixed gain (no compression), like the catalog pipeline: reach `targetLUFS`
    /// unless that would push the true peak above `ceilingDBTP`, in which case the
    /// ceiling wins and the result is quieter than the target.
    static func level(_ channels: [[Float]], sampleRate: Int, targetLUFS: Double, ceilingDBTP: Double)
        -> (channels: [[Float]], gainDB: Double, loudness: Double, truePeak: Double) {
        let loudness = integratedLoudness(channels, sampleRate: sampleRate)
        let peak = truePeak(channels)
        let gainDB = min(targetLUFS - loudness, ceilingDBTP - peak)
        let gain = Float(pow(10, gainDB / 20))
        let out = channels.map { $0.map { $0 * gain } }
        return (out, gainDB, loudness + gainDB, peak + gainDB)
    }

    private static func kWeighted(_ x: [Float], sampleRate fs: Double) -> [Float] {
        // Stage 1: high shelf (+4 dB above ~1.7 kHz). Stage 2: high-pass at ~38 Hz.
        // Bilinear-transform coefficients for any sample rate, as libebur128 (MIT) and
        // ffmpeg's ebur128 derive them; identical to BS.1770's table at 48 kHz.
        func shelf() -> [Double] {
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let k = tan(.pi * f0 / fs)
            let vh = pow(10, g / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            return [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                    1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        }
        func highPass() -> [Double] {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(.pi * f0 / fs)
            let a0 = 1 + k / q + k * k
            return [1, -2, 1, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        }
        // vDSP's biquad takes [b0, b1, b2, a1, a2] per section with a0 = 1.
        let sections = [shelf(), highPass()].flatMap { k in [k[0], k[1], k[2], k[4], k[5]].map { $0 / k[3] } }
        guard var filter = vDSP.Biquad(coefficients: sections, channelCount: 1, sectionCount: 2, ofType: Float.self) else {
            return x
        }
        return filter.apply(input: x)
    }
}
