// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct PlannerInput {
    var map: SceneMap?
    /// Character offset of the reader or narration in the story.
    var position: Int
    /// What the director plays now.
    var current: Atmosphere?
    var style: SoundscapeStyle
    var intensity: MusicIntensity
    /// Usable pieces already cached for a request (its style or neutral).
    var inventory: (PromptRequest) -> Int
    /// Prompts already used for this book.
    var used: Set<String>
    var studyOnly: Bool
    var bookID: UUID?
    var musicEnabled: Bool
    var ambienceEnabled: Bool
    /// About 30 minutes of narration ahead.
    var lookAheadWindows = 10
}

/// Decides what to generate next. Pure: the director alone decides when the atmosphere
/// changes; this only makes sure that what it may choose is ready.
enum SoundscapePlanner {
    static let maximumJobs = 6

    /// 1. What plays now: two music pieces (to rotate) and one bed (priority 3).
    /// 2. What the windows ahead favour: the two strongest other moods and the strongest
    ///    other bed, one piece each (priority 2).
    /// 3. Variety: up to four pieces of the current mood (priority 1).
    static func plan(_ input: PlannerInput, library: PromptLibrary, seed: UInt64) -> [GenerationJob] {
        var builder = Builder(library: library, seed: seed, used: input.used, bookID: input.bookID)
        let ahead = lookAhead(input)
        let here = ahead.first?.reading

        if input.musicEnabled, let mood = input.current?.music {
            let request = musicRequest(mood, input: input, reading: ahead.first { mood == evidenceMood($0.reading, input) }?.reading ?? here)
            let count = input.inventory(request)
            builder.add(request, priority: 3, count: max(0, 2 - count))
            if count >= 2, count < 4 { builder.add(request, priority: 1, count: 1) }
        }
        if input.ambienceEnabled, let bed = input.current?.base, bed != .none {
            let request = ambienceRequest(bed, input: input, reading: here)
            if input.inventory(request) < 1 { builder.add(request, priority: 3, count: 1) }
        }

        // Challengers from the evidence ahead.
        var moodScores: [MusicMood: (score: Double, reading: SceneReading)] = [:]
        var bedScores: [BaseAmbience: (score: Double, reading: SceneReading)] = [:]
        let kind = input.map?.profile?.kind
        for item in ahead {
            if let evidence = AtmosphereMapper.music(for: item.reading, kind: kind, intensity: input.intensity) {
                let previous = moodScores[evidence.value]
                let best = previous.map { evidence.strength > $0.score ? item.reading : $0.reading } ?? item.reading
                moodScores[evidence.value] = ((previous?.score ?? 0) + evidence.strength, best)
            }
            if let evidence = AtmosphereMapper.base(for: item.reading, kind: kind), evidence.value != .none {
                let previous = bedScores[evidence.value]
                bedScores[evidence.value] = ((previous?.score ?? 0) + evidence.strength, previous?.reading ?? item.reading)
            }
        }
        if input.musicEnabled {
            let challengers = moodScores.filter { $0.key != input.current?.music }
                .sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key.rawValue < $1.key.rawValue }
                .prefix(2)
            for (mood, value) in challengers {
                let request = musicRequest(mood, input: input, reading: value.reading)
                if input.inventory(request) < 1 { builder.add(request, priority: 2, count: 1) }
            }
        }
        if input.ambienceEnabled,
           let (bed, value) = bedScores.filter({ $0.key != input.current?.base })
               .max(by: { $0.value.score != $1.value.score ? $0.value.score < $1.value.score : $0.key.rawValue > $1.key.rawValue }) {
            let request = ambienceRequest(bed, input: input, reading: value.reading)
            if input.inventory(request) < 1 { builder.add(request, priority: 2, count: 1) }
        }
        return builder.finished()
    }

    /// The optional per-book pack: six music moods (the analysed book's strongest, then the
    /// style's usual ones, always calm) and three beds for the style.
    static func starterPack(style: SoundscapeStyle, map: SceneMap?, bookID: UUID?, library: PromptLibrary,
                            seed: UInt64, studyOnly: Bool = false, textLength: Int? = nil) -> [GenerationJob] {
        // Read aloud, ~900 characters a minute; a music piece rotates about every 6 min.
        let minutes = textLength.map { Double($0) / 900 }
        let musicCount = minutes.map { min(6, max(1, Int(($0 / 6).rounded(.up)))) } ?? 6
        let bedCount = minutes.map { $0 < 20 ? 1 : $0 < 60 ? 2 : 3 } ?? 3
        var moods: [MusicMood] = [.calm]
        if let map {
            var scores: [MusicMood: Double] = [:]
            for index in map.windows.indices {
                guard let reading = map.reading(index),
                      let evidence = AtmosphereMapper.music(for: reading, kind: map.profile?.kind, intensity: .balanced)
                else { continue }
                scores[evidence.value, default: 0] += evidence.strength
            }
            for mood in scores.sorted(by: { $0.value > $1.value }).map(\.key) where !moods.contains(mood) {
                moods.append(mood)
            }
        }
        for mood in defaultMoods(style) where !moods.contains(mood) { moods.append(mood) }
        var builder = Builder(library: library, seed: seed, used: [], bookID: bookID, limit: musicCount + bedCount)
        for mood in moods.prefix(musicCount) {
            builder.add(PromptRequest(layer: .music, style: style, mood: mood, bed: nil, emotion: nil, situation: nil,
                                      intensity: 2, setting: nil, studyOnly: studyOnly), priority: 3, count: 1)
        }
        for bed in defaultBeds(style).prefix(bedCount) {
            builder.add(PromptRequest(layer: .ambience, style: style, mood: nil, bed: bed, emotion: nil, situation: nil,
                                      intensity: 1, setting: nil, studyOnly: studyOnly), priority: 2, count: 1)
        }
        return builder.finished()
    }

    /// One piece for what the reader chose (or the director wants) and nothing has yet.
    static func job(layer: CatalogTrack.Layer, mood: MusicMood?, bed: BaseAmbience?, style: SoundscapeStyle,
                    bookID: UUID?, library: PromptLibrary, seed: UInt64, priority: Int,
                    studyOnly: Bool = false) -> GenerationJob? {
        var builder = Builder(library: library, seed: seed, used: [], bookID: bookID, limit: 1)
        builder.add(PromptRequest(layer: layer, style: style, mood: layer == .music ? mood : nil,
                                  bed: layer == .ambience ? bed : nil, emotion: nil, situation: nil,
                                  intensity: 2, setting: nil, studyOnly: studyOnly), priority: priority, count: 1)
        return builder.finished().first
    }

    static func defaultMoods(_ style: SoundscapeStyle) -> [MusicMood] {
        switch style {
        case .neutral: [.calm, .contemplative, .mysterious, .melancholic, .tense, .adventure]
        case .fantasy: [.calm, .mysterious, .adventure, .epic, .tense, .melancholic]
        case .scienceFiction: [.calm, .mysterious, .tense, .epic, .contemplative, .adventure]
        case .cyberpunk: [.calm, .mysterious, .tense, .melancholic, .dramatic, .adventure]
        case .horror: [.calm, .eerie, .tense, .mysterious, .dramatic, .melancholic]
        case .noir: [.calm, .mysterious, .tense, .melancholic, .contemplative, .dramatic]
        case .thriller: [.calm, .tense, .mysterious, .dramatic, .adventure, .contemplative]
        case .western: [.calm, .tense, .adventure, .melancholic, .epic, .contemplative]
        case .historical: [.calm, .solemn, .contemplative, .dramatic, .romantic, .tense]
        case .war: [.calm, .tense, .epic, .solemn, .melancholic, .dramatic]
        case .romance: [.calm, .romantic, .melancholic, .joyful, .contemplative, .dramatic]
        case .comedy: [.calm, .comic, .joyful, .romantic, .mysterious, .adventure]
        case .adventure: [.calm, .adventure, .epic, .mysterious, .tense, .joyful]
        case .fairyTale: [.calm, .joyful, .mysterious, .adventure, .melancholic, .comic]
        }
    }

    static func defaultBeds(_ style: SoundscapeStyle) -> [BaseAmbience] {
        switch style {
        case .neutral: [.rain, .forestDay, .fireplace]
        case .fantasy: [.forestDay, .fireplace, .cave]
        case .scienceFiction: [.city, .wind, .cave]
        case .cyberpunk: [.rain, .city, .tavern]
        case .horror: [.forestNight, .storm, .wind]
        case .noir: [.rain, .city, .tavern]
        case .thriller: [.city, .rain, .storm]
        case .western: [.wind, .fireplace, .tavern]
        case .historical: [.fireplace, .city, .rain]
        case .war: [.wind, .storm, .fireplace]
        case .romance: [.rain, .fireplace, .sea]
        case .comedy: [.city, .tavern, .forestDay]
        case .adventure: [.forestDay, .sea, .wind]
        case .fairyTale: [.forestDay, .fireplace, .stream]
        }
    }

    // MARK: Helpers

    private static func lookAhead(_ input: PlannerInput) -> [(index: Int, reading: SceneReading)] {
        guard let map = input.map, !map.windows.isEmpty else { return [] }
        let start = map.windowIndex(containing: input.position) ?? 0
        let end = min(map.windows.count, start + input.lookAheadWindows)
        return (start ..< end).compactMap { index in map.reading(index).map { (index, $0) } }
    }

    private static func evidenceMood(_ reading: SceneReading, _ input: PlannerInput) -> MusicMood? {
        AtmosphereMapper.music(for: reading, kind: input.map?.profile?.kind, intensity: input.intensity)?.value
    }

    private static func musicRequest(_ mood: MusicMood, input: PlannerInput, reading: SceneReading?) -> PromptRequest {
        PromptRequest(layer: .music, style: input.style, mood: mood, bed: nil, emotion: reading?.effectiveEmotion,
                      situation: reading?.effectiveSituation, intensity: min(max(reading?.intensity ?? 2, 1), 3),
                      setting: nil, studyOnly: input.studyOnly)
    }

    private static func ambienceRequest(_ bed: BaseAmbience, input: PlannerInput, reading: SceneReading?) -> PromptRequest {
        PromptRequest(layer: .ambience, style: input.style, mood: nil, bed: bed, emotion: nil, situation: nil,
                      intensity: 1, setting: reading.flatMap { $0.setting == .unknown ? nil : $0.setting },
                      studyOnly: input.studyOnly)
    }

    /// Picks distinct prompts and keeps the result ordered, unique and capped.
    private struct Builder {
        let library: PromptLibrary
        let seed: UInt64
        var used: Set<String>
        let bookID: UUID?
        var limit = SoundscapePlanner.maximumJobs
        private(set) var jobs: [GenerationJob] = []

        init(library: PromptLibrary, seed: UInt64, used: Set<String>, bookID: UUID?, limit: Int = SoundscapePlanner.maximumJobs) {
            self.library = library
            self.seed = seed
            self.used = used
            self.bookID = bookID
            self.limit = limit
        }

        /// Prompts chosen in this plan are excluded; the book's history only lowers a
        /// prompt's score.
        private var planned: Set<String> = []

        mutating func add(_ request: PromptRequest, priority: Int, count: Int) {
            for _ in 0 ..< count {
                let remaining = PromptLibrary(version: library.version, prompts: library.prompts.filter { !planned.contains($0.id) })
                guard let prompt = PromptSelector.select(request, from: remaining, used: used, seed: seed &+ UInt64(jobs.count))
                else { return }
                planned.insert(prompt.id)
                let job = GenerationJob(request: request, prompt: prompt, recipe: .full(for: request.layer), bookID: bookID,
                                        priority: priority)
                guard !jobs.contains(where: { $0.key == job.key }) else { return }
                jobs.append(job)
            }
        }

        func finished() -> [GenerationJob] {
            Array(jobs.enumerated().sorted {
                $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
            }.map(\.element).prefix(limit))
        }
    }
}
