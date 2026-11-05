import Foundation

extension QwenRender {
    /// Postprocessing must never turn a generation limit into a successful completion.
    /// Session retries and context carry both depend on the original limit remaining visible.
    mutating func trimSilence(capPauses: Bool) {
        let cut = trailingSilenceCut(samples, frames: frames)
        if cut < frames {
            frames = cut
            samples = Array(samples.prefix(cut * samplesPerFrame))
            codes = Array(codes.prefix(cut * 16))
            if stopReason == .eos { stopReason = .trailingSilence }
        }
        silenceBefore = QwenSilence.analyze(samples: samples, sampleRate: sampleRate)
        silence = silenceBefore
        if capPauses {
            let capped = QwenSilence.cap(samples: samples, sampleRate: sampleRate)
            if capped.samples.count != samples.count {
                samples = capped.samples
                pausesCapped = capped.pausesCapped
                silence = QwenSilence.analyze(samples: samples, sampleRate: sampleRate)
            }
        }
    }
}
