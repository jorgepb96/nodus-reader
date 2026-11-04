import Foundation

let sampleRate = 24000
let samplesPerFrame = 1920

/// Frames to keep: cuts only TRUE trailing silence -- the run after the last audible chunk, when it
/// is at least `stopS` long (keeping `stopS` of it, as the streaming tracker would have). A long
/// pause with speech after it is never a cut point: that used to drop whole sentences mid-part
/// (Spanish takes pause >1.5 s mid-line); mid-line pauses are shortened by `QwenSilence.cap`.
func trailingSilenceCut(_ wav: [Float], frames total: Int, chunk: Int = 12, floorDb: Float = -35, stopS: Float = 1.5) -> Int {
    let win = sampleRate / 50
    var lastLoudSample = -1
    var done = 0
    while done + chunk <= total {
        let a = done * samplesPerFrame, b = (done + chunk) * samplesPerFrame
        for w in 0..<((b - a) / win) {
            var ss: Float = 0
            for i in 0..<win { let v = wav[a + w * win + i]; ss += v * v }
            if 20 * log10f(sqrtf(ss / Float(win)) + 1e-9) > floorDb { lastLoudSample = a + (w + 1) * win }
        }
        done += chunk
    }
    guard lastLoudSample >= 0 else { return total }
    let trailing = Float(total * samplesPerFrame - lastLoudSample) / Float(sampleRate)
    guard trailing >= stopS else { return total }
    let keep = lastLoudSample + Int(stopS * Float(sampleRate))
    return min(total, (keep + samplesPerFrame - 1) / samplesPerFrame)
}
