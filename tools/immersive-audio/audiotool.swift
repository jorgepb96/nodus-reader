// SPDX-License-Identifier: AGPL-3.0-only
//
// DSP helpers for the Immersive Audio catalog pipeline (macOS, Accelerate).
// Build once:  swiftc -O -o build/immersive-audio/audiotool tools/immersive-audio/audiotool.swift
//
//   audiotool analyze <file>                       JSON: format, peaks, DC, clipping, channels, bandwidth, clicks
//   audiotool frames <file>                        decoded frame count as AVAudioFile reports it (priming trimmed)
//   audiotool loop <in> <out.wav> <start> <length> <seam>
//                                                  seconds; writes a loop whose end crossfades into its start
//   audiotool seam <file>                          JSON: step and spectral change across the loop point
//   audiotool fingerprint <file> <out.json>        Haitsma–Kalker style sub-fingerprints (32 bits / 11.6 ms)
//   audiotool compare <a.json> <b.json>            JSON: best bit error rate over offsets (< 0.35 = same audio)
import Accelerate
import AVFoundation
import Foundation

struct Fail: Error, CustomStringConvertible { let description: String }

func readAll(_ url: URL) throws -> (channels: [[Float]], rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw Fail(description: "cannot allocate")
    }
    try file.read(into: buffer)
    let count = Int(buffer.frameLength)
    let channels = (0..<Int(format.channelCount)).map { channel in
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: count))
    }
    return (channels, format.sampleRate)
}

func json(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func rms(_ x: ArraySlice<Float>) -> Float {
    var value: Float = 0
    x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
    return value
}

func db(_ x: Float) -> Double { 20 * log10(max(Double(x), 1e-9)) }

/// Magnitude spectrum (dB) of `frame` (power-of-two length) with a Hann window.
func spectrum(_ frame: [Float], setup: vDSP.FFT<DSPSplitComplex>, log2n: Int) -> [Float] {
    let n = frame.count
    var windowed = [Float](repeating: 0, count: n)
    let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    vDSP.multiply(frame, window, result: &windowed)
    var real = [Float](repeating: 0, count: n / 2)
    var imaginary = [Float](repeating: 0, count: n / 2)
    var magnitudes = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { r in
        imaginary.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            windowed.withUnsafeBufferPointer { w in
                w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                }
            }
            setup.forward(input: split, output: &split)
            vDSP.absolute(split, result: &magnitudes)
        }
    }
    return magnitudes
}

func mono(_ channels: [[Float]]) -> [Float] {
    guard channels.count > 1 else { return channels[0] }
    var sum = channels[0]
    for channel in channels.dropFirst() { vDSP.add(sum, channel, result: &sum) }
    return vDSP.multiply(1 / Float(channels.count), sum)
}

// MARK: analyze

func analyze(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let (channels, rate) = try readAll(url)
    var report: [String: Any] = [
        "sampleRate": rate, "channels": channels.count, "frames": channels[0].count,
        "seconds": Double(channels[0].count) / rate,
        "codec": file.fileFormat.settings[AVFormatIDKey] ?? 0,
    ]
    var peaks: [Double] = []
    var dcs: [Double] = []
    var rmsValues: [Double] = []
    var clippedRuns = 0
    var clicks = 0
    for channel in channels {
        peaks.append(db(vDSP.maximumMagnitude(channel)))
        dcs.append(Double(vDSP.mean(channel)))
        rmsValues.append(db(rms(channel[...])))
        // Clipping: runs of ≥ 3 consecutive samples at ≥ 0.999.
        var run = 0
        for sample in channel {
            if abs(sample) >= 0.999 { run += 1 } else { if run >= 3 { clippedRuns += 1 }; run = 0 }
        }
        // Discontinuities: a sample-to-sample step far above the local
        // level (a click), measured on 10 ms blocks.
        let block = max(Int(rate / 100), 1)
        var start = 1
        while start + block < channel.count {
            var largest: Float = 0
            var level: Float = 0
            for i in start..<(start + block) {
                largest = max(largest, abs(channel[i] - channel[i - 1]))
                level = max(level, abs(channel[i]))
            }
            let blockRMS = rms(channel[start..<(start + block)])
            if largest > 0.25, largest > 6 * blockRMS, level > 0.05 { clicks += 1 }
            start += block
        }
    }
    report["peakDBFS"] = peaks
    report["dcOffset"] = dcs
    report["rmsDBFS"] = rmsValues
    report["clippedRuns"] = clippedRuns
    report["clickBlocks"] = clicks
    if channels.count == 2 {
        let a = channels[0], b = channels[1]
        let dot = vDSP.dot(a, b)
        let norm = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        report["channelCorrelation"] = norm > 0 ? Double(dot / norm) : 0
        var difference = [Float](repeating: 0, count: a.count)
        vDSP.subtract(a, b, result: &difference)
        report["sideDBFS"] = db(rms(difference[...]))
    }
    // Effective bandwidth: highest frequency whose average level is within
    // 60 dB of the loudest band (an upsampled or low-passed source shows here).
    let signal = mono(channels)
    let log2n = 13
    let n = 1 << log2n
    if signal.count > n * 4, let setup = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self) {
        var sum = [Float](repeating: 0, count: n / 2)
        var frames = 0
        var offset = 0
        let step = max((signal.count - n) / 200, n)
        while offset + n <= signal.count {
            let magnitudes = spectrum(Array(signal[offset..<(offset + n)]), setup: setup, log2n: log2n)
            vDSP.add(sum, vDSP.multiply(magnitudes, magnitudes), result: &sum)
            frames += 1
            offset += step
        }
        let power = sum.map { Double($0) / Double(max(frames, 1)) }
        let loudest = power.max() ?? 1
        let threshold = loudest * 1e-6
        let last = power.lastIndex { $0 > threshold } ?? 0
        // Natural roll-off: the highest frequency within 60 dB of the loudest bin.
        report["bandwidthHz"] = Double(last) * rate / Double(n)
        // Brickwall: a sharp cliff (> 30 dB between neighbouring 500 Hz bands
        // above 8 kHz) is what lossy encoders and upsampled files leave;
        // instruments roll off gradually.
        let binHz = rate / Double(n)
        let width = max(Int(500 / binHz), 1)
        var bands: [(Double, Double)] = []
        var start = Int(8_000 / binHz)
        while start + width < power.count {
            let mean = power[start..<(start + width)].reduce(0, +) / Double(width)
            bands.append((Double(start) * binHz, 10 * log10(max(mean, 1e-30))))
            start += width
        }
        var cliff = (frequency: 0.0, drop: 0.0)
        for i in 0..<max(bands.count - 1, 0) {
            let drop = bands[i].1 - bands[i + 1].1
            if drop > cliff.drop { cliff = (bands[i + 1].0, drop) }
        }
        report["brickwallHz"] = cliff.drop > 30 ? cliff.frequency : 0
        report["brickwallDropDB"] = cliff.drop
    }
    json(report)
}

// MARK: loop

/// Writes `length` seconds from `start` whose last `seam` seconds are
/// crossfaded (equal power) with the `seam` seconds before `start`: the end
/// flows into the beginning sample-exactly, so the file loops seamlessly.
func loop(_ input: String, _ output: String, start: Double, length: Double, seam: Double) throws {
    let (channels, rate) = try readAll(URL(fileURLWithPath: input))
    let s = Int(start * rate), l = Int(length * rate), f = Int(seam * rate)
    guard s >= f, s + l <= channels[0].count, f > 0, f < l else {
        throw Fail(description: "loop region out of range (need \(seam) s before start)")
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count))!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(l))!
    buffer.frameLength = AVAudioFrameCount(l)
    for (index, channel) in channels.enumerated() {
        let out = buffer.floatChannelData![index]
        for i in 0..<l { out[i] = channel[s + i] }
        // The tail fades out while the audio that precedes the loop start
        // fades in: at the last sample it has become exactly what leads into
        // the first sample.
        for i in 0..<f {
            let x = (Double(i) + 0.5) / Double(f)
            let tail = channel[s + l - f + i]
            let lead = channel[s - f + i]
            out[l - f + i] = Float(cos(x * .pi / 2)) * tail + Float(sin(x * .pi / 2)) * lead
        }
    }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                   AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32,
                                   AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                   AVLinearPCMIsNonInterleaved: false]
    try? FileManager.default.removeItem(atPath: output)
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: output), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

// MARK: seam

/// How the loop point compares with the rest of the file: the sample step
/// across it relative to typical steps, and the spectral change across it
/// relative to typical 20 ms changes. Ratios near 1 mean the seam is as
/// smooth as the material itself.
func seam(_ path: String) throws {
    let (channels, rate) = try readAll(URL(fileURLWithPath: path))
    var stepRatio = 0.0
    for channel in channels {
        let n = channel.count
        let seamStep = abs(channel[0] - channel[n - 1])
        var steps: [Float] = []
        var i = 1
        while i < n { steps.append(abs(channel[i] - channel[i - 1])); i += max(n / 20_000, 1) }
        steps.sort()
        let typical = max(steps[Int(Double(steps.count) * 0.99)], 1e-6)
        stepRatio = max(stepRatio, Double(seamStep / typical))
    }
    let signal = mono(channels)
    let log2n = 10
    let n = 1 << log2n
    let setup = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)!
    func flux(_ a: [Float], _ b: [Float]) -> Float {
        let sa = spectrum(a, setup: setup, log2n: log2n).map { log10($0 + 1e-6) }
        let sb = spectrum(b, setup: setup, log2n: log2n).map { log10($0 + 1e-6) }
        return vDSP.distanceSquared(sa, sb).squareRoot()
    }
    let across = flux(Array(signal.suffix(n)), Array(signal.prefix(n)))
    var typical: [Float] = []
    var offset = n
    let hop = max((signal.count - 2 * n) / 300, n)
    while offset + n <= signal.count {
        typical.append(flux(Array(signal[(offset - n)..<offset]), Array(signal[offset..<(offset + n)])))
        offset += hop
    }
    typical.sort()
    let median = typical.isEmpty ? 1 : typical[typical.count / 2]
    json(["stepRatio": stepRatio, "fluxRatio": Double(across / max(median, 1e-6)), "seconds": Double(signal.count) / rate])
}

// MARK: fingerprint

/// 32-bit sub-fingerprints: signs of band-energy differences across bands
/// and time (33 log bands 300–2000 Hz on 11.025 kHz audio, 2048-sample
/// frames, hop 128). Robust to codecs, gain and resampling.
func fingerprint(_ path: String, _ output: String) throws {
    let (channels, rate) = try readAll(URL(fileURLWithPath: path))
    let source = mono(channels)
    // Resample to 11,025 Hz by linear interpolation after a crude low pass
    // (box filter); adequate for fingerprints, not for listening.
    let factor = rate / 11_025
    let width = max(Int(factor.rounded()), 1)
    var smoothed = source
    if width > 1 {
        let kernel = [Float](repeating: 1 / Float(width), count: width)
        smoothed = vDSP.convolve(source + [Float](repeating: 0, count: width - 1), withKernel: kernel)
    }
    let count = Int(Double(smoothed.count) / factor)
    var signal = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let position = Double(i) * factor
        let j = Int(position)
        let fraction = Float(position - Double(j))
        signal[i] = j + 1 < smoothed.count ? smoothed[j] * (1 - fraction) + smoothed[j + 1] * fraction : smoothed[min(j, smoothed.count - 1)]
    }
    let log2n = 11
    let n = 1 << log2n
    let hop = 128
    let setup = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)!
    let edges = (0...33).map { 300 * pow(2000.0 / 300.0, Double($0) / 33) }
    let bins = edges.map { Int($0 / 11_025 * Double(n)) }
    var previous: [Float]?
    var codes: [UInt32] = []
    var offset = 0
    while offset + n <= signal.count {
        let magnitudes = spectrum(Array(signal[offset..<(offset + n)]), setup: setup, log2n: log2n)
        var energy = [Float](repeating: 0, count: 33)
        for band in 0..<33 {
            let low = bins[band], high = max(bins[band + 1], low + 1)
            energy[band] = magnitudes[low..<high].reduce(0) { $0 + $1 * $1 }
        }
        if let previous {
            var code: UInt32 = 0
            for m in 0..<32 {
                let d = (energy[m] - energy[m + 1]) - (previous[m] - previous[m + 1])
                if d > 0 { code |= 1 << UInt32(m) }
            }
            codes.append(code)
        }
        previous = energy
        offset += hop
    }
    let data = try JSONSerialization.data(withJSONObject: ["frames": codes.count, "codes": codes.map { Int($0) }])
    try data.write(to: URL(fileURLWithPath: output))
    json(["frames": codes.count])
}

func compare(_ a: String, _ b: String) throws {
    func load(_ path: String) throws -> [UInt32] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        return (object["codes"] as! [Int]).map { UInt32(truncatingIfNeeded: $0) }
    }
    let x = try load(a), y = try load(b)
    let (short, long) = x.count <= y.count ? (x, y) : (y, x)
    // Compare a 10 s excerpt (≈ 860 codes) from the middle of the shorter
    // one against every offset of the longer one.
    let window = min(860, short.count)
    guard window > 0 else { json(["ber": 1.0]); return }
    let start = (short.count - window) / 2
    let probe = Array(short[start..<(start + window)])
    var best = 1.0
    var offset = 0
    while offset + window <= long.count {
        var bits = 0
        for k in 0..<window { bits += (probe[k] ^ long[offset + k]).nonzeroBitCount }
        best = min(best, Double(bits) / Double(window * 32))
        offset += 1
    }
    json(["ber": best, "sameAudio": best < 0.35])
}

let arguments = CommandLine.arguments
do {
    switch arguments.count > 1 ? arguments[1] : "" {
    case "analyze": try analyze(arguments[2])
    case "frames": print(try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2])).length)
    case "loop": try loop(arguments[2], arguments[3], start: Double(arguments[4])!, length: Double(arguments[5])!,
                          seam: Double(arguments[6])!)
    case "seam": try seam(arguments[2])
    case "fingerprint": try fingerprint(arguments[2], arguments[3])
    case "compare": try compare(arguments[2], arguments[3])
    default:
        FileHandle.standardError.write("usage: audiotool analyze|frames|loop|seam|fingerprint|compare …\n".data(using: .utf8)!)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("audiotool: \(error)\n".data(using: .utf8)!)
    exit(1)
}
