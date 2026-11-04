import Accelerate
import Foundation

/// The mel the Qwen3-TTS speaker encoder was trained on (upstream `mel_spectrogram`; mlx_audio's
/// qwen3_tts.mel_spectrogram), on Accelerate: 24 kHz, n_fft 1024, hop 256, 128 mels, 0..12 kHz,
/// reflect pad 384 each side (no centring), symmetric Hann, MAGNITUDE `sqrt(re^2 + im^2 + 1e-9)`,
/// Slaney mel scale and area normalisation, `ln(max(., 1e-5))`.
///
/// NOT the mlx-audio-swift fork's `computeMelSpectrogram` (power spectrum, HTK, Whisper-style
/// scaling): the speaker encoder was not trained on that and its embedding is a different vector
/// (cosine ~0.6). Spec: qwen-onnx-cpu/docs/voice-prep-coreml.md.
enum QwenMel {
    static let sampleRate = 24000
    static let nFFT = 1024
    static let hop = 256
    static let nMels = 128
    static let fMax = 12000.0
    private static let nBins = nFFT / 2 + 1

    /// Number of mel frames for `n` samples: `1 + (n + 768 - 1024) / 256`.
    static func frameCount(samples n: Int) -> Int { 1 + (n + (nFFT - hop) - nFFT) / hop }

    /// librosa.filters.mel(sr, n_fft, n_mels, fmin 0, fmax 12000, htk=False, norm="slaney"), (nMels x nBins).
    static let filterbank: [Float] = {
        func hz2mel(_ f: Double) -> Double {
            f >= 1000 ? 15 + log(f / 1000) / (log(6.4) / 27) : f / (200.0 / 3)
        }
        func mel2hz(_ m: Double) -> Double {
            m >= 15 ? 1000 * exp(log(6.4) / 27 * (m - 15)) : m * (200.0 / 3)
        }
        let lo = hz2mel(0), hi = hz2mel(fMax)
        let melF = (0..<(nMels + 2)).map { mel2hz(lo + (hi - lo) * Double($0) / Double(nMels + 1)) }
        let fftF = (0..<nBins).map { Double(sampleRate) / 2 * Double($0) / Double(nBins - 1) }
        var fb = [Float](repeating: 0, count: nMels * nBins)
        for m in 0..<nMels {
            let fdiff0 = melF[m + 1] - melF[m], fdiff1 = melF[m + 2] - melF[m + 1]
            let norm = 2 / (melF[m + 2] - melF[m])
            for k in 0..<nBins {
                let lower = -(melF[m] - fftF[k]) / fdiff0
                let upper = (melF[m + 2] - fftF[k]) / fdiff1
                fb[m * nBins + k] = Float(max(0, min(lower, upper)) * norm)
            }
        }
        return fb
    }()

    /// Symmetric Hann, `0.5 - 0.5 cos(2 pi k / (n - 1))`.
    private static let window: [Float] = (0..<nFFT).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT - 1)))
    }

    /// Log-mel of mono 24 kHz `x`, frames x 128, row-major. Needs more than 384 samples (reflect pad).
    static func logMel(_ x: [Float]) -> (mel: [Float], frames: Int) {
        let pad = (nFFT - hop) / 2
        precondition(x.count > pad, "reference too short for the reflect pad")
        var xp = [Float](); xp.reserveCapacity(x.count + 2 * pad)
        xp.append(contentsOf: x[1...pad].reversed())
        xp.append(contentsOf: x)
        xp.append(contentsOf: x[(x.count - pad - 1)..<(x.count - 1)].reversed())
        let frames = 1 + (xp.count - nFFT) / hop

        let log2n = vDSP_Length(10)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }

        var mag = [Float](repeating: 0, count: frames * nBins)
        var frame = [Float](repeating: 0, count: nFFT)
        var re = [Float](repeating: 0, count: nFFT / 2)
        var im = [Float](repeating: 0, count: nFFT / 2)
        for f in 0..<frames {
            xp.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { w in
                    vDSP_vmul(src.baseAddress! + f * hop, 1, w.baseAddress!, 1, &frame, 1, vDSP_Length(nFFT))
                }
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(nFFT / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            // zrip packs DC in re[0] and Nyquist in im[0]; its output is 2x the true DFT.
            let base = f * nBins
            for k in 0..<nBins {
                let r: Float, i: Float
                if k == 0 { r = re[0] * 0.5; i = 0 }
                else if k == nBins - 1 { r = im[0] * 0.5; i = 0 }
                else { r = re[k] * 0.5; i = im[k] * 0.5 }
                mag[base + k] = (r * r + i * i + 1e-9).squareRoot()
            }
        }

        // mel = mag (frames x bins) . fb^T (bins x mels)
        var mel = [Float](repeating: 0, count: frames * nMels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(nMels), Int32(nBins),
                    1, mag, Int32(nBins), filterbank, Int32(nBins), 0, &mel, Int32(nMels))
        var floor: Float = 1e-5
        vDSP_vthr(mel, 1, &floor, &mel, 1, vDSP_Length(mel.count))
        var n = Int32(mel.count)
        vvlogf(&mel, mel, &n)
        return (mel, frames)
    }
}
