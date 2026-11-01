// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Decides when the atmosphere stays and when it changes. Nothing else.
///
/// Stability comes first: an imperfect atmosphere that holds is better than
/// one that keeps interrupting. A change needs, all at once, enough time on
/// the current atmosphere, a run of consecutive windows agreeing on the new
/// one, evidence well above the current one's (hysteresis), no close second
/// candidate (ambiguous ⇒ keep), no recent use of the candidate (no ping-pong)
/// and a natural place to change (a paragraph, scene or chapter break).
///
/// Evidence is a heuristic score accumulated from window readings with decay
/// (`AtmosphereMapper`); it is never presented as a probability.
///
/// The director is a pure value: time is the engaged playing time passed in
/// by the caller, so tests can drive hours of reading in microseconds.
struct AmbienceDirector: Sendable {
    // MARK: Configuration

    struct LayerConfig: Codable, Hashable, Sendable {
        /// Minimum engaged seconds on one value before a regular change.
        var dwell: TimeInterval
        /// Minimum seconds when the text itself marks a clear new scene at a
        /// chapter start or a scene-break line.
        var overrideFloor: TimeInterval
        /// Consecutive windows (strength ≥ 2) that must agree on a challenger.
        var streak: Int
        /// Evidence kept from one window to the next.
        var decay: Double
        /// Evidence the challenger needs.
        var enter: Double
        /// Lead the challenger needs over the current value (hysteresis).
        var margin: Double
        /// Lead over the runner-up; below it the reading is ambiguous.
        var ambiguity: Double
        /// A value abandoned this recently is not taken back.
        var cooldown: TimeInterval
        /// Safety net: never more changes than this per engaged hour.
        var hourlyCap: Int
    }

    struct Config: Codable, Hashable, Sendable {
        var music = LayerConfig(dwell: 600, overrideFloor: 360, streak: 2, decay: 0.6, enter: 3.5,
                                margin: 1.5, ambiguity: 1.0, cooldown: 1_200, hourlyCap: 4)
        var base = LayerConfig(dwell: 1_200, overrideFloor: 600, streak: 3, decay: 0.75, enter: 5.0,
                               margin: 2.5, ambiguity: 1.5, cooldown: 1_800, hourlyCap: 2)
        /// A start chosen before any analysis may be corrected once, this soon.
        var provisionalWindow: TimeInterval = 180
        /// After a jump, wait this long before reconsidering.
        var settle: TimeInterval = 20
        /// …or this long after several quick jumps (the reader is browsing).
        var rapidSettle: TimeInterval = 60
        var rapidJumpCount = 3
        var rapidJumpSpan: TimeInterval = 60
        /// Evidence needed to start on an analysed value instead of the default.
        var startMusicEvidence = 2.0
        var startBaseEvidence = 3.0
        /// A jump this far (in characters) back into heard text restores what played there.
        var restoreDistance = 2 * SceneSegmenter.target

        static let standard = Config()
    }

    // MARK: Input and output

    enum Movement: Hashable, Sendable {
        /// Reading or listening forward.
        case natural
        /// A short step back (previous sentence, page back): ignored.
        case smallBack
        case jump(chapterChanged: Bool)
    }

    enum Override: Hashable, Sendable {
        /// The reader locked what is playing now.
        case lock(Atmosphere)
        /// The reader chose this atmosphere.
        case manual(Atmosphere)

        var atmosphere: Atmosphere {
            switch self {
            case .lock(let atmosphere), .manual(let atmosphere): atmosphere
            }
        }
    }

    struct Input: Sendable {
        /// Engaged seconds: time Immersive Audio has been playing.
        var now: TimeInterval
        /// UTF-16 offset in `StoryText` coordinates.
        var position: Int
        var movement: Movement = .natural
        /// A paragraph, scene or chapter break was crossed since the last step.
        var atTransitionSite = false
        var map: SceneMap?
        var mode: ImmersiveMode = .automatic
        var intensity: MusicIntensity = .balanced
        /// What plays when analysis says nothing (and in manual and study).
        var defaults = Atmosphere(base: .none, music: .calm)
        var override: Override?
        var musicEnabled = true
        var ambienceEnabled = true
        var installedMoods: Set<MusicMood> = Set(MusicMood.allCases)
        var installedBeds: Set<BaseAmbience> = Set(BaseAmbience.allCases)
        /// Study texture blocks; nil keeps one texture for the session.
        var studyBlock: TimeInterval?
        var crossfade: TimeInterval = 12
    }

    enum KeepReason: String, Codable, Sendable {
        case unchanged, userLock, manual, study, nonFiction, layerDisabled, settling
        case dwell, streakTooShort, weakEvidence, marginTooSmall, ambiguous, cooldown
        case hourlyCap, awaitingTransition, noEvidence, noAnalysisAtJump, fallbackUnavailable
    }

    enum DecisionReason: String, Codable, Sendable {
        case start, provisionalCorrection, sceneChange, justifiedOverride
        case jumpReevaluation, restoreAfterJump, userChoice, modeChange, layerToggle, returnToAutomatic

        /// Changes decided from the text by the regular rules.
        var isAutomatic: Bool { self == .sceneChange || self == .justifiedOverride }
    }

    enum LayerDecision<Value: Hashable & Sendable>: Hashable, Sendable {
        case keep(KeepReason)
        case change(to: Value, reason: DecisionReason, crossfade: TimeInterval)

        var isChange: Bool { if case .change = self { true } else { false } }
    }

    struct Decision: Hashable, Sendable {
        var music: LayerDecision<MusicMood?>
        var base: LayerDecision<BaseAmbience>
        /// Study block ended: start another texture within the same mood.
        var rotateMusicTexture = false
    }

    /// What the rules saw when they allowed a change: the log keeps it so a
    /// session can be audited afterwards (`DirectorInvariants`).
    struct ChangeCheck: Codable, Hashable, Sendable {
        var elapsed: TimeInterval
        var requiredDwell: TimeInterval
        var streak: Int
        var requiredStreak: Int
        var challenger: Double
        var incumbent: Double
        var runnerUp: Double
        var enter: Double
        var margin: Double
        var ambiguity: Double
        var cooldownWaived: Bool
        var atSite: Bool
        var changesInLastHour: Int
        var hourlyCap: Int
    }

    struct Event: Codable, Hashable, Sendable {
        enum Layer: String, Codable, Sendable { case music, base }
        var time: TimeInterval
        var position: Int
        var layer: Layer
        var from: String?
        var to: String?
        /// A `DecisionReason` for changes, a `KeepReason` for holds.
        var reason: String
        var isChange: Bool
        var check: ChangeCheck?
    }

    // MARK: State

    private struct Track<Value: Hashable & Sendable>: Sendable {
        var current: Value?
        var since: TimeInterval = 0
        var evidence: [Value: Double] = [:]
        var streakValue: Value?
        var streak = 0
        var abandoned: [Value: TimeInterval] = [:]
        var changes: [TimeInterval] = []
        var lastKeep: KeepReason?

        mutating func accumulate(_ item: LayerEvidence<Value>?, decay: Double) {
            for key in evidence.keys { evidence[key]! *= decay }
            evidence = evidence.filter { $0.value >= 0.05 }
            guard let item else {
                streak = 0
                streakValue = nil
                return
            }
            evidence[item.value, default: 0] += item.strength
            if item.strength >= 2 {
                streak = streakValue == item.value ? streak + 1 : 1
                streakValue = item.value
            } else {
                streak = 0
                streakValue = nil
            }
        }

        mutating func set(_ value: Value?, at now: TimeInterval, counts: Bool) {
            if let old = current, old != value { abandoned[old] = now }
            current = value
            since = now
            streak = 0
            streakValue = nil
            lastKeep = nil
            if counts { changes.append(now) }
            changes = changes.filter { now - $0 < 3_600 }
        }
    }

    private struct Rules {
        var dwell: TimeInterval
        var streak: Int
        var enter: Double
        var margin: Double
        var ambiguity: Double
        var cooldownWaived: Bool
        var reason: DecisionReason
    }

    let config: Config
    private var music = Track<MusicMood>()
    private var base = Track<BaseAmbience>()
    private(set) var started = false
    private var startTime: TimeInterval = 0
    private var provisional = false
    private var lastPosition = 0
    /// Last window whose reading has been taken into the evidence.
    private var consumedThrough = -1
    private var settleUntil: TimeInterval?
    private var jumpTimes: [TimeInterval] = []
    private var jumpFrom: (position: Int, chapterChanged: Bool)?
    private var wasFixed = false
    private var blockStart: TimeInterval = 0
    /// What played where during this session, for jumps back.
    private(set) var heard: [(start: Int, end: Int, atmosphere: Atmosphere)] = []
    private(set) var log: [Event] = []

    init(config: Config = .standard) {
        self.config = config
    }

    var current: Atmosphere? {
        started ? Atmosphere(base: base.current ?? .none, music: music.current) : nil
    }

    /// Heuristic evidence per value (for the debug view; not probabilities).
    var musicEvidence: [MusicMood: Double] { music.evidence }
    var baseEvidence: [BaseAmbience: Double] { base.evidence }

    // MARK: Step

    mutating func step(_ input: Input) -> Decision {
        defer { lastPosition = input.position }
        if let fixed = fixedTarget(input) {
            return applyFixed(fixed.atmosphere, reason: fixed.reason, keep: fixed.keep, input: input)
        }
        if wasFixed {
            wasFixed = false
            return reconsider(input, reason: .returnToAutomatic, chapterChanged: true)
        }
        if !started {
            return start(input)
        }
        switch input.movement {
        case .smallBack:
            return keepBoth(.unchanged, input)
        case .jump(let chapterChanged):
            jumpTimes = jumpTimes.filter { input.now - $0 < config.rapidJumpSpan } + [input.now]
            let rapid = jumpTimes.count >= config.rapidJumpCount
            settleUntil = input.now + (rapid ? config.rapidSettle : config.settle)
            if jumpFrom == nil { jumpFrom = (lastPosition, chapterChanged) }
            else if chapterChanged { jumpFrom?.chapterChanged = true }
            return keepBoth(.settling, input)
        case .natural:
            break
        }
        if let until = settleUntil {
            if input.now < until { return keepBoth(.settling, input) }
            settleUntil = nil
            if let from = jumpFrom {
                jumpFrom = nil
                return resolveJump(input, from: from.position, chapterChanged: from.chapterChanged)
            }
        }
        recordHeard(input.position)
        let entered = consumeWindows(input)
        let site = input.atTransitionSite || entered
        if provisional, !music.evidence.isEmpty || !base.evidence.isEmpty,
           input.now - startTime <= config.provisionalWindow {
            // The start was a guess made before any analysis: the first clear
            // reading may correct it, once.
            let decision = evaluate(input, site: true, rules: { layer in
                Rules(dwell: 0, streak: 1, enter: 2, margin: 1, ambiguity: layer.ambiguity,
                      cooldownWaived: true, reason: .provisionalCorrection)
            })
            if decision.music.isChange || decision.base.isChange { provisional = false }
            return decision
        }
        if input.now - startTime > config.provisionalWindow { provisional = false }
        return evaluate(input, site: site, rules: nil)
    }

    // MARK: Fixed atmospheres (manual, lock, study, non-fiction)

    private struct Fixed {
        var atmosphere: Atmosphere
        var reason: DecisionReason
        var keep: KeepReason
    }

    private func fixedTarget(_ input: Input) -> Fixed? {
        if let override = input.override {
            if case .lock = override { return Fixed(atmosphere: override.atmosphere, reason: .userChoice, keep: .userLock) }
            return Fixed(atmosphere: override.atmosphere, reason: .userChoice, keep: .manual)
        }
        switch input.mode {
        case .off:
            return Fixed(atmosphere: .silent, reason: .modeChange, keep: .unchanged)
        case .manual:
            return Fixed(atmosphere: input.defaults, reason: .userChoice, keep: .manual)
        case .study:
            return Fixed(atmosphere: input.defaults, reason: .modeChange, keep: .study)
        case .automatic:
            if let kind = input.map?.profile?.kind, !kind.hasScenes {
                // Essays, academic texts, manuals: a steady, undramatic atmosphere.
                var steady = input.defaults
                if let mood = steady.music, mood != .calm, mood != .contemplative, mood != .focus {
                    steady.music = .calm
                }
                return Fixed(atmosphere: steady, reason: .modeChange, keep: .nonFiction)
            }
            return nil
        }
    }

    private mutating func applyFixed(_ target: Atmosphere, reason: DecisionReason, keep: KeepReason,
                                     input: Input) -> Decision {
        let wantMusic = input.musicEnabled ? target.music.flatMap {
            AtmosphereMapper.playable($0, installed: input.installedMoods)
        } : nil
        let wantBase = input.ambienceEnabled
            ? (AtmosphereMapper.playable(target.base, installed: input.installedBeds) ?? .none) : .none
        let first = !started
        if first {
            started = true
            startTime = input.now
            blockStart = input.now
        }
        wasFixed = true
        // Keep the evidence in step with the reading, so returning to
        // automatic does not replay a backlog of windows.
        if let map = input.map, let index = map.windowIndex(containing: input.position) {
            consumedThrough = index
        }
        let crossfade = first ? min(input.crossfade, 4) : input.crossfade
        let firstReason: DecisionReason = first ? .start : reason
        var decision = Decision(music: .keep(keep), base: .keep(keep))
        if first || music.current != wantMusic {
            decision.music = .change(to: wantMusic, reason: firstReason, crossfade: crossfade)
            music.set(wantMusic, at: input.now, counts: false)
            logChange(.music, from: nil, to: wantMusic?.rawValue, reason: firstReason, input: input, check: nil)
        }
        if first || base.current != wantBase {
            decision.base = .change(to: wantBase, reason: firstReason, crossfade: crossfade)
            base.set(wantBase, at: input.now, counts: false)
            logChange(.base, from: nil, to: wantBase.rawValue, reason: firstReason, input: input, check: nil)
        }
        if input.mode == .study, input.override == nil, let block = input.studyBlock,
           input.now - blockStart >= block {
            blockStart = input.now
            decision.rotateMusicTexture = true
        }
        recordHeard(input.position)
        return decision
    }

    // MARK: Start

    private mutating func start(_ input: Input) -> Decision {
        started = true
        startTime = input.now
        blockStart = input.now
        var musicScores: [MusicMood: Double] = [:]
        var baseScores: [BaseAmbience: Double] = [:]
        var analysed = false
        if let map = input.map, let index = map.windowIndex(containing: input.position) {
            for i in index...min(index + 2, map.windows.count - 1) {
                guard let reading = map.reading(i) else { continue }
                analysed = true
                if let item = musicEvidence(reading, input) { musicScores[item.value, default: 0] += item.strength }
                if let item = baseEvidence(reading, input) { baseScores[item.value, default: 0] += item.strength }
            }
            consumedThrough = map.reading(index) != nil ? index : index - 1
        }
        provisional = !analysed
        music.evidence = musicScores
        base.evidence = baseScores
        let analysedMood = musicScores.max { $0.value < $1.value }.flatMap {
            $0.value >= config.startMusicEvidence ? $0.key : nil
        }
        let analysedBed = baseScores.max { $0.value < $1.value }.flatMap {
            $0.value >= config.startBaseEvidence ? $0.key : nil
        }
        let wantMusic = input.musicEnabled
            ? (analysedMood ?? input.defaults.music.flatMap { AtmosphereMapper.playable($0, installed: input.installedMoods) })
            : nil
        let wantBase = input.ambienceEnabled
            ? (analysedBed ?? AtmosphereMapper.playable(input.defaults.base, installed: input.installedBeds) ?? .none)
            : .none
        music.set(wantMusic, at: input.now, counts: false)
        base.set(wantBase, at: input.now, counts: false)
        logChange(.music, from: nil, to: wantMusic?.rawValue, reason: .start, input: input, check: nil)
        logChange(.base, from: nil, to: wantBase.rawValue, reason: .start, input: input, check: nil)
        recordHeard(input.position)
        let fade = min(input.crossfade, 4)
        return Decision(music: .change(to: wantMusic, reason: .start, crossfade: fade),
                        base: .change(to: wantBase, reason: .start, crossfade: fade))
    }

    // MARK: Evidence

    private func musicEvidence(_ reading: SceneReading, _ input: Input) -> LayerEvidence<MusicMood>? {
        guard input.musicEnabled,
              let item = AtmosphereMapper.music(for: reading, kind: input.map?.profile?.kind, intensity: input.intensity),
              let playable = AtmosphereMapper.playable(item.value, installed: input.installedMoods) else { return nil }
        return LayerEvidence(value: playable, strength: item.strength)
    }

    private func baseEvidence(_ reading: SceneReading, _ input: Input) -> LayerEvidence<BaseAmbience>? {
        guard input.ambienceEnabled,
              let item = AtmosphereMapper.base(for: reading, kind: input.map?.profile?.kind),
              let playable = AtmosphereMapper.playable(item.value, installed: input.installedBeds) else { return nil }
        return LayerEvidence(value: playable, strength: item.strength)
    }

    /// Takes in the windows read since the last step. The window being read
    /// counts once its analysis exists; a window left without one only decays
    /// the evidence. Returns whether a new window was entered.
    private mutating func consumeWindows(_ input: Input) -> Bool {
        guard let map = input.map, let index = map.windowIndex(containing: input.position) else { return false }
        let before = consumedThrough
        var next = consumedThrough + 1
        while next <= index {
            let status = map.status[next]
            if next == index, status == nil { break }
            let reading = status?.reading
            music.accumulate(reading.flatMap { musicEvidence($0, input) }, decay: config.music.decay)
            base.accumulate(reading.flatMap { baseEvidence($0, input) }, decay: config.base.decay)
            consumedThrough = next
            next += 1
        }
        return consumedThrough > before && before >= 0
    }

    // MARK: Evaluation

    private mutating func evaluate(_ input: Input, site: Bool,
                                   rules custom: ((LayerConfig) -> Rules)?) -> Decision {
        let window = input.map.flatMap { map in map.windowIndex(containing: input.position).map { map.windows[$0] } }
        let reading = window.flatMap { input.map?.reading($0.index) }
        let markedScene = reading?.sceneChange == .clear
            && (window?.startsChapter == true || window?.startsAfterSceneBreak == true)
        func rules(_ layer: LayerConfig, elapsed: TimeInterval) -> Rules {
            if let custom { return custom(layer) }
            if markedScene, elapsed >= layer.overrideFloor {
                return Rules(dwell: layer.overrideFloor, streak: max(layer.streak - 1, 1), enter: layer.enter,
                             margin: layer.margin, ambiguity: layer.ambiguity, cooldownWaived: false,
                             reason: .justifiedOverride)
            }
            return Rules(dwell: layer.dwell, streak: layer.streak, enter: layer.enter, margin: layer.margin,
                         ambiguity: layer.ambiguity, cooldownWaived: false, reason: .sceneChange)
        }
        var decision = Decision(music: .keep(.unchanged), base: .keep(.unchanged))

        if !input.musicEnabled {
            if music.current != nil {
                music.set(nil, at: input.now, counts: false)
                decision.music = .change(to: nil, reason: .layerToggle, crossfade: input.crossfade)
                logChange(.music, from: nil, to: nil, reason: .layerToggle, input: input, check: nil)
            } else {
                decision.music = .keep(.layerDisabled)
            }
        } else {
            let elapsed = input.now - music.since
            let verdict = Self.judge(&music, layer: config.music,
                                     rules: rules(config.music, elapsed: elapsed),
                                     now: input.now, site: site)
            switch verdict {
            case .keep(let reason):
                decision.music = .keep(reason)
                logKeep(.music, reason: reason, input: input)
            case .change(let value, let reason, let check):
                let old = music.current?.rawValue
                music.set(value, at: input.now, counts: true)
                decision.music = .change(to: value, reason: reason, crossfade: input.crossfade)
                logChange(.music, from: old, to: value.rawValue, reason: reason, input: input, check: check)
            }
        }

        if !input.ambienceEnabled {
            if base.current != BaseAmbience.none {
                base.set(BaseAmbience.none, at: input.now, counts: false)
                decision.base = .change(to: BaseAmbience.none, reason: .layerToggle, crossfade: input.crossfade)
                logChange(.base, from: nil, to: BaseAmbience.none.rawValue, reason: .layerToggle, input: input, check: nil)
            } else {
                decision.base = .keep(.layerDisabled)
            }
        } else {
            let elapsed = input.now - base.since
            let verdict = Self.judge(&base, layer: config.base,
                                     rules: rules(config.base, elapsed: elapsed),
                                     now: input.now, site: site)
            switch verdict {
            case .keep(let reason):
                decision.base = .keep(reason)
                logKeep(.base, reason: reason, input: input)
            case .change(let value, let reason, let check):
                let old = base.current?.rawValue
                base.set(value, at: input.now, counts: true)
                decision.base = .change(to: value, reason: reason, crossfade: input.crossfade)
                logChange(.base, from: old, to: value.rawValue, reason: reason, input: input, check: check)
            }
        }
        return decision
    }

    private enum Verdict<Value> {
        case keep(KeepReason)
        case change(Value, DecisionReason, ChangeCheck)
    }

    /// The rules, in order. Every one must pass; the first that fails is the
    /// reason the current value is kept.
    private static func judge<Value: Hashable & Sendable>(_ track: inout Track<Value>, layer: LayerConfig, rules: Rules,
                                     now: TimeInterval, site: Bool) -> Verdict<Value> {
        let incumbent = track.current.flatMap { track.evidence[$0] } ?? 0
        let ranked = track.evidence.filter { $0.key != track.current }.sorted {
            $0.value != $1.value ? $0.value > $1.value : "\($0.key)" < "\($1.key)"
        }
        guard let best = ranked.first, best.value > 0 else { return .keep(.noEvidence) }
        let elapsed = now - track.since
        guard elapsed >= rules.dwell else { return .keep(.dwell) }
        let streak = track.streakValue == best.key ? track.streak : 0
        guard streak >= rules.streak else { return .keep(.streakTooShort) }
        guard best.value >= rules.enter else { return .keep(.weakEvidence) }
        guard best.value - incumbent >= rules.margin else { return .keep(.marginTooSmall) }
        let runnerUp = max(ranked.dropFirst().first?.value ?? 0, incumbent)
        guard best.value - runnerUp >= rules.ambiguity else { return .keep(.ambiguous) }
        if !rules.cooldownWaived, let left = track.abandoned[best.key], now - left < layer.cooldown {
            return .keep(.cooldown)
        }
        let recent = track.changes.filter { now - $0 < 3_600 }.count
        guard recent < layer.hourlyCap else { return .keep(.hourlyCap) }
        guard site else { return .keep(.awaitingTransition) }
        let check = ChangeCheck(elapsed: elapsed, requiredDwell: rules.dwell, streak: streak,
                                requiredStreak: rules.streak, challenger: best.value, incumbent: incumbent,
                                runnerUp: runnerUp, enter: rules.enter, margin: rules.margin,
                                ambiguity: rules.ambiguity, cooldownWaived: rules.cooldownWaived,
                                atSite: site, changesInLastHour: recent, hourlyCap: layer.hourlyCap)
        return .change(best.key, rules.reason, check)
    }

    // MARK: Jumps

    private mutating func resolveJump(_ input: Input, from: Int, chapterChanged: Bool) -> Decision {
        if abs(input.position - from) >= config.restoreDistance,
           let segment = heard.last(where: { input.position >= $0.start && input.position <= $0.end }) {
            consumedThrough = input.map?.windowIndex(containing: input.position) ?? consumedThrough
            return restore(segment.atmosphere, input)
        }
        return reconsider(input, reason: .jumpReevaluation, chapterChanged: chapterChanged)
    }

    /// Rebuilds the evidence from the windows just before `position` as if
    /// they had been read, then applies the rules without the dwell.
    private mutating func reconsider(_ input: Input, reason: DecisionReason, chapterChanged: Bool) -> Decision {
        guard let map = input.map, let index = map.windowIndex(containing: input.position) else {
            return keepBoth(.noAnalysisAtJump, input)
        }
        let range = max(index - 2, 0)...index
        guard range.contains(where: { map.reading($0) != nil }) else {
            consumedThrough = index - 1
            return keepBoth(.noAnalysisAtJump, input)
        }
        music.evidence = [:]
        base.evidence = [:]
        music.streak = 0
        base.streak = 0
        for i in range {
            let reading = map.reading(i)
            music.accumulate(reading.flatMap { musicEvidence($0, input) }, decay: config.music.decay)
            base.accumulate(reading.flatMap { baseEvidence($0, input) }, decay: config.base.decay)
        }
        consumedThrough = map.reading(index) != nil ? index : index - 1
        return evaluate(input, site: true) { layer in
            Rules(dwell: 0, streak: 1, enter: layer.enter, margin: layer.margin, ambiguity: layer.ambiguity,
                  cooldownWaived: chapterChanged, reason: reason)
        }
    }

    private mutating func restore(_ atmosphere: Atmosphere, _ input: Input) -> Decision {
        var decision = Decision(music: .keep(.unchanged), base: .keep(.unchanged))
        let wantMusic = input.musicEnabled ? atmosphere.music : nil
        let wantBase = input.ambienceEnabled ? atmosphere.base : .none
        if music.current != wantMusic {
            let old = music.current?.rawValue
            music.set(wantMusic, at: input.now, counts: false)
            decision.music = .change(to: wantMusic, reason: .restoreAfterJump, crossfade: input.crossfade)
            logChange(.music, from: old, to: wantMusic?.rawValue, reason: .restoreAfterJump, input: input, check: nil)
        }
        if base.current != wantBase {
            let old = base.current?.rawValue
            base.set(wantBase, at: input.now, counts: false)
            decision.base = .change(to: wantBase, reason: .restoreAfterJump, crossfade: input.crossfade)
            logChange(.base, from: old, to: wantBase.rawValue, reason: .restoreAfterJump, input: input, check: nil)
        }
        music.evidence = [:]
        base.evidence = [:]
        return decision
    }

    // MARK: Bookkeeping

    private mutating func keepBoth(_ reason: KeepReason, _ input: Input) -> Decision {
        logKeep(.music, reason: reason, input: input)
        logKeep(.base, reason: reason, input: input)
        return Decision(music: .keep(reason), base: .keep(reason))
    }

    private mutating func recordHeard(_ position: Int) {
        let now = Atmosphere(base: base.current ?? .none, music: music.current)
        if let last = heard.last, last.atmosphere == now,
           position >= last.start, position - last.end <= 2 * SceneSegmenter.maximum {
            heard[heard.count - 1].end = max(last.end, position)
        } else {
            heard.append((position, position, now))
            if heard.count > 200 { heard.removeFirst(heard.count - 200) }
        }
    }

    private mutating func logChange(_ layer: Event.Layer, from: String?, to: String?, reason: DecisionReason,
                                    input: Input, check: ChangeCheck?) {
        append(Event(time: input.now, position: input.position, layer: layer, from: from, to: to,
                     reason: reason.rawValue, isChange: true, check: check))
        recordHeard(input.position)
    }

    private mutating func logKeep(_ layer: Event.Layer, reason: KeepReason, input: Input) {
        switch layer {
        case .music:
            guard music.lastKeep != reason else { return }
            music.lastKeep = reason
        case .base:
            guard base.lastKeep != reason else { return }
            base.lastKeep = reason
        }
        append(Event(time: input.now, position: input.position, layer: layer, from: nil, to: nil,
                     reason: reason.rawValue, isChange: false, check: nil))
    }

    private mutating func append(_ event: Event) {
        log.append(event)
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }
}

/// Audits a director log against its rules. Used by the long simulated
/// sessions: it validates that every automatic change was earned, without
/// imposing an arbitrary number of changes.
enum DirectorInvariants {
    static func violations(in log: [AmbienceDirector.Event],
                           config: AmbienceDirector.Config = .standard) -> [String] {
        var problems: [String] = []
        var lastChange: [AmbienceDirector.Event.Layer: TimeInterval] = [:]
        var leftAt: [String: TimeInterval] = [:]
        for event in log where event.isChange {
            let layer = event.layer == .music ? config.music : config.base
            let key = "\(event.layer.rawValue)"
            let reason = AmbienceDirector.DecisionReason(rawValue: event.reason)
            if reason?.isAutomatic == true {
                guard let check = event.check else {
                    problems.append("\(key) change at \(Int(event.time)) s has no recorded check")
                    continue
                }
                let floor = reason == .justifiedOverride ? layer.overrideFloor : layer.dwell
                if check.elapsed < floor { problems.append("\(key) changed after \(Int(check.elapsed)) s (< \(Int(floor)) s)") }
                if check.streak < max(layer.streak - (reason == .justifiedOverride ? 1 : 0), 1) {
                    problems.append("\(key) changed on a streak of \(check.streak)")
                }
                if check.challenger < layer.enter { problems.append("\(key) changed on weak evidence") }
                if check.challenger - check.incumbent < layer.margin { problems.append("\(key) changed inside the hysteresis margin") }
                if check.challenger - check.runnerUp < layer.ambiguity { problems.append("\(key) changed while ambiguous") }
                if !check.atSite { problems.append("\(key) changed outside a transition") }
                if check.changesInLastHour >= layer.hourlyCap { problems.append("\(key) exceeded the hourly cap") }
                // Independent of the recorded check: the timeline itself.
                if let previous = lastChange[event.layer], event.time - previous < layer.overrideFloor {
                    problems.append("\(key) changed \(Int(event.time - previous)) s after the previous change")
                }
                if let to = event.to, let left = leftAt["\(key).\(to)"], event.time - left < layer.cooldown {
                    problems.append("\(key) returned to \(to) \(Int(event.time - left)) s after leaving it")
                }
            }
            if let from = event.from { leftAt["\(key).\(from)"] = event.time }
            lastChange[event.layer] = event.time
        }
        return problems
    }
}
