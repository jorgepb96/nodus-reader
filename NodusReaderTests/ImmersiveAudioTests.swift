// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Testing
@testable import Nodus_Reader

// MARK: Fixtures

private func reading(_ setting: SceneSetting = .forest, tone: SceneTone = .calm, action: SceneAction = .none,
                     kind: PassageKind = .scene, intensity: Int = 1, clarity: Int = 3,
                     weather: SceneWeather = .clear, change: SceneChange = .none,
                     verified: Bool = true) -> SceneReading {
    SceneReading(passageKind: kind, setting: setting, settingClarity: clarity, weather: weather, tone: tone,
                 action: action, intensity: intensity, sceneChange: change, evidence: "the trees",
                 evidenceVerified: verified, source: .contentTagging)
}

/// A map of `readings.count` windows of 3,000 characters; a chapter starts
/// every `chapterEvery` windows.
private func sceneMap(_ readings: [SceneReading?], chapterEvery: Int = 6,
                      kind: DocumentKind = .fiction) -> SceneMap {
    var windows: [SceneWindow] = []
    var status: [Int: WindowStatus] = [:]
    for (index, item) in readings.enumerated() {
        windows.append(SceneWindow(index: index, start: index * 3_000, end: (index + 1) * 3_000,
                                   chapter: index / chapterEvery, startsChapter: index % chapterEvery == 0,
                                   startsAfterSceneBreak: false))
        if let item { status[index] = .analysed(item) }
    }
    var map = SceneMap(contentKey: "k", language: "en", windows: windows, status: status)
    map.profile = DocumentProfile(kind: kind, source: .model, votes: [kind], signals: .empty)
    return map
}

/// Narration at about 15 characters a second, one step every 15 seconds.
private struct Session {
    var director = AmbienceDirector()
    var now: TimeInterval = 0
    var position = 0
    var decisions: [AmbienceDirector.Decision] = []

    mutating func run(map: SceneMap, minutes: Double, mode: ImmersiveMode = .automatic,
                      intensity: MusicIntensity = .expressive,
                      configure: (inout AmbienceDirector.Input) -> Void = { _ in }) {
        let steps = Int(minutes * 4)
        for _ in 0..<steps {
            var input = AmbienceDirector.Input(now: now, position: position, movement: .natural,
                                               atTransitionSite: true, map: map, mode: mode, intensity: intensity)
            configure(&input)
            decisions.append(director.step(input))
            now += 15
            position += 225
        }
    }

    var changes: [AmbienceDirector.Event] { director.log.filter(\.isChange) }
    var automaticChanges: [AmbienceDirector.Event] {
        changes.filter { AmbienceDirector.DecisionReason(rawValue: $0.reason)?.isAutomatic == true }
    }
}

// MARK: Vocabulary and segmentation

@Test func immersiveVocabularyFallbacksNeverLoopAndEndCalm() {
    for mood in MusicMood.allCases {
        #expect(!mood.fallbacks.contains(mood))
    }
    #expect(AtmosphereMapper.playable(.epic, installed: [.calm]) == .calm)
    #expect(AtmosphereMapper.playable(.epic, installed: [.tense, .calm]) == .tense)
    #expect(AtmosphereMapper.playable(.storm, installed: [.rain]) == .rain)
    #expect(AtmosphereMapper.playable(.sea, installed: [.rain]) == nil)
    #expect(AtmosphereMapper.playable(BaseAmbience.none, installed: []) == BaseAmbience.none)
}

@Test func sceneWindowsTileTheStoryAtParagraphsWithoutCrossingChapters() {
    let paragraph = String(repeating: "The road wound on through the hills and the rain. ", count: 6)
    let chapter1 = (0..<40).map { _ in paragraph }.joined(separator: "\n")
    let chapter2 = (0..<25).map { _ in paragraph }.joined(separator: "\n") + "\n* * *\n"
        + (0..<20).map { _ in paragraph }.joined(separator: "\n")
    let story = StoryText(chapters: [chapter1, chapter2])
    let windows = SceneSegmenter.windows(in: story)
    #expect(windows.count > 4)
    #expect(windows.first?.start == story.storyStart)
    #expect(windows.last?.end == story.storyEnd)
    for (a, b) in zip(windows, windows.dropFirst()) {
        #expect(a.end <= b.start)
        #expect(b.start - a.end <= 2) // only the chapter separator is skipped
    }
    for window in windows {
        #expect(window.length <= SceneSegmenter.maximum + 2)
        // No window spans the second chapter's start.
        #expect(!(window.start < story.chapterStarts[1] && window.end > story.chapterStarts[1]))
    }
    #expect(windows.contains { $0.startsChapter && $0.start == story.chapterStarts[1] })
    #expect(windows.contains { $0.startsAfterSceneBreak })
    let map = SceneMap(contentKey: "k", language: "en", windows: windows)
    #expect(map.windowIndex(containing: windows[3].start + 10) == 3)
}

@Test func sceneMapIsRebuiltWhenTheTextOrVocabularyChanges() {
    let windows = [SceneWindow(index: 0, start: 0, end: 10, chapter: 0, startsChapter: true, startsAfterSceneBreak: false)]
    var map = SceneMap(contentKey: "a", language: "en", windows: windows)
    map.status[0] = .analysed(reading())
    #expect(map.adapted(contentKey: "a", language: "en", windows: windows).analysedCount == 1)
    #expect(map.adapted(contentKey: "b", language: "en", windows: windows).analysedCount == 0)
    #expect(map.adapted(contentKey: "a", language: "es", windows: windows).analysedCount == 0)
    var old = map
    old.vocabularyVersion = 0
    #expect(old.adapted(contentKey: "a", language: "en", windows: windows).analysedCount == 0)
    let keyA = ImmersiveContentKey.make(contentHash: "h", text: "one" as NSString)
    let keyB = ImmersiveContentKey.make(contentHash: "h", text: "two" as NSString)
    #expect(keyA != keyB)
}

@Test func documentProfileIsCautiousOnTiesAndCitations() {
    #expect(DocumentProfile.resolve(votes: [.fiction, .essay], signals: .empty).kind == .essay)
    #expect(DocumentProfile.resolve(votes: [.fiction, .fiction, .essay], signals: .empty).kind == .fiction)
    let academic = TextSignals.measure("As shown by Smith et al. (2019) and [12], the effect [3, 4] holds (2020).")
    #expect(academic.suggestedKind == .academic)
    #expect(DocumentProfile.resolve(votes: [.fiction], signals: academic).kind == .narrativeNonfiction)
    let dialogue = TextSignals.measure("“Come in,” she said.\nHe stood still.\n“Now,” she said.\n— Fine.")
    #expect(dialogue.suggestedKind == .fiction)
    #expect(DocumentProfile.resolve(votes: [], signals: dialogue).source == .heuristics)
}

// MARK: Mapper

@Test func historicalViolenceNeverMapsToEpicMusic() {
    let battle = reading(.countryside, tone: .tense, action: .battle, kind: .scene, intensity: 3)
    // An essay or academic text describing a battle has no scenes at all.
    #expect(AtmosphereMapper.music(for: battle, kind: .essay, intensity: .expressive) == nil)
    #expect(AtmosphereMapper.music(for: battle, kind: .academic, intensity: .expressive) == nil)
    // History told as a story: never dramatic.
    let history = AtmosphereMapper.music(for: battle, kind: .narrativeNonfiction, intensity: .expressive)
    #expect(history?.value.isDramatic == false)
    // Exposition and summary about a battle do not move the music.
    let told = reading(.countryside, tone: .tense, action: .battle, kind: .exposition, intensity: 3)
    #expect(AtmosphereMapper.music(for: told, kind: .fiction, intensity: .expressive) == nil)
    #expect(AtmosphereMapper.base(for: told, kind: .fiction) == nil)
    // A real battle scene in fiction does, subject to the intensity setting.
    #expect(AtmosphereMapper.music(for: battle, kind: .fiction, intensity: .expressive)?.value == .epic)
    #expect(AtmosphereMapper.music(for: battle, kind: .fiction, intensity: .subtle)?.value == .mysterious)
    let weaker = reading(.countryside, tone: .tense, action: .battle, kind: .dialogue, intensity: 1)
    #expect(AtmosphereMapper.music(for: weaker, kind: .fiction, intensity: .expressive)?.value.isDramatic == false)
    // A merely tense conversation is not a dramatic moment.
    let talk = reading(.tavern, tone: .tense, action: .conversation, kind: .scene, intensity: 2)
    #expect(AtmosphereMapper.music(for: talk, kind: .fiction, intensity: .expressive)?.value == .mysterious)
    // A storm told with a shouted order is still an intense moment.
    let storm = reading(.ship, tone: .tense, action: .work, kind: .dialogue, intensity: 3)
    #expect(AtmosphereMapper.music(for: storm, kind: .fiction, intensity: .expressive)?.value == .tense)
    // A comic chase is comedy.
    let comic = reading(.home, tone: .comic, action: .chase, kind: .dialogue, intensity: 2)
    #expect(AtmosphereMapper.music(for: comic, kind: .fiction, intensity: .expressive)?.value == .comic)
}

@Test func baseEvidenceNeedsAClearPlaceAndAVerifiedQuote() {
    #expect(AtmosphereMapper.base(for: reading(.forest, clarity: 3), kind: .fiction)?.value == .forestDay)
    #expect(AtmosphereMapper.base(for: reading(.forest, tone: .eerie, clarity: 3), kind: .fiction)?.value == .forestNight)
    // An unmatched (paraphrased) quote weakens a vague place; no grounding at all removes it.
    #expect((AtmosphereMapper.base(for: reading(.forest, clarity: 1, verified: false), kind: .fiction)?.strength ?? 0) < 1)
    var ungrounded = reading(.forest, clarity: 1, verified: false)
    ungrounded.evidence = "none"
    #expect(AtmosphereMapper.base(for: ungrounded, kind: .fiction) == nil)
    #expect(AtmosphereMapper.base(for: reading(.city, clarity: 2, weather: .rain), kind: .fiction)?.value == .rain)
    #expect(AtmosphereMapper.base(for: reading(.sea, kind: .summary, clarity: 3), kind: .fiction)?.strength == 1)
    #expect(AtmosphereMapper.base(for: reading(.sea, kind: .recollection, clarity: 3), kind: .fiction) == nil)
}

// MARK: Director

@Test func longSceneKeepsItsAtmosphereForAnHour() {
    let map = sceneMap(Array(repeating: reading(.forest, tone: .calm), count: 40))
    var session = Session()
    session.run(map: map, minutes: 60)
    #expect(session.automaticChanges.isEmpty)
    #expect(session.director.current == Atmosphere(base: .forestDay, music: .calm))
    #expect(DirectorInvariants.violations(in: session.director.log).isEmpty)
}

@Test func minorAndPassingChangesKeepTheAtmosphere() {
    // One tense window, alternating labels and weak evidence after dwell.
    var readings = Array(repeating: reading(.forest, tone: .calm), count: 30) as [SceneReading?]
    readings[10] = reading(.forest, tone: .tense, action: .chase, intensity: 3)
    for i in 14..<24 {
        readings[i] = i % 2 == 0 ? reading(.forest, tone: .mysterious, intensity: 2)
            : reading(.forest, tone: .romantic, intensity: 2)
    }
    readings[26] = reading(.forest, tone: .melancholic, kind: .summary, intensity: 1)
    var session = Session()
    session.run(map: sceneMap(readings), minutes: 90)
    #expect(session.automaticChanges.filter { $0.layer == .music }.isEmpty)
    let keeps = Set(session.director.log.filter { !$0.isChange }.map(\.reason))
    #expect(keeps.contains(AmbienceDirector.KeepReason.streakTooShort.rawValue))
    #expect(DirectorInvariants.violations(in: session.director.log).isEmpty)
}

@Test func ambiguousEvidenceKeepsTheCurrentMood() {
    var director = AmbienceDirector()
    var readings: [SceneReading?] = Array(repeating: reading(.forest, tone: .calm), count: 4)
    // Two moods equally supported, both strong, for a long stretch.
    for i in 0..<16 {
        readings.append(i % 2 == 0 ? reading(.forest, tone: .mysterious, intensity: 3)
                        : reading(.forest, tone: .melancholic, intensity: 3))
    }
    let map = sceneMap(readings, chapterEvery: 100)
    var now: TimeInterval = 0
    var position = 0
    var musicChanged = false
    while position < 60_000 {
        let decision = director.step(.init(now: now, position: position, atTransitionSite: true, map: map))
        if case .change(_, let reason, _) = decision.music, reason != .start { musicChanged = true }
        now += 15
        position += 225
    }
    #expect(!musicChanged)
}

@Test func clearNewSceneChangesAtATransitionAfterTheDwell() {
    var readings = Array(repeating: reading(.forest, tone: .calm), count: 12) as [SceneReading?]
    readings += [reading(.sea, tone: .mysterious, intensity: 2, change: .clear)]
    readings += Array(repeating: reading(.sea, tone: .mysterious, intensity: 2), count: 12)
    var session = Session()
    session.run(map: sceneMap(readings), minutes: 70)
    let music = session.automaticChanges.filter { $0.layer == .music }
    #expect(music.count == 1)
    #expect(music.first?.to == MusicMood.mysterious.rawValue)
    #expect((music.first?.position ?? 0) >= 12 * 3_000)
    let base = session.automaticChanges.filter { $0.layer == .base }
    #expect(base.first?.to == BaseAmbience.sea.rawValue)
    #expect(DirectorInvariants.violations(in: session.director.log).isEmpty)
}

@Test func changesWaitForANaturalPlaceToHappen() {
    var readings = Array(repeating: reading(.forest, tone: .calm), count: 3) as [SceneReading?]
    readings += Array(repeating: reading(.forest, tone: .mysterious, intensity: 3), count: 10)
    var director = AmbienceDirector()
    var now: TimeInterval = 0
    var position = 0
    var waited = false
    // Steps inside one window, never at a site: changes are held back.
    while position < 11 * 3_000 {
        let window = position / 3_000
        let decision = director.step(.init(now: now, position: position, atTransitionSite: false,
                                           map: sceneMap(readings)))
        if case .keep(.awaitingTransition) = decision.music { waited = true }
        if case .change(_, .sceneChange, _) = decision.music {
            // Only when a new window (a paragraph break) was entered.
            #expect(position % 3_000 < 225)
            _ = window
        }
        // The dwell (600 s) ends in the middle of a window.
        now += 6
        position += 225
    }
    #expect(waited)
}

@Test func cooldownPreventsReturningToAnAbandonedMood() {
    var readings = Array(repeating: reading(.forest, tone: .calm), count: 12) as [SceneReading?]
    readings += Array(repeating: reading(.forest, tone: .mysterious, intensity: 3), count: 12)
    readings += Array(repeating: reading(.forest, tone: .calm, intensity: 2), count: 10)
    var session = Session()
    session.run(map: sceneMap(readings, chapterEvery: 100), minutes: 150)
    let music = session.automaticChanges.filter { $0.layer == .music }
    #expect(music.first?.to == MusicMood.mysterious.rawValue)
    if music.count > 1, let first = music.first, let back = music.dropFirst().first(where: { $0.to == "calm" }) {
        #expect(back.time - first.time >= AmbienceDirector.Config.standard.music.cooldown)
    }
    #expect(DirectorInvariants.violations(in: session.director.log).isEmpty)
}

@Test func essaysGetASteadyUndramaticAtmosphere() {
    let battle = reading(.countryside, tone: .epic, action: .battle, kind: .scene, intensity: 3)
    let map = sceneMap(Array(repeating: battle, count: 30), kind: .essay)
    var session = Session()
    session.run(map: map, minutes: 60) { $0.defaults = Atmosphere(base: .library, music: .epic) }
    #expect(session.director.current?.music == .calm)
    #expect(session.director.current?.base == .library)
    #expect(session.automaticChanges.isEmpty)
}

@Test func studyModeIgnoresTheTextAndRotatesTexturesByBlock() {
    let map = sceneMap(Array(repeating: reading(.sea, tone: .epic, action: .battle, intensity: 3), count: 30))
    var session = Session()
    var rotations = 0
    session.run(map: map, minutes: 100, mode: .study) {
        $0.defaults = Atmosphere(base: .library, music: .focus)
        $0.studyBlock = 45 * 60
    }
    rotations = session.decisions.filter(\.rotateMusicTexture).count
    #expect(session.director.current == Atmosphere(base: .library, music: .focus))
    #expect(rotations == 2)
    #expect(session.automaticChanges.isEmpty)
}

@Test func manualChoiceAndLockOverrideAnalysis() {
    let map = sceneMap(Array(repeating: reading(.sea, tone: .mysterious, intensity: 3), count: 20))
    var director = AmbienceDirector()
    let rain = Atmosphere(base: .rain, music: nil)
    var decision = director.step(.init(now: 0, position: 0, map: map, override: .manual(rain)))
    #expect(decision.base == .change(to: .rain, reason: .start, crossfade: 4))
    for t in stride(from: 15.0, to: 3_000, by: 15) {
        decision = director.step(.init(now: t, position: Int(t) * 15, map: map, override: .lock(rain)))
        #expect(!decision.base.isChange)
        #expect(!decision.music.isChange)
    }
    // Back to automatic: re-evaluated at once from the text around the reader.
    decision = director.step(.init(now: 3_000, position: 45_000, map: map))
    #expect(director.current?.music == .mysterious)
    #expect(director.current?.base == .sea)
}

@Test func jumpsSettleRestoreHeardTextAndIgnoreSmallSteps() {
    var readings = Array(repeating: reading(.forest, tone: .calm), count: 10) as [SceneReading?]
    readings += Array(repeating: nil, count: 5) // not analysed yet
    readings += Array(repeating: reading(.sea, tone: .mysterious, intensity: 3), count: 10)
    let map = sceneMap(readings, chapterEvery: 5)
    var director = AmbienceDirector()
    var now: TimeInterval = 0
    _ = director.step(.init(now: now, position: 0, map: map))
    let start = director.current
    for position in stride(from: 225, through: 2_250, by: 225) {
        now += 15
        _ = director.step(.init(now: now, position: position, atTransitionSite: true, map: map))
    }
    // A step back is ignored.
    now += 15
    var decision = director.step(.init(now: now, position: 2_000, movement: .smallBack, map: map))
    #expect(decision.music == .keep(.unchanged))
    // Jump forward into unanalysed text: settle, then keep.
    now += 15
    decision = director.step(.init(now: now, position: 13 * 3_000, movement: .jump(chapterChanged: true), map: map))
    #expect(decision.music == .keep(.settling))
    now += 25
    decision = director.step(.init(now: now, position: 13 * 3_000 + 100, map: map))
    #expect(decision.music == .keep(.noAnalysisAtJump))
    #expect(director.current == start)
    // Jump into analysed text: after settling, re-evaluated with relaxed rules.
    now += 15
    _ = director.step(.init(now: now, position: 18 * 3_000, movement: .jump(chapterChanged: true), map: map))
    now += 25
    _ = director.step(.init(now: now, position: 18 * 3_000 + 100, map: map))
    #expect(director.current?.music == .mysterious)
    // Jump back to the beginning, already heard: what played there returns.
    now += 15
    _ = director.step(.init(now: now, position: 1_000, movement: .jump(chapterChanged: true), map: map))
    now += 25
    _ = director.step(.init(now: now, position: 1_100, map: map))
    #expect(director.current == start)
}

@Test func rapidJumpsWaitLongerBeforeReconsidering() {
    let map = sceneMap(Array(repeating: reading(.forest), count: 30))
    var director = AmbienceDirector()
    _ = director.step(.init(now: 0, position: 0, map: map))
    for (i, t) in [10.0, 20, 30].enumerated() {
        _ = director.step(.init(now: t, position: (i + 3) * 9_000, movement: .jump(chapterChanged: true), map: map))
    }
    let decision = director.step(.init(now: 60, position: 27_100, map: map))
    #expect(decision.music == .keep(.settling))
}

@Test func simulatedHourOfNarrationFollowsTheRules() {
    // A scripted book: long scenes, a few clear transitions, passing moods.
    var readings: [SceneReading?] = []
    readings += Array(repeating: reading(.home, tone: .warm), count: 5)
    readings += [reading(.home, tone: .tense, intensity: 2)]
    readings += Array(repeating: reading(.home, tone: .warm), count: 3)
    readings += [reading(.forest, tone: .mysterious, intensity: 2, change: .clear)]
    readings += Array(repeating: reading(.forest, tone: .mysterious, intensity: 2), count: 6)
    readings += [reading(.forest, tone: .epic, action: .battle, intensity: 3, change: .clear)]
    readings += Array(repeating: reading(.forest, tone: .epic, action: .battle, intensity: 3), count: 4)
    readings += Array(repeating: reading(.village, tone: .calm, kind: .summary), count: 6)
    var session = Session()
    session.run(map: sceneMap(readings), minutes: 60)
    #expect(DirectorInvariants.violations(in: session.director.log).isEmpty)
    let music = session.automaticChanges.filter { $0.layer == .music }
    // An hour can justify a few changes, never a constant stream.
    #expect(music.count <= 4)
    for (a, b) in zip(music, music.dropFirst()) {
        #expect(b.time - a.time >= AmbienceDirector.Config.standard.music.overrideFloor)
    }
}

@Test func randomSessionsNeverBreakTheStabilityRules() {
    var generator = SeededGenerator(seed: 0x5EED)
    let settings = SceneSetting.allCases
    let tones = SceneTone.allCases
    let kinds: [PassageKind] = [.scene, .scene, .dialogue, .summary, .exposition, .recollection]
    for _ in 0..<100 {
        var readings: [SceneReading?] = []
        var current = reading()
        for _ in 0..<40 {
            if Int.random(in: 0..<10, using: &generator) < 3 {
                current = reading(settings.randomElement(using: &generator)!,
                                  tone: tones.randomElement(using: &generator)!,
                                  action: SceneAction.allCases.randomElement(using: &generator)!,
                                  kind: kinds.randomElement(using: &generator)!,
                                  intensity: Int.random(in: 0...3, using: &generator),
                                  clarity: Int.random(in: 0...3, using: &generator),
                                  weather: SceneWeather.allCases.randomElement(using: &generator)!,
                                  change: SceneChange.allCases.randomElement(using: &generator)!,
                                  verified: Bool.random(using: &generator))
            }
            readings.append(Int.random(in: 0..<10, using: &generator) == 0 ? nil : current)
        }
        let map = sceneMap(readings, chapterEvery: Int.random(in: 3...8, using: &generator))
        var director = AmbienceDirector()
        var now: TimeInterval = 0
        var position = 0
        for _ in 0..<480 { // two hours
            var movement = AmbienceDirector.Movement.natural
            if Int.random(in: 0..<60, using: &generator) == 0 {
                position = Int.random(in: 0..<(40 * 3_000), using: &generator)
                movement = .jump(chapterChanged: Bool.random(using: &generator))
            }
            _ = director.step(.init(now: now, position: position, movement: movement,
                                    atTransitionSite: Bool.random(using: &generator), map: map,
                                    intensity: MusicIntensity.allCases.randomElement(using: &generator)!))
            now += 15
            position = min(position + 225, 40 * 3_000 - 1)
        }
        let problems = DirectorInvariants.violations(in: director.log)
        #expect(problems.isEmpty, "\(problems)")
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: Position and time

@Test func positionTrackerTellsReadingFromBrowsing() {
    var tracker = PositionTracker()
    let text = String(repeating: "word ", count: 2_000) + "\n" + String(repeating: "word ", count: 2_000) as NSString
    #expect(tracker.update(position: 0, chapter: 0, text: text).movement == .natural)
    #expect(tracker.update(position: 400, chapter: 0, text: text).movement == .natural)
    #expect(tracker.update(position: 200, chapter: 0, text: text).movement == .smallBack)
    let crossing = tracker.update(position: 9_000, chapter: 0, text: text)
    #expect(crossing.movement == .jump(chapterChanged: false))
    _ = tracker.update(position: 9_990, chapter: 0, text: text)
    #expect(tracker.update(position: 10_010, chapter: 0, text: text).crossedSite)
    #expect(tracker.update(position: 10_100, chapter: 1, text: text) == (.natural, true))
}

@Test func engagedClockCountsOnlyPlayingTime() {
    var clock = EngagedClock()
    _ = clock.tick(at: 0, playing: true)
    _ = clock.tick(at: 2, playing: true)
    _ = clock.tick(at: 4, playing: false)
    _ = clock.tick(at: 100, playing: false)
    _ = clock.tick(at: 101, playing: true)
    let total = clock.tick(at: 10_000, playing: true) // a suspended app: gap capped
    #expect(total == 2 + EngagedClock.maximumGap)
}

// MARK: Gain

@Test func equalPowerCrossfadeKeepsPowerAndMovesSmoothly() {
    let fadeOut = GainRamp(from: 1, to: 0, start: 0, duration: 12, shape: .equalPower)
    let fadeIn = GainRamp(from: 0, to: 1, start: 0, duration: 12, shape: .equalPower)
    var previous: (Double, Double)?
    for step in 0...1_200 {
        let t = Double(step) * 0.01
        let a = fadeOut.value(at: t)
        let b = fadeIn.value(at: t)
        #expect(abs(a * a + b * b - 1) < 1e-9)
        if let (pa, pb) = previous {
            for (x, y) in [(pa, a), (pb, b)] where x > 0.1 && y > 0.1 {
                #expect(abs(GainCurve.decibels(fromLinear: x) - GainCurve.decibels(fromLinear: y)) <= 0.25)
            }
        }
        previous = (a, b)
    }
}

@Test func duckingFallsQuicklyHoldsAndRecoversSlowly() {
    var duck = DuckingEnvelope(depth: -10)
    #expect(duck.gain(at: 0) == 1)
    duck.setAudible(true, at: 1)
    var last = duck.gain(at: 1)
    for step in 1...100 {
        let gain = duck.gain(at: 1 + Double(step) * 0.01)
        #expect(abs(GainCurve.decibels(fromLinear: gain) - GainCurve.decibels(fromLinear: last)) <= 0.4)
        last = gain
    }
    #expect(abs(GainCurve.decibels(fromLinear: duck.gain(at: 2)) + 10) < 0.01)
    // A pause between sentences shorter than the hold does not swell the music.
    duck.setAudible(false, at: 3)
    #expect(abs(GainCurve.decibels(fromLinear: duck.gain(at: 4.5)) + 10) < 0.01)
    duck.setAudible(true, at: 4.6)
    #expect(abs(GainCurve.decibels(fromLinear: duck.gain(at: 5)) + 10) < 0.01)
    duck.setAudible(false, at: 6)
    #expect(duck.gain(at: 7.9) < 0.33)
    #expect(abs(duck.gain(at: 9.3) - 1) < 1e-6)
}

@Test func headroomKeepsNarrationPlusMusicBelowFullScale() {
    for peak in stride(from: Float(0), through: 1, by: 0.05) {
        let ceiling = Headroom.ceiling(narrationPeak: peak)
        #expect(ceiling <= 0.89)
        #expect(ceiling >= 0.1)
        if peak <= 0.78 { #expect(peak + ceiling <= 0.98) }
    }
    #expect(VolumeTaper.gain(0.5) == 0.25)
}

// MARK: Policy and availability

@Test func pausePolicyFollowsNarrationAndTheReader() {
    var policy = ImmersivePlaybackPolicy()
    #expect(policy.handle(.enabled(true)) == nil)
    #expect(policy.handle(.readerOpened) == .play(fadeIn: 3))
    #expect(policy.handle(.narrationStarted) == nil)
    #expect(policy.handle(.narrationPaused) == .pause(fadeOut: 0.6))
    #expect(policy.handle(.narrationStarted) == .play(fadeIn: 1.2))
    // Narration in the background keeps the atmosphere.
    #expect(policy.handle(.appActive(false)) == nil)
    #expect(policy.handle(.interruptionBegan) == .pause(fadeOut: 0))
    #expect(policy.handle(.interruptionEnded) == .play(fadeIn: 2))
    #expect(policy.handle(.headphonesUnplugged) == .pause(fadeOut: 0))
    #expect(policy.handle(.readerActivity) == nil) // narration must restart first
    #expect(policy.handle(.narrationStarted) == .play(fadeIn: 1.2))
    #expect(policy.handle(.sleepTimerFired) == .pause(fadeOut: 3))
}

@Test func silentReadingStopsInTheBackgroundAndWhenIdle() {
    var policy = ImmersivePlaybackPolicy()
    _ = policy.handle(.enabled(true))
    #expect(policy.handle(.readerOpened) == .play(fadeIn: 3))
    #expect(policy.handle(.appActive(false)) == .pause(fadeOut: 3))
    #expect(policy.handle(.appActive(true)) == .play(fadeIn: 1.2))
    #expect(policy.handle(.idleTimeout) == .pause(fadeOut: 30))
    #expect(policy.handle(.readerActivity) == .play(fadeIn: 2))
    #expect(policy.handle(.readerClosed) == .pause(fadeOut: 2))
    var keep = ImmersivePlaybackPolicy(pausePolicy: .keepPlaying)
    _ = keep.handle(.enabled(true))
    _ = keep.handle(.readerOpened)
    _ = keep.handle(.narrationStarted)
    #expect(keep.handle(.narrationPaused) == nil)
    #expect(keep.handle(.bookFinished) == .pause(fadeOut: 8))
}

@Test func automaticModeIsOfferedOnlyWhereTheModelRuns() {
    let unsupported = ImmersiveAvailability.resolve(systemHasModel: false, model: nil, languageSupported: nil)
    #expect(unsupported == .unsupportedSystem)
    #expect(!unsupported.showsAutomatic && !unsupported.allowsAutomatic)
    #expect(unsupported.explanation != nil)
    let off = ImmersiveAvailability.resolve(systemHasModel: true, model: .appleIntelligenceOff, languageSupported: true)
    #expect(off.showsAutomatic && !off.allowsAutomatic)
    #expect(ImmersiveAvailability.resolve(systemHasModel: true, model: .deviceNotEligible, languageSupported: nil) == .deviceNotEligible)
    #expect(ImmersiveAvailability.resolve(systemHasModel: true, model: .modelNotReady, languageSupported: nil) == .modelNotReady)
    #expect(ImmersiveAvailability.resolve(systemHasModel: true, model: .available, languageSupported: false) == .languageUnsupported)
    #expect(ImmersiveAvailability.resolve(systemHasModel: true, model: .available, languageSupported: true).allowsAutomatic)
}

@Test func manualModeNeedsNoModelAtAll() {
    // A device without Apple Intelligence: manual and study still decide.
    var director = AmbienceDirector()
    let decision = director.step(.init(now: 0, position: 0, map: nil, mode: .manual,
                                       defaults: Atmosphere(base: .rain, music: .calm)))
    #expect(decision.base.isChange && decision.music.isChange)
    #expect(director.current == Atmosphere(base: .rain, music: .calm))
}

// MARK: Track rotation

private func track(_ id: String, mood: MusicMood = .calm, energy: Int = 1, subPool: String? = nil,
                   studySafe: Bool = true) -> CatalogTrack {
    CatalogTrack(
        id: id, layer: .music, title: id, author: "a", authorURL: nil,
        source: .init(provider: "p", pageURL: "u", fileURL: "f", retrievedOn: "2026-11-01", originalSHA256: "x",
                      originalBytes: 1, originalFormat: .init(codec: "wav", sampleRate: 48_000, channels: 2, bitRate: nil)),
        license: .init(spdx: "CC0-1.0", url: "l", evidence: .init(url: "e", snapshot: "s", snapshotSHA256: "h", quote: "q"),
                       verifiedOn: "2026-11-01", verifiedBy: "test"),
        processing: .init(transformations: [], tools: [:]),
        file: .init(path: "\(id).m4a", githubAssetName: nil, bytes: 1, sha256: "y", sampleRate: 48_000, channels: 2,
                    bitRateKbps: 160, frames: 48_000 * 120),
        audio: .init(integratedLUFS: -20, truePeakDBTP: -1.5, lra: nil, isLoop: false, tailStartSeconds: 110),
        semantics: .init(moods: [mood.rawValue], base: nil, energy: energy, studySafe: studySafe, subPool: subPool))
}

@Test func trackRotationAvoidsRepeatsAndRespectsEnergy() {
    let pool = [track("a"), track("b"), track("c", energy: 3), track("d", subPool: "piano")]
    var history = PlayHistory()
    var played: [String] = []
    var current: String?
    for minute in stride(from: 0.0, to: 40, by: 2) {
        let next = TrackSelector.next(from: pool, current: current, history: history, now: minute * 60, maximumEnergy: 1)
        #expect(next != nil)
        #expect(next?.id != current)
        #expect(next?.id != "c")
        current = next?.id
        history.played(current!, at: minute * 60)
        played.append(current!)
    }
    #expect(Set(played) == ["a", "b", "d"])
    let preferred = TrackSelector.next(from: pool, current: nil, history: PlayHistory(), now: 0, preferSubPool: "piano")
    #expect(preferred?.id == "d")
    #expect(TrackSelector.next(from: [track("solo")], current: "solo", history: history, now: 0)?.id == "solo")
}

// MARK: Narration integration

@Test func narrationBuffersAtOtherRatesAreConvertedForThePlayer() throws {
    // Ming speaks at 44.1 kHz; the narration player is wired at 24 kHz.
    let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
    let converted = try #require(PlaybackController.converted(buffer, to: target))
    #expect(converted.format.sampleRate == 24_000)
    #expect(abs(Int(converted.frameLength) - 24_000) <= 64)
    #expect(abs(PlaybackController.peak(of: converted) - 0.5) < 0.02)
    let same = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 10))
    #expect(PlaybackController.converted(same, to: target) === same)
}

@Test @MainActor func audioSessionKeepsSpokenAudioWhileNarrationOrItsListenerPlays() {
    typealias C = AudioSessionCoordinator
    #expect(C.configuration(for: [], current: nil) == nil)
    #expect(C.configuration(for: [.immersive], current: nil) == .mixedAmbience)
    #expect(C.configuration(for: [.narration, .immersive], current: .mixedAmbience) == .spokenAudio)
    #expect(C.configuration(for: [.immersive], current: .spokenAudio) == .spokenAudio)
}

@Test func onDeviceModelGateServesOneRequestAtATimeInteractiveFirst() async throws {
    let gate = OnDeviceModelGate()
    actor Recorder {
        var order: [String] = []
        var running = 0
        var maxRunning = 0
        func enter(_ name: String) { order.append(name); running += 1; maxRunning = max(maxRunning, running) }
        func leave() { running -= 1 }
    }
    let recorder = Recorder()
    let first = Task {
        try await gate.run(.background) {
            await recorder.enter("first")
            try await Task.sleep(for: .milliseconds(200))
            await recorder.leave()
        }
    }
    while !(await gate.isBusy) { await Task.yield() }
    let background = Task {
        try await gate.run(.background) { await recorder.enter("background"); await recorder.leave() }
    }
    while await gate.waitingCount < 1 { await Task.yield() }
    let cancelled = Task {
        try await gate.run(.background) { await recorder.enter("cancelled"); await recorder.leave() }
    }
    while await gate.waitingCount < 2 { await Task.yield() }
    let interactive = Task {
        try await gate.run(.interactive) { await recorder.enter("interactive"); await recorder.leave() }
    }
    while await gate.waitingCount < 3 { await Task.yield() }
    cancelled.cancel()
    try await first.value
    try await interactive.value
    try await background.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await recorder.order == ["first", "interactive", "background"])
    #expect(await recorder.maxRunning == 1)
}

// MARK: Engine (offline rendering)

/// Writes a stereo sine (left/right at `frequency`, right phase-shifted so
/// the file is truly stereo) and returns its URL.
private func writeTone(_ name: String, seconds: Double, frequency: Double, amplitude: Float, sampleRate: Double = 48_000,
                       aac: Bool = false) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name + (aac ? ".m4a" : ".caf"))
    try? FileManager.default.removeItem(at: url)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) {
        let phase = 2 * Double.pi * frequency * Double(i) / sampleRate
        buffer.floatChannelData![0][i] = amplitude * Float(sin(phase))
        buffer.floatChannelData![1][i] = amplitude * Float(sin(phase + .pi / 3))
    }
    let settings: [String: Any] = aac
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
           AVEncoderBitRateKey: 160_000]
        : format.settings
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
    return url
}

private func peak(_ buffer: AVAudioPCMBuffer, from: Int = 0) -> Float {
    var result: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        for i in from..<Int(buffer.frameLength) { result = max(result, abs(buffer.floatChannelData![channel][i])) }
    }
    return result
}

private func rms(_ buffer: AVAudioPCMBuffer, from: Int, to: Int) -> Double {
    var sum = 0.0
    let data = buffer.floatChannelData![0]
    for i in from..<to { sum += Double(data[i] * data[i]) }
    return (sum / Double(max(to - from, 1))).squareRoot()
}

/// Largest jump between consecutive samples (a click shows up as a spike).
private func largestStep(_ buffer: AVAudioPCMBuffer, from: Int) -> Float {
    var result: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for i in max(from, 1)..<Int(buffer.frameLength) { result = max(result, abs(data[i] - data[i - 1])) }
    }
    return result
}

private func request(_ id: String, _ url: URL, _ layer: ImmersiveAudioEngine.Layer, loop: Bool = false,
                     tail: TimeInterval? = nil) -> ImmersiveAudioEngine.TrackRequest {
    .init(id: id, url: url, layer: layer, loop: loop, tailStart: tail)
}

@Test func immersiveMixNeverExceedsTheCeilingLeftByNarration() throws {
    let a = try writeTone("full-a", seconds: 6, frequency: 220, amplitude: 0.99)
    let b = try writeTone("full-b", seconds: 6, frequency: 330, amplitude: 0.99)
    let bed = try writeTone("full-bed", seconds: 6, frequency: 110, amplitude: 0.99, sampleRate: 44_100)
    let engine = ImmersiveAudioEngine(mode: .offline(sampleRate: 48_000))
    engine.start(fadeIn: 0.05)
    engine.setVolume(.music, slider: 1, duration: 0)
    engine.setVolume(.ambience, slider: 1, duration: 0)
    engine.setNarrationPeak(0.6)
    engine.play(request("a", a, .music), crossfade: 0.05)
    engine.play(request("bed", bed, .ambience, loop: true), crossfade: 0.05)
    _ = try engine.render(seconds: 1)
    engine.play(request("b", b, .music), crossfade: 3)
    let output = try engine.render(seconds: 4)
    let ceiling = Headroom.ceiling(narrationPeak: 0.6)
    // The limiter may overshoot by a fraction of a decibel on its attack.
    #expect(peak(output) <= ceiling * 1.12)
    #expect(peak(output) > ceiling * 0.5)
    engine.shutdown()
}

@Test func crossfadesAndLoopsAreClickFreeAndGapless() throws {
    // 440 whole cycles in one second: a loop whose seam is continuous.
    let loop = try writeTone("loop", seconds: 1, frequency: 440, amplitude: 0.5)
    let other = try writeTone("other", seconds: 6, frequency: 220, amplitude: 0.5)
    let engine = ImmersiveAudioEngine(mode: .offline(sampleRate: 48_000))
    engine.start(fadeIn: 0.05)
    engine.setVolume(.music, slider: 1, duration: 0)
    engine.setVolume(.ambience, slider: 1, duration: 0)
    engine.play(request("loop", loop, .ambience, loop: true), crossfade: 0.2)
    let looped = try engine.render(seconds: 3.5)
    // After the fade-in, three loop seams pass with no gap and no click.
    let settled = Int(0.3 * 48_000)
    let sineStep = Float(2 * Double.pi * 440 / 48_000) * 0.5 * Float(Headroom.ambienceBusCap)
    #expect(largestStep(looped, from: settled) <= sineStep * 1.1)
    #expect(rms(looped, from: settled, to: Int(looped.frameLength)) > 0.1)
    // A long crossfade between two pieces moves without steps.
    engine.play(request("other", other, .ambience), crossfade: 2)
    let crossfade = try engine.render(seconds: 2.5)
    let combined = Float(2 * Double.pi * 440 / 48_000) * 0.5 * Float(Headroom.ambienceBusCap) * 1.5
    #expect(largestStep(crossfade, from: 0) <= combined)
    engine.shutdown()
}

@Test func compressedMusicDecodesWithItsLengthAndContent() throws {
    let url = try writeTone("aac", seconds: 2, frequency: 440, amplitude: 0.5, sampleRate: 44_100, aac: true)
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.formatDescription.audioFormatList.first?.mASBD.mFormatID == kAudioFormatMPEG4AAC)
    #expect(file.processingFormat.channelCount == 2)
    // Encoder priming is trimmed: the decoded length is the written length.
    #expect(abs(file.length - 88_200) <= 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let level = rms(buffer, from: 4_410, to: 84_000)
    #expect(abs(level - 0.5 / 2.0.squareRoot()) < 0.02)
}

@Test func musicDucksUnderNarrationAndRecovers() throws {
    let tone = try writeTone("duck", seconds: 12, frequency: 220, amplitude: 0.5)
    let engine = ImmersiveAudioEngine(mode: .offline(sampleRate: 48_000))
    engine.start(fadeIn: 0.05)
    engine.setVolume(.music, slider: 1, duration: 0)
    engine.play(request("duck", tone, .music), crossfade: 0.05)
    let open = try engine.render(seconds: 1)
    engine.setNarrationAudible(true)
    let ducked = try engine.render(seconds: 1.5)
    engine.setNarrationAudible(false)
    let held = try engine.render(seconds: 1.5)
    let released = try engine.render(seconds: 2.5)
    let full = rms(open, from: 24_000, to: 48_000)
    let low = rms(ducked, from: 48_000, to: 72_000)
    #expect(abs(20 * log10(low / full) + 10) < 0.5)
    // Still ducked during the hold after speech stops…
    #expect(abs(20 * log10(rms(held, from: 24_000, to: 48_000) / full) + 10) < 0.5)
    // …then back up.
    #expect(abs(20 * log10(rms(released, from: 72_000, to: 120_000) / full)) < 0.5)
    engine.shutdown()
}

@Test func engineResumesWhereItWasAfterAConfigurationChange() throws {
    let tone = try writeTone("long", seconds: 10, frequency: 220, amplitude: 0.5)
    let engine = ImmersiveAudioEngine(mode: .offline(sampleRate: 48_000))
    engine.start(fadeIn: 0.05)
    engine.play(request("long", tone, .music), crossfade: 0.05)
    _ = try engine.render(seconds: 2)
    let before = try #require(engine.position(.music))
    #expect(abs(Double(before) / 48_000 - 2) < 0.05)
    engine.simulateConfigurationChange()
    _ = try engine.render(seconds: 0.5)
    let after = try #require(engine.position(.music))
    #expect(abs(Double(after - before) / 48_000 - 0.5) < 0.05)
    engine.shutdown()
}

@Test func silentTestRunsRenderNothingAndShutdownReleasesTheEngine() throws {
    let tone = try writeTone("silent", seconds: 2, frequency: 220, amplitude: 0.5)
    weak var released: ImmersiveAudioEngine?
    do {
        let engine = ImmersiveAudioEngine(mode: .offline(sampleRate: 48_000), silent: true)
        released = engine
        engine.start(fadeIn: 0.05)
        engine.play(request("s", tone, .music, tail: 1), crossfade: 0.05)
        var tails: [String] = []
        engine.onTrackTail = { _, id in tails.append(id) }
        let output = try engine.render(seconds: 1.5)
        #expect(peak(output) == 0)
        #expect(tails == ["s"])
        engine.shutdown()
        #expect(engine.isShutDown)
    }
    #expect(released == nil)
}

// MARK: Catalog, downloads and analysis scheduling

@Test func downloadsFallBackToTheMirrorAndRejectAlteredFiles() async throws {
    let source = try writeTone("mirror-source", seconds: 1, frequency: 330, amplitude: 0.3)
    let bytes = FileStore.fileSize(at: source)
    let hash = try ContentHash.sha256(of: source)
    var item = track("mirror")
    item.file = .init(path: "music/mirror.caf", githubAssetName: "mirror.caf", bytes: bytes, sha256: hash,
                      sampleRate: 48_000, channels: 2, bitRateKbps: 0, frames: 48_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-library-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    // The first host is missing the file; the second (the mirror) has it.
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID())/mirror.caf")
    try await ImmersiveAudioLibrary.download(item, urls: [missing, source], into: root)
    #expect(try ContentHash.sha256(of: root.appendingPathComponent("music/mirror.caf")) == hash)
    // A file that does not match the manifest is never kept.
    var altered = item
    altered.file.sha256 = String(repeating: "0", count: 64)
    altered.file.path = "music/altered.caf"
    await #expect(throws: (any Error).self) {
        try await ImmersiveAudioLibrary.download(altered, urls: [source], into: root)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("music/altered.caf").path))
}

@Test func catalogURLsTryHuggingFaceFirstThenTheGitHubRelease() {
    var item = track("a")
    item.file.path = "music/calm/a b.m4a"
    item.file.githubAssetName = "music.calm.a.m4a"
    let catalog = ImmersiveCatalog(schemaVersion: 1, catalogVersion: "t", hosts: [
        .init(name: "huggingface", baseURL: "https://huggingface.co/datasets/x/y/resolve/abc/"),
        .init(name: "github", baseURL: "https://github.com/x/y/releases/download/t/"),
        .init(name: "unpublished", baseURL: "https://example.invalid/<commit>/"),
    ], packs: [], tracks: [item])
    let urls = catalog.urls(for: item).map(\.absoluteString)
    #expect(urls == ["https://huggingface.co/datasets/x/y/resolve/abc/music/calm/a%20b.m4a",
                     "https://github.com/x/y/releases/download/t/music.calm.a.m4a"])
}

@Test func bundledCatalogIsCompleteAndLicensed() throws {
    guard let catalog = ImmersiveCatalog.bundled() else {
        Issue.record("The app bundle has no Immersive Audio catalog")
        return
    }
    #expect(catalog.schemaVersion == ImmersiveCatalog.supportedSchema)
    #expect(!catalog.tracks.isEmpty)
    #expect(Set(catalog.tracks.map(\.id)).count == catalog.tracks.count)
    #expect(Set(catalog.tracks.map(\.file.sha256)).count == catalog.tracks.count)
    #expect(Set(catalog.tracks.map(\.source.originalSHA256)).count == catalog.tracks.count)
    let hex = try Regex("^[0-9a-f]{64}$")
    for track in catalog.tracks {
        // Public domain dedication or attribution only: never ShareAlike, NC or ND.
        #expect(["CC0-1.0", "CC-BY-3.0", "CC-BY-4.0"].contains(track.license.spdx), "\(track.id)")
        #expect(track.license.url.hasPrefix("https://creativecommons.org/publicdomain/zero/1.0")
                || track.license.url.hasPrefix("https://creativecommons.org/licenses/by/"), "\(track.id)")
        #expect(!track.author.isEmpty && !track.source.pageURL.isEmpty, "\(track.id): attribution needs an author and a source")
        #expect(!track.license.evidence.url.isEmpty && !track.license.evidence.quote.isEmpty, "\(track.id)")
        #expect(!track.license.verifiedOn.isEmpty, "\(track.id)")
        #expect(track.file.sha256.wholeMatch(of: hex) != nil, "\(track.id)")
        #expect(track.source.originalSHA256.wholeMatch(of: hex) != nil, "\(track.id)")
        #expect(track.audio.truePeakDBTP <= -1.0, "\(track.id)")
        #expect(track.file.channels == 2 || track.layer == .ambience, "\(track.id)")
        if track.layer == .music {
            #expect(!track.moods.isEmpty, "\(track.id)")
        } else {
            #expect(track.bed != nil && track.audio.isLoop, "\(track.id)")
        }
    }
    let ids = Set(catalog.tracks.map(\.id))
    for pack in catalog.packs {
        #expect(pack.trackIDs.allSatisfy(ids.contains), "\(pack.id)")
        let bytes = catalog.tracks(in: pack).reduce(Int64(0)) { $0 + $1.file.bytes }
        #expect(pack.bytes == bytes, "\(pack.id)")
    }
    #expect(catalog.hosts.map(\.name) == ["huggingface", "github"])
}

/// Decodes every file of a processed pack (opt-in: point
/// NODUS_IMMERSIVE_PACK_ROOT at `build/immersive-audio/packs`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_IMMERSIVE_PACK_ROOT"] != nil))
func processedPackFilesMatchTheManifestAndDecode() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NODUS_IMMERSIVE_PACK_ROOT"]!)
    let catalog = try #require(ImmersiveCatalog.bundled())
    for track in catalog.tracks {
        let url = root.appendingPathComponent(track.file.path)
        #expect(try ContentHash.sha256(of: url) == track.file.sha256, "\(track.id)")
        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - track.file.frames) <= 1, "\(track.id)")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(min(file.length, 48_000 * 30))))
        try file.read(into: buffer)
        #expect(peak(buffer) < 0.95, "\(track.id)")
    }
}

@Test func analysisLooksAheadOfTheReaderNotAtTheWholeBook() {
    var map = sceneMap(Array(repeating: nil, count: 40))
    var order = SceneAnalysisScheduler.queue(map: map, around: 5)
    #expect(order.first == 5)
    #expect(Array(order.prefix(11)) == Array(5...15))
    #expect(Array(order.suffix(2)) == [4, 3])
    #expect(!order.contains(30))
    map.status[5] = .analysed(reading())
    map.status[6] = .declined
    order = SceneAnalysisScheduler.queue(map: map, around: 5)
    #expect(order.first == 7)
    #expect(SceneAnalysisScheduler.queue(map: map, around: 39).first == 39)
    let story = StoryText(chapters: [String(repeating: "A line of a story that goes on.\n", count: 600)])
    let samples = SceneAnalysisScheduler.profileSamples(story)
    #expect(samples.count == 3)
    #expect(samples.allSatisfy { $0.count <= 1_500 && $0.count > 200 })
}

@Test func fallbackLineParserAcceptsOnlyTheVocabulary() {
    let passage = "The rain hammered the deck as the ship rolled."
    let line = "kind=scene; setting=ship; clarity=3; weather=storm; tone=tense; action=work; intensity=2; change=clear; evidence=\"The rain hammered the deck\""
    let reading = SceneLineParser.parse(line, passage: passage)
    #expect(reading?.setting == .ship)
    #expect(reading?.weather == .storm)
    #expect(reading?.evidenceVerified == true)
    #expect(reading?.source == .generalFallback)
    #expect(SceneLineParser.parse(line.replacingOccurrences(of: "ship;", with: "spaceship;"), passage: passage) == nil)
    #expect(SceneLineParser.parse(line.replacingOccurrences(of: "intensity=2", with: "intensity=7"), passage: passage) == nil)
    #expect(!SceneEvidence.verify("a dragon appeared", in: passage))
    #expect(SceneEvidence.verify("RAIN hammered, the deck", in: passage))
    // A paraphrase of phrases in the text passes; invented details do not.
    let goose = "The goose escaped, the vicar's wife screamed and the bishop laughed until he cried."
    #expect(SceneEvidence.verify("goose escaped, vicar's wife screamed, bishop laughed", in: goose))
    #expect(!SceneEvidence.verify("dragon breathed fire over castle walls", in: goose))
}

@Test func scheduleStoresAnalysisPerBookAndTextVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-store-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SceneMapStore(root: root)
    let id = UUID()
    var map = sceneMap([reading(), nil])
    map.contentKey = "hash-1"
    store.saveMap(map, bookID: id)
    let loaded = try #require(store.loadMap(bookID: id))
    #expect(loaded.analysedCount == 1)
    #expect(loaded.adapted(contentKey: "hash-2", language: "en", windows: loaded.windows).analysedCount == 0)
    store.savePreferences(ImmersiveBookPreferences(mode: nil, atmosphere: Atmosphere(base: .rain, music: nil), locked: true),
                          bookID: id)
    #expect(store.loadPreferences(bookID: id)?.locked == true)
    #expect(store.bookIDs() == [id])
    store.remove(bookID: id)
    #expect(store.bookIDs().isEmpty)
}

@Test @MainActor func schedulerAnalysesAheadAndStopsWhenTheBookCloses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-sched-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paragraph = String(repeating: "She walked under the dark trees of the old forest. ", count: 8)
    let story = StoryText(chapters: [(0..<120).map { _ in paragraph }.joined(separator: "\n")])
    let windows = SceneSegmenter.windows(in: story)
    let id = UUID()
    var calls: [Int] = []
    let scheduler = SceneAnalysisScheduler(
        store: SceneMapStore(root: root),
        analyse: { window, _ in
            calls.append(window.index)
            return .analysed(reading())
        },
        vote: { _ in [.fiction, .fiction, .fiction] })
    scheduler.start(map: SceneMap(contentKey: "k", language: "en", windows: windows),
                    context: .init(bookID: id, story: story, language: "en", languageName: "English"),
                    conditions: .init(canRun: { true }, position: { 0 }))
    try await Task.sleep(for: .seconds(4))
    scheduler.stop()
    let analysed = calls.count
    #expect(analysed == min(SceneAnalysisScheduler.horizon + 1, windows.count))
    #expect(scheduler.map?.profile?.kind == .fiction)
    try await Task.sleep(for: .milliseconds(300))
    #expect(calls.count == analysed)
    #expect(SceneMapStore(root: root).loadMap(bookID: id)?.analysedCount == analysed)
}
