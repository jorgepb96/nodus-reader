// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Gain curves for music transitions. All pure functions of time, so the
/// automation can be evaluated at any clock (the audio timer, or the sample
/// time of an offline render in tests).
enum GainCurve {
    /// Equal-power fade-in: with `fadeOut` at the same point, the summed
    /// power of two uncorrelated pieces stays constant through a crossfade.
    static func fadeIn(_ x: Double) -> Double { sin(clamp(x) * .pi / 2) }
    static func fadeOut(_ x: Double) -> Double { cos(clamp(x) * .pi / 2) }
    /// Smooth start and end (no slope discontinuity, so no click).
    static func raisedCosine(_ x: Double) -> Double { 0.5 - 0.5 * cos(clamp(x) * .pi) }

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    static func linear(fromDecibels db: Double) -> Double { pow(10, db / 20) }
    static func decibels(fromLinear gain: Double) -> Double { 20 * log10(max(gain, 1e-6)) }
}

/// One gain movement over time.
struct GainRamp: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        /// Equal-power fade, for crossfades between pieces.
        case equalPower
        /// Raised-cosine interpolation in decibels, for ducking and level changes.
        case decibels
    }

    var from: Double
    var to: Double
    var start: TimeInterval
    var duration: TimeInterval
    var shape: Shape

    static func hold(_ gain: Double) -> GainRamp {
        GainRamp(from: gain, to: gain, start: 0, duration: 0, shape: .decibels)
    }

    func isFinished(at time: TimeInterval) -> Bool { time >= start + duration }

    func value(at time: TimeInterval) -> Double {
        guard duration > 0 else { return time >= start ? to : from }
        let x = GainCurve.clamp((time - start) / duration)
        switch shape {
        case .equalPower:
            // Fades between any two levels on equal-power curves: a fade-in
            // follows sin, a fade-out cos, scaled to the endpoints.
            if to >= from {
                return from + (to - from) * GainCurve.fadeIn(x)
            }
            return to + (from - to) * GainCurve.fadeOut(x)
        case .decibels:
            let floor = 1e-4
            if from < floor || to < floor {
                // dB is undefined at silence: blend linearly on a smooth curve.
                return from + (to - from) * GainCurve.raisedCosine(x)
            }
            let a = GainCurve.decibels(fromLinear: from)
            let b = GainCurve.decibels(fromLinear: to)
            return GainCurve.linear(fromDecibels: a + (b - a) * GainCurve.raisedCosine(x))
        }
    }
}

/// Lowers music under narration: down quickly when speech starts, back up
/// slowly after it has been silent for `hold` seconds, so the pauses between
/// sentences do not make the music swell and dip.
struct DuckingEnvelope: Equatable, Sendable {
    var depth: Double       // decibels, negative
    var attack: TimeInterval = 0.6
    var hold: TimeInterval = 2.0
    var release: TimeInterval = 1.2

    private var ramp = GainRamp.hold(1)
    private var audible = false
    private var silentSince: TimeInterval?

    init(depth: Double) {
        self.depth = depth
    }

    var isDucked: Bool { audible }

    mutating func setAudible(_ value: Bool, at time: TimeInterval) {
        guard value != audible else { return }
        audible = value
        if value {
            silentSince = nil
            let current = gain(at: time)
            let target = GainCurve.linear(fromDecibels: depth)
            ramp = GainRamp(from: current, to: target, start: time, duration: attack * rampFraction(current, target),
                            shape: .decibels)
        } else {
            silentSince = time
        }
    }

    /// Gain to apply at `time` (1 = no ducking).
    mutating func gain(at time: TimeInterval) -> Double {
        if !audible, let since = silentSince, time >= since + hold {
            let start = since + hold
            let current = ramp.value(at: start)
            ramp = GainRamp(from: current, to: 1, start: start, duration: release * rampFraction(current, 1),
                            shape: .decibels)
            silentSince = nil
        }
        return ramp.value(at: time)
    }

    /// Whether the gain will still move after `time`.
    func isMoving(at time: TimeInterval) -> Bool {
        silentSince != nil || !ramp.isFinished(at: time)
    }

    /// A ramp that starts partway keeps the same slope: shorter duration.
    private func rampFraction(_ from: Double, _ to: Double) -> Double {
        let full = abs(depth)
        guard full > 0 else { return 1 }
        let span = abs(GainCurve.decibels(fromLinear: from) - GainCurve.decibels(fromLinear: to))
        return min(max(span / full, 0.05), 1)
    }
}

/// Slider positions (0…1) to gain: a squared taper, so half way is about
/// −12 dB and the low end of the slider is usable for quiet backgrounds.
enum VolumeTaper {
    static func gain(_ slider: Double) -> Double {
        let x = GainCurve.clamp(slider)
        return x * x
    }
}

/// Keeps narration plus Immersive Audio below full scale. Narration's level
/// is never touched; the immersive mix gets what headroom is left.
enum Headroom {
    /// Highest peak the immersive mix may reach given narration's peak.
    static func ceiling(narrationPeak: Float) -> Float {
        min(max(0.98 - 1.12 * narrationPeak, 0.1), 0.89)
    }

    /// Music bus cap before the user's volume (−6 dB), ambience (−3 dB).
    static let musicBusCap = GainCurve.linear(fromDecibels: -6)
    static let ambienceBusCap = GainCurve.linear(fromDecibels: -3)
}
