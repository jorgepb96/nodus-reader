// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why an analysis request did not produce a reading.
enum SceneAnalysisFailure: Error, Equatable, Sendable {
    /// The model does not read this language: stop analysing the book.
    case unsupportedLanguage
    /// The model is busy, rate limited or its assets are missing: try later.
    case temporarilyUnavailable
    case other(String)
}

/// The prompt texts, shared by both paths and kept here so they can be read
/// and reviewed in one place.
enum ScenePrompt {
    static let instructions = """
    You tag passages of books for a reading app that plays quiet background music and ambient sound. \
    Describe only what is happening in the PASSAGE, at the moment it is told. The text before and after \
    it is context only. A thing that is merely mentioned (a battle remembered or discussed, a storm used \
    as a metaphor, a place someone talks about) does not set the scene. Essays, history and academic \
    writing that describe events are exposition, not scenes. Use unknown, neutral or none when the passage \
    does not say. Comic means the passage is written to be funny; dramatic means an emotional confrontation, \
    revelation or loss told as it happens. Ratings: 0 none, 1 slight, 2 clear, 3 strong.
    """

    static let documentInstructions = """
    You classify books for a reading app. Decide what kind of document a sample comes from: fiction \
    (novels, stories), narrativeNonfiction (history, biography or travel told as a story), essay, \
    academic (papers, textbooks), manual (instructions, technical), reference, poetry, drama or other.
    """

    static func passage(_ text: String, before: String, after: String, language: String) -> String {
        """
        Language of the book: \(language).
        BEFORE (context only): …\(before)
        PASSAGE: \(text)
        AFTER (context only): \(after)…
        """
    }

    /// The fallback asks for one line of plain text it can parse.
    static let lineFormat = """
    Answer with one line exactly in this form, using only the listed words:
    kind=scene|dialogue|summary|recollection|exposition|frontMatter; \
    setting=\(SceneSetting.allCases.map(\.rawValue).joined(separator: "|")); clarity=0-3; \
    weather=\(SceneWeather.allCases.map(\.rawValue).joined(separator: "|")); \
    tone=\(SceneTone.allCases.map(\.rawValue).joined(separator: "|")); \
    action=\(SceneAction.allCases.map(\.rawValue).joined(separator: "|")); intensity=0-3; \
    change=none|minor|clear; evidence=<at most 12 words copied from the passage>
    """
}

/// Parses the fallback's one-line answer. Anything outside the vocabulary
/// makes the whole answer invalid: no guessing.
enum SceneLineParser {
    static func parse(_ line: String, passage: String) -> SceneReading? {
        var fields: [String: String] = [:]
        for part in line.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            fields[pair[0].lowercased()] = pair[1]
        }
        guard let kind = fields["kind"].flatMap(PassageKind.init(rawValue:)),
              let setting = fields["setting"].flatMap(SceneSetting.init(rawValue:)),
              let clarity = fields["clarity"].flatMap(Int.init), (0...3).contains(clarity),
              let weather = fields["weather"].flatMap(SceneWeather.init(rawValue:)),
              let tone = fields["tone"].flatMap(SceneTone.init(rawValue:)),
              let action = fields["action"].flatMap(SceneAction.init(rawValue:)),
              let intensity = fields["intensity"].flatMap(Int.init), (0...3).contains(intensity),
              let change = fields["change"].flatMap(SceneChange.init(rawValue:)) else { return nil }
        let evidence = (fields["evidence"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"“”«» "))
        return SceneReading(passageKind: kind, setting: setting, settingClarity: clarity, weather: weather,
                            tone: tone, action: action, intensity: intensity, sceneChange: change,
                            evidence: evidence, evidenceVerified: SceneEvidence.verify(evidence, in: passage),
                            source: .generalFallback)
    }
}

/// Checks that the model's quoted evidence is really in the passage
/// (ignoring case, accents, punctuation and spacing).
enum SceneEvidence {
    /// An exact quote, or a close paraphrase whose content words (four
    /// letters or more) are mostly in the passage: the on-device model often
    /// lists phrases from the text instead of copying one. Invented details
    /// fail either way.
    static func verify(_ evidence: String, in passage: String) -> Bool {
        let quote = normalize(evidence)
        guard quote.count >= 3 else { return false }
        let text = normalize(passage)
        if text.contains(quote) { return true }
        let words: Set<String> = Set(text.split(separator: " ").map(String.init))
        let content: [String] = quote.split(separator: " ").map(String.init).filter { $0.count >= 4 }
        guard content.count >= 3 else { return false }
        // Same word, or the same stem (screamed/scream, laughed/laughing).
        let found = content.filter { (word: String) -> Bool in
            if words.contains(word) { return true }
            guard word.count >= 5 else { return false }
            let stem = String(word.prefix(5))
            return words.contains { (other: String) in other.hasPrefix(stem) }
        }.count
        return Double(found) / Double(content.count) >= 0.7
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedPassageKind { case scene, dialogue, summary, recollection, exposition, frontMatter }

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedSetting {
    case forest, sea, river, mountain, countryside, desert, snowfield, cave
    case city, village, home, tavern, library, sacred, castle, ship, space, unknown
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedWeather { case clear, rain, storm, wind, snow, unknown }

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedTone { case calm, warm, romantic, melancholic, mysterious, eerie, tense, epic, joyful, solemn, comic, dramatic, neutral }

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedAction {
    case conversation, contemplation, travel, exploration, battle, chase, celebration, ritual, work, rest, none
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedChange { case none, minor, clear }

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum TaggedDocumentKind {
    case fiction, narrativeNonfiction, essay, academic, manual, reference, poetry, drama, other
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "What is happening in the passage")
struct SceneTagging {
    @Guide(description: "What the passage is doing: a scene happening now, dialogue, a summary of events, a memory, exposition of ideas, or front matter")
    var passageKind: TaggedPassageKind
    @Guide(description: "Where the passage takes place; unknown if not stated")
    var setting: TaggedSetting
    @Guide(description: "How clearly the passage establishes that place, 0 to 3", .range(0...3))
    var settingClarity: Int
    @Guide(description: "Weather present in the scene itself")
    var weather: TaggedWeather
    var tone: TaggedTone
    var action: TaggedAction
    @Guide(description: "How intense the passage is, 0 still to 3 climactic", .range(0...3))
    var intensity: Int
    @Guide(description: "Whether the passage begins a different scene (place, time or characters) from the text before")
    var sceneChange: TaggedChange
    @Guide(description: "At most 12 words copied exactly from the passage that show the setting or the mood")
    var evidence: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct DocumentTagging {
    var kind: TaggedDocumentKind
}

/// Reads book passages with Apple's on-device model and answers in the
/// normalised vocabulary. Nothing leaves the device: only
/// `SystemLanguageModel` is used, never Private Cloud Compute. Requests go
/// through the app-wide gate, at background priority.
@available(iOS 26.0, macOS 26.0, *)
actor SceneAnalyzer {
    private let tagging = SystemLanguageModel(useCase: .contentTagging)
    /// Only for passages the tagging model refused (violence in fiction):
    /// permissive guardrails apply to plain-text answers only.
    private let fallback = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    static func modelState() -> ImmersiveAvailability.ModelState {
        switch SystemLanguageModel(useCase: .contentTagging).availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable: return .modelNotReady
        }
    }

    static func supports(languageCode: String) -> Bool {
        let code = Locale.Language(identifier: languageCode).languageCode
        return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode == code }
    }

    /// The model's guess for each sample.
    func documentVotes(samples: [String], language: String) async throws -> [DocumentKind] {
        var votes: [DocumentKind] = []
        for sample in samples {
            try Task.checkCancellation()
            let model = tagging
            // A sample the model refuses (war, violence) gives no vote; the
            // others and the text signals still decide.
            let kind: String?
            do {
                kind = try await run {
                    let session = LanguageModelSession(model: model, instructions: ScenePrompt.documentInstructions)
                    let response = try await session.respond(
                        to: "Language: \(language).\nSAMPLE: \(sample)", generating: DocumentTagging.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 20))
                    return "\(response.content.kind)"
                }
            } catch let error where Self.isRefusal(error) {
                kind = nil
            }
            if let kind, let value = DocumentKind(rawValue: kind) { votes.append(value) }
        }
        return votes
    }

    func analyse(passage: String, before: String, after: String, language: String) async throws -> WindowStatus {
        let prompt = ScenePrompt.passage(passage, before: before, after: after, language: language)
        do {
            let model = tagging
            let tagged = try await run {
                let session = LanguageModelSession(model: model, instructions: ScenePrompt.instructions)
                let response = try await session.respond(
                    to: prompt, generating: SceneTagging.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
                return TaggedValues(response.content)
            }
            guard let reading = tagged.reading(passage: passage) else { return .failed("vocabulary") }
            return .analysed(reading)
        } catch let failure as SceneAnalysisFailure {
            throw failure
        } catch let error where Self.isRefusal(error) {
            return try await analyseWithFallback(prompt: prompt, passage: passage)
        } catch {
            throw Self.failure(error)
        }
    }

    private func analyseWithFallback(prompt: String, passage: String) async throws -> WindowStatus {
        let model = fallback
        do {
            let line = try await run {
                let session = LanguageModelSession(model: model, instructions: ScenePrompt.instructions + "\n" + ScenePrompt.lineFormat)
                let response = try await session.respond(
                    to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
                return response.content
            }
            guard let reading = SceneLineParser.parse(line, passage: passage) else { return .declined }
            return .analysed(reading)
        } catch let error where Self.isRefusal(error) {
            return .declined
        } catch {
            throw Self.failure(error)
        }
    }

    private func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await OnDeviceModelGate.shared.run(.background, work)
    }

    /// Both error types the SDK can throw (`LanguageModelError` from 27).
    private static func isRefusal(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal, .decodingFailure: return true
            default: return false
            }
        }
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: return false
            }
        }
        return false
    }

    private static func failure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale: return SceneAnalysisFailure.unsupportedLanguage
            case .assetsUnavailable, .rateLimited, .concurrentRequests: return SceneAnalysisFailure.temporarilyUnavailable
            case .exceededContextWindowSize: return SceneAnalysisFailure.other("context")
            default: return SceneAnalysisFailure.other(error.localizedDescription)
            }
        }
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .unsupportedLanguageOrLocale: return SceneAnalysisFailure.unsupportedLanguage
            case .rateLimited, .timeout: return SceneAnalysisFailure.temporarilyUnavailable
            default: return SceneAnalysisFailure.other(error.localizedDescription)
            }
        }
        return SceneAnalysisFailure.other(error.localizedDescription)
    }
}

/// The generated values as plain strings (Sendable, outside the session).
@available(iOS 26.0, macOS 26.0, *)
private struct TaggedValues: Sendable {
    let kind, setting, weather, tone, action, change, evidence: String
    let clarity, intensity: Int

    init(_ tagging: SceneTagging) {
        kind = "\(tagging.passageKind)"
        setting = "\(tagging.setting)"
        weather = "\(tagging.weather)"
        tone = "\(tagging.tone)"
        action = "\(tagging.action)"
        change = "\(tagging.sceneChange)"
        evidence = tagging.evidence
        clarity = tagging.settingClarity
        intensity = tagging.intensity
    }

    func reading(passage: String) -> SceneReading? {
        guard let kind = PassageKind(rawValue: kind), let setting = SceneSetting(rawValue: setting),
              let weather = SceneWeather(rawValue: weather), let tone = SceneTone(rawValue: tone),
              let action = SceneAction(rawValue: action), let change = SceneChange(rawValue: change) else { return nil }
        return SceneReading(passageKind: kind, setting: setting, settingClarity: min(max(clarity, 0), 3),
                            weather: weather, tone: tone, action: action, intensity: min(max(intensity, 0), 3),
                            sceneChange: change, evidence: evidence,
                            evidenceVerified: SceneEvidence.verify(evidence, in: passage), source: .contentTagging)
    }
}
#endif
