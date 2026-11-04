import Foundation

/// Perceived-loudness measurement and the limiter that makes a loudness target
/// reachable (#voice-loudness, 2026-08-29).
///
/// WHY THIS EXISTS, given `AudioAssembler.loudnessGain` already did a version of
/// this. Measuring the library after the first pass showed the standard was only
/// being applied to about half of it, for two distinct reasons:
///
/// 1. **The peak ceiling blocked the boost.** Every under-target voice had a peak
///    already pegged near full scale (-0.2 to -1.0 dBFS) from a handful of
///    transients, so `min(wanted, ceiling)` refused to raise it at all: `joe`
///    sat at -25.8 dBFS RMS, 7.8 dB under a -18.0 target, and the normaliser
///    left it there. Refusing to boost is the safe answer only if clipping is
///    the only alternative — it isn't. Limiting the transients instead lets the
///    body of the clip come up while the peak still honours the ceiling.
///
/// 2. **RMS is not loudness.** `maceo-sad` and `david` measured an identical
///    -18.0 dBFS RMS and differ by 2.0 LU — audibly, and in the direction the
///    ear reports. Equalising RMS therefore cannot deliver "gain 1 means the
///    same thing for every voice", which is the entire contract. ITU-R BS.1770
///    K-weighting costs two biquads and removes most of that residual.
public enum Loudness {
    /// Never let normalisation push a peak above this.
    ///
    /// This bounds the LIMITER, not the gain. The first version of this standard
    /// used the ceiling to cap the gain instead, and that silently disabled the
    /// whole feature for about half the library: any clip with a couple of
    /// transients near full scale could not be boosted at all, so `joe` stayed
    /// 7.8 dB under target and `morgan-freeman` 4.3 dB under. Bending those
    /// transients is a far smaller edit to a reference than leaving the voice
    /// permanently quiet on every device.
    ///
    /// Lives here rather than on AudioAssembler because it is part of the
    /// reference-audio standard a `.gvoice` pack is normalised to, and both
    /// apps have to agree on it.
    public static let referencePeakCeilingDbFS: Float = -1.0

    /// The reference-audio loudness standard, in LUFS (ITU-R BS.1770 K-weighted).
    ///
    /// A clone sounds as loud as the reference it was built from, and nothing
    /// downstream re-levels it: on iOS the voice path is a straight gain
    /// multiply (VoiceMixer.setGain) with no compressor at all. So a quietly
    /// recorded voice is quiet on every device, at every gain setting, forever —
    /// an imported voice came in ~2.3 dB under the shipped hosts and was
    /// audibly quieter on an iPhone at the same setting (David, 2026-08-29).
    ///
    /// The anchor is not a preference: it is measured from `billie-frost`, the
    /// bundled host whose level is known-good, which sits at **-18.2 LUFS**.
    /// Matching it is what makes "gain 1" mean the same thing for every voice —
    /// the contract the UI already implies.
    ///
    /// The target is that anchor raised **1.2 dB** (≈15% in linear amplitude).
    /// Levelling the set to billie-frost made every voice CONSISTENT but left the
    /// whole set quiet against the music bed (David, 2026-08-29). Consistency was
    /// the bug; absolute level is a separate, deliberate choice on top of it.
    ///
    /// LUFS rather than RMS, and RMS rather than peak, for the same reason twice
    /// over — each is a closer model of what an ear reports than the last.
    /// `normalizePeak` equalises the loudest SAMPLE, which one transient
    /// dominates. Plain RMS equalises energy, but weights 60 Hz the same as
    /// 3 kHz: measured over the real library, `maceo-sad` and `david` sit at an
    /// identical -18.0 dBFS RMS and still differ by 2.0 LU, in the direction the
    /// ear reports. K-weighting costs two biquads and removes most of that gap.
    ///
    /// Lives here with the ceiling: together they ARE the reference standard a
    /// `.gvoice` is normalised to, and both apps have to agree on both numbers.
    public static let referenceLoudnessLUFS: Float = -17.0



    // MARK: - Measurement

    /// Integrated K-weighted loudness in LUFS (ITU-R BS.1770-4), without gating.
    ///
    /// Ungated on purpose: gating exists to stop silence between dialogue from
    /// dragging a broadcast programme's measurement down, but a voice reference
    /// is a few seconds of near-continuous speech that has already been trimmed.
    /// Gating it would mostly add a threshold to tune for no gain in accuracy.
    ///
    /// Returns `-.infinity` for silence — there is no loudness to report, and
    /// callers must treat it as "leave alone" rather than "boost enormously".
    public static func lufs(_ samples: [Float], sampleRate: Int) -> Float {
        guard !samples.isEmpty, sampleRate > 0 else { return -.infinity }
        let weighted = kWeighted(samples, sampleRate: sampleRate)
        var sum = 0.0
        for s in weighted { sum += Double(s) * Double(s) }
        let meanSquare = sum / Double(weighted.count)
        guard meanSquare > 1e-14 else { return -.infinity }
        // -0.691 is the BS.1770 calibration offset for a single (mono) channel
        // at unity weight.
        return Float(-0.691 + 10 * log10(meanSquare))
    }

    /// The BS.1770 two-stage pre-filter: a high-shelf approximating the acoustic
    /// effect of a head in a diffuse field, then an RLB high-pass that discounts
    /// the low end the ear is insensitive to. Coefficients are derived for the
    /// actual sample rate rather than the 48 kHz constants usually quoted, because
    /// references here are commonly 22.05/24/44.1 kHz and reusing 48 kHz
    /// coefficients would detune both filters.
    static func kWeighted(_ samples: [Float], sampleRate: Int) -> [Float] {
        let rate = Double(sampleRate)

        // Stage 1 — high-shelf, +3.999 dB above ~1.68 kHz.
        let f0 = 1681.974450955533
        let gain = 3.999843853973347
        let q0 = 0.7071752369554196
        let k0 = tan(Double.pi * f0 / rate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k0 / q0 + k0 * k0
        let shelfB = [(vh + vb * k0 / q0 + k0 * k0) / a0,
                      2 * (k0 * k0 - vh) / a0,
                      (vh - vb * k0 / q0 + k0 * k0) / a0]
        let shelfA = [2 * (k0 * k0 - 1) / a0, (1 - k0 / q0 + k0 * k0) / a0]

        // Stage 2 — RLB high-pass at ~38 Hz.
        let f1 = 38.13547087602444
        let q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / rate)
        let a1 = 1 + k1 / q1 + k1 * k1
        let hpB = [1.0, -2.0, 1.0]
        let hpA = [2 * (k1 * k1 - 1) / a1, (1 - k1 / q1 + k1 * k1) / a1]

        return biquad(biquad(samples, b: shelfB, a: shelfA), b: hpB, a: hpA)
    }

    /// Direct-form-I biquad in Double. Double rather than Float because the RLB
    /// high-pass has poles very close to the unit circle at these sample rates,
    /// where single precision accumulates audible DC drift over a long clip.
    private static func biquad(_ x: [Float], b: [Double], a: [Double]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0 ..< x.count {
            let xn = Double(x[i])
            let yn = b[0] * xn + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            out[i] = Float(yn)
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
        }
        return out
    }

    // MARK: - Limiting

    /// Soft-knee limiter. Samples below `ceilingDbFS - kneeDb` pass through bit-
    /// identical; above it, amplitude is mapped smoothly onto the remaining
    /// headroom so the output asymptotically approaches — and never exceeds —
    /// the ceiling.
    ///
    /// `tanh` rather than a hard clip because this audio is training material for
    /// a cloning backend: a hard clip introduces a discontinuity and wideband
    /// harmonics exactly where the waveform is loudest, which is the part of the
    /// signal a backend keys on. The soft curve is continuous in value and slope
    /// at the knee, so below-knee speech — which is nearly all of it — is
    /// untouched and the transients bend rather than break.
    ///
    /// This is not a lookahead limiter: it is memoryless, so it does not
    /// anticipate a transient and duck ahead of it. That is deliberate. A
    /// lookahead limiter's gain envelope moves the whole clip around a peak,
    /// which is a much larger edit to a reference than bending the peak itself.
    public static func softLimit(_ samples: [Float],
                                 ceilingDbFS: Float = Loudness.referencePeakCeilingDbFS,
                                 kneeDb: Float = 6) -> [Float] {
        let ceiling = pow(10, ceilingDbFS / 20)
        let threshold = ceiling * pow(10, -kneeDb / 20)
        let range = ceiling - threshold
        guard range > 0 else { return samples.map { max(-ceiling, min(ceiling, $0)) } }
        return samples.map { s in
            let magnitude = abs(s)
            guard magnitude > threshold else { return s }
            let bent = threshold + range * tanh((magnitude - threshold) / range)
            return s < 0 ? -bent : bent
        }
    }

    // MARK: - The standard

    /// Bring `samples` to `targetLUFS`, limiting transients rather than refusing
    /// to boost when the peak ceiling would otherwise bind.
    ///
    /// Solved iteratively because limiting itself removes loudness: the gain that
    /// would hit the target before limiting undershoots after it. Each pass
    /// re-limits **the original samples** at an accumulated gain rather than
    /// re-limiting the previous output, so however many passes it takes, the
    /// result has been through the soft curve exactly once.
    ///
    /// `maxBoostDb` is a backstop against driving a pathological signal until the
    /// limiter is doing all the work — a clip that is one bang and otherwise
    /// near-silence. It is deliberately generous, because a merely QUIET recording
    /// is not pathological and must still reach the standard: `sam-elliott` came
    /// off a phone at -36.0 LUFS with an ordinary 18.7 dB crest factor, needing
    /// +19 dB that the limiter barely touches. A tighter bound (15 dB was the
    /// first try) left it 4 dB short and made it the single worst voice in the
    /// library — the bound firing on exactly the recording the standard was
    /// supposed to rescue. The real protection against crushing is the "never
    /// quieter" guard below, which is signal-dependent; this is only a stop.
    ///
    /// `measuring` is the signal loudness is READ from, when that differs from
    /// the signal gain is WRITTEN to — a mono downmix standing in for interleaved
    /// multi-channel audio. Defaults to `samples` itself.
    /// Share of `samples` sitting below `thresholdDBFS`, measured in 20 ms
    /// windows. A rendered pass that is mostly silence did not speak its
    /// lines — the words were consumed while no audio came out — so this is
    /// the cheap check that catches a dead pass before anyone plays it.
    public static func silentFraction(_ samples: [Float], sampleRate: Int,
                                      thresholdDBFS: Double = -50) -> Double {
        let hop = max(1, sampleRate / 50)
        guard samples.count >= hop else { return 0 }
        let threshold = Float(pow(10.0, thresholdDBFS / 20.0))
        var quiet = 0, total = 0, index = 0
        while index + hop <= samples.count {
            var sum: Float = 0
            for value in samples[index ..< index + hop] { sum += value * value }
            if (sum / Float(hop)).squareRoot() < threshold { quiet += 1 }
            total += 1
            index += hop
        }
        return total > 0 ? Double(quiet) / Double(total) : 0
    }

    public static func leveled(_ samples: [Float],
                               sampleRate: Int,
                               targetLUFS: Float = Loudness.referenceLoudnessLUFS,
                               ceilingDbFS: Float = Loudness.referencePeakCeilingDbFS,
                               maxBoostDb: Float = 24,
                               measuring: [Float]? = nil) -> [Float] {
        let probe = measuring ?? samples
        let measured = lufs(probe, sampleRate: sampleRate)
        guard measured.isFinite else { return samples }

        var gainDb = targetLUFS - measured
        var best = samples
        var bestLoudness = measured
        for _ in 0 ..< 6 {
            gainDb = min(gainDb, maxBoostDb)
            let gain = pow(10, gainDb / 20)
            let candidate = softLimit(samples.map { $0 * gain },
                                      ceilingDbFS: ceilingDbFS)
            // Measure what the limiter actually produced, not what the gain
            // intended — limiting removes loudness, which is precisely why this
            // has to iterate. The probe is limited the same way so the reading
            // matches the written signal; the limiter is memoryless and per
            // sample, so that correspondence is exact rather than approximate.
            let heard = lufs(softLimit(probe.map { $0 * gain }, ceilingDbFS: ceilingDbFS),
                             sampleRate: sampleRate)
            best = candidate
            bestLoudness = heard
            let error = targetLUFS - heard
            if abs(error) < 0.1 { break }
            // Already at the boost bound and still short: no further gain is
            // available, so stop rather than spin.
            if gainDb >= maxBoostDb, error > 0 { break }
            gainDb += error
        }

        // A clip we set out to make LOUDER must never come back quieter.
        // Boost-then-limit can LOSE net loudness when the signal essentially IS
        // its transients: nothing sits under the knee for the gain to lift, so the
        // limiter takes back more than the gain added. Real speech never looks
        // like that, but the invariant is absolute and was learned the hard way —
        // an earlier version of this standard made `joe` quieter, which is the
        // exact failure the standard exists to prevent. Under-target beats the
        // wrong direction.
        //
        // Conditioned on having wanted a boost, because an over-level reference
        // is SUPPOSED to end up quieter — that is the standard working, not the
        // failure. (An unconditional version of this guard passed the boost tests
        // and silently disabled attenuation entirely.)
        if targetLUFS > measured, bestLoudness < measured { return samples }
        return best
    }
}
