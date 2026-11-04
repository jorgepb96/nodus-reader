import Foundation

/// Trims dead air off a line that is being STREAMED, one vocoder chunk at a time.
///
/// The finished-line cap (`QwenSilence.cap`) needs the whole clip: its silence threshold is derived from the
/// clip's own speech level and its pause rule rewrites the middle of a pause. A stream cannot do that, so this
/// does the two parts that are safe without the future:
///
/// - Leading silence: nothing is emitted until a window above the speech threshold shows up; the audio then
///   starts at most `maxLeading` (0.05 s, like `QwenSilence.cap`) before it.
/// - Trailing silence: a silent run at the end of a chunk is HELD BACK. If speech follows, the run was an
///   internal pause and is emitted in full (streaming does NOT shorten internal pauses; only the finished,
///   non-streamed result does). If the line ends, at most `maxTrailing` (0.1 s) of it is emitted by `finish()`.
///
/// Every emitted sample is an untouched sample of the vocoder output, so the concatenation of what `push` and
/// `finish` return is a contiguous slice of the un-capped line. The threshold is relative to the loudest 20 ms
/// window seen so far (40 dB under it, floored at -60 dBFS), and a chunk whose loudest window is under
/// -45 dBFS counts as silence before the line has started.
public final class QwenStreamTrimmer {
    public static let speechFloorDB = -45.0
    public static let belowPeakDB = 40.0
    private let sampleRate: Int
    private let window: Int
    private let maxLeading: Int
    private let maxTrailing: Int
    private var started = false
    private var peakDB = -120.0
    private var held: [Float] = []

    public init(sampleRate: Int, maxLeading: Double = 0.05, maxTrailing: Double = 0.1) {
        self.sampleRate = sampleRate
        window = max(1, Int(Double(sampleRate) * QwenSilence.windowSeconds))
        self.maxLeading = Int(maxLeading * Double(sampleRate))
        self.maxTrailing = Int(maxTrailing * Double(sampleRate))
    }

    private func windowDB(_ x: ArraySlice<Float>) -> [Double] {
        var out: [Double] = []
        var a = x.startIndex
        while a < x.endIndex {
            let b = min(x.endIndex, a + window)
            var s = 0.0
            for j in a..<b { let v = Double(x[j]); s += v * v }
            out.append(10 * log10(s / Double(b - a) + 1e-12))
            a = b
        }
        return out
    }

    /// Feeds the next chunk; returns the samples that are now safe to play (possibly none).
    public func push(_ chunk: [Float]) -> [Float] {
        guard !chunk.isEmpty else { return [] }
        let db = windowDB(chunk[...])
        peakDB = max(peakDB, db.max() ?? -120)
        let thr = max(peakDB - Self.belowPeakDB, QwenSilence.floorDB)
        var body = chunk[...]
        if !started {
            guard peakDB >= Self.speechFloorDB, let first = db.firstIndex(where: { $0 >= thr }) else { return [] }
            started = true
            body = chunk[max(0, first * window - maxLeading)...]
        }
        // Trailing silent windows of `body`, aligned to its own start.
        let bdb = windowDB(body)
        var keepWindows = bdb.count
        while keepWindows > 0, bdb[keepWindows - 1] < thr { keepWindows -= 1 }
        let keep = min(body.count, keepWindows * window)
        if keepWindows == 0 {
            held.append(contentsOf: body)
            return []
        }
        var out = held
        held = []
        out.append(contentsOf: body.prefix(keep))
        held.append(contentsOf: body.dropFirst(keep))
        return out
    }

    /// The line is over: returns the allowed tail of the held silence (at most `maxTrailing`), if the line started.
    public func finish() -> [Float] {
        defer { held = [] }
        guard started else { return [] }
        return Array(held.prefix(maxTrailing))
    }
}
