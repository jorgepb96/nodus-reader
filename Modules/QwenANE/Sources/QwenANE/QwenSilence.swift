import Foundation

/// What the silence in a clip looks like. All times are seconds.
public struct SilenceReport: Sendable, Equatable {
    /// Silence before the first speech window.
    public var leading: Double
    /// Silence after the last speech window.
    public var trailing: Double
    /// The longest silent run between two speech windows (0 when there is none).
    public var longestPause: Double
    /// Where that run starts, in seconds from the clip start.
    public var longestPauseAt: Double
    /// Internal silent runs longer than `QwenSilence.reportPause` (0.7 s).
    public var pausesOverThreshold: Int
    /// The speech level the thresholds were derived from (95th-percentile 20 ms window RMS, dBFS).
    public var speechLevelDB: Double

    public static let empty = SilenceReport(leading: 0, trailing: 0, longestPause: 0, longestPauseAt: 0,
                                            pausesOverThreshold: 0, speechLevelDB: -120)
}

/// Finds and removes dead air in a rendered line. Pure and model-free.
///
/// Classification: the clip is cut into 20 ms windows and each gets an RMS in dBFS. The speech level
/// is the 95th percentile of those. A window is silent when it is more than `belowSpeechDB` (35 dB)
/// under the speech level, with the threshold floored at -60 dBFS so a quiet voice still works and
/// digital noise floors do not count as speech. 35 dB is deliberately conservative: breaths and soft
/// consonant tails sit roughly 15 to 30 dB under speech, so they count as non-silent and are never cut.
/// Only runs of silent windows are ever shortened, and they are shortened from the middle.
public enum QwenSilence {
    public static let windowSeconds = 0.02
    public static let belowSpeechDB = 35.0
    public static let floorDB = -60.0
    /// `SilenceReport.pausesOverThreshold` counts internal pauses longer than this.
    public static let reportPause = 0.7

    struct Run { var start: Int; var end: Int }   // sample range [start, end)

    /// Silent runs (in samples) plus the thresholds; nil when the clip has no speech window.
    static func silentRuns(_ x: [Float], sampleRate: Int) -> (runs: [Run], levelDB: Double)? {
        let w = max(1, Int(Double(sampleRate) * windowSeconds))
        guard x.count >= w else { return nil }
        let nWin = (x.count + w - 1) / w
        var db = [Double](repeating: -120, count: nWin)
        for i in 0..<nWin {
            let a = i * w, b = min(x.count, a + w)
            var s = 0.0
            for j in a..<b { let v = Double(x[j]); s += v * v }
            db[i] = 10 * log10(s / Double(b - a) + 1e-12)
        }
        let sorted = db.sorted()
        let level = sorted[min(nWin - 1, Int(Double(nWin) * 0.95))]
        let thr = max(level - belowSpeechDB, floorDB)
        guard level > floorDB else { return nil }          // nothing above the floor: no speech to anchor on
        var runs: [Run] = []
        var i = 0
        while i < nWin {
            if db[i] < thr {
                var j = i
                while j < nWin, db[j] < thr { j += 1 }
                runs.append(Run(start: i * w, end: min(x.count, j * w)))
                i = j
            } else { i += 1 }
        }
        return (runs, level)
    }

    public static func analyze(samples x: [Float], sampleRate: Int) -> SilenceReport {
        guard let (runs, level) = silentRuns(x, sampleRate: sampleRate) else { return .empty }
        let sr = Double(sampleRate)
        var r = SilenceReport.empty
        r.speechLevelDB = level
        for run in runs {
            let len = Double(run.end - run.start) / sr
            if run.start == 0 { r.leading = len }
            else if run.end == x.count { r.trailing = len }
            else {
                if len > r.longestPause { r.longestPause = len; r.longestPauseAt = Double(run.start) / sr }
                if len > reportPause { r.pausesOverThreshold += 1 }
            }
        }
        return r
    }

    public struct CapResult: Sendable {
        public var samples: [Float]
        /// Internal pauses shortened.
        public var pausesCapped: Int
    }

    /// Shortens internal pauses longer than `maxPause` to `keep` seconds (the middle of the pause is
    /// removed, the join is a `fade`-second crossfade inside the silence), trims leading silence to at
    /// most `maxLeading` and trailing to at most `maxTrailing`. A clip with nothing to cut comes back
    /// bit-identical. Samples classified as non-silent are never touched.
    public static func cap(samples x: [Float], sampleRate: Int, maxPause: Double = 0.7, keep: Double = 0.45,
                           fade: Double = 0.01, maxLeading: Double = 0.05, maxTrailing: Double = 0.1) -> CapResult {
        guard let (runs, _) = silentRuns(x, sampleRate: sampleRate) else { return CapResult(samples: x, pausesCapped: 0) }
        let sr = Double(sampleRate)
        let keepN = Int(keep * sr), maxN = Int(maxPause * sr), f = max(1, Int(fade * sr))
        // Ranges [a, b) of x to delete, ascending.
        var cuts: [(Int, Int, Bool)] = []   // (from, to, crossfade)
        var capped = 0
        for run in runs {
            let len = run.end - run.start
            if run.start == 0 {
                let lim = Int(maxLeading * sr)
                if len > lim { cuts.append((0, len - lim, false)) }
            } else if run.end == x.count {
                let lim = Int(maxTrailing * sr)
                if len > lim { cuts.append((run.start + lim, x.count, false)) }
            } else if len > maxN {
                let head = keepN / 2, tail = keepN - head
                let a = run.start + head, b = run.end - tail
                if b - a > 2 * f { cuts.append((a, b, true)); capped += 1 }
            }
        }
        guard !cuts.isEmpty else { return CapResult(samples: x, pausesCapped: 0) }
        var out = [Float](); out.reserveCapacity(x.count)
        var pos = 0
        for (a, b, xfade) in cuts {
            if xfade {
                // keep x[pos..<a-f], then blend x[a-f..<a] (fading out) with x[b-f..<b] (fading in)
                out.append(contentsOf: x[pos..<(a - f)])
                for k in 0..<f {
                    let t = Float(k + 1) / Float(f + 1)
                    out.append(x[a - f + k] * (1 - t) + x[b - f + k] * t)
                }
            } else {
                out.append(contentsOf: x[pos..<a])
            }
            pos = b
        }
        out.append(contentsOf: x[pos...])
        return CapResult(samples: out, pausesCapped: capped)
    }

    public static func capPauses(samples: [Float], sampleRate: Int, maxPause: Double = 0.7, keep: Double = 0.45,
                                 fade: Double = 0.01) -> [Float] {
        cap(samples: samples, sampleRate: sampleRate, maxPause: maxPause, keep: keep, fade: fade).samples
    }
}
