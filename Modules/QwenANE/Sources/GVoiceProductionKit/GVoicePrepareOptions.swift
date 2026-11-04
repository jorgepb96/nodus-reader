import Foundation

public struct GVoicePrepareOptions: Sendable, Equatable {
    public var input: URL; public var output: URL; public var transcriptFile: URL
    public var sourceIdentity: String?; public var weights: URL?
    public var recipe: ReferenceCleanupRecipe

    public static func parse(_ arguments: [String]) throws -> Self {
        var input: URL?, output: URL?, transcript: URL?, sourceIdentity: String?, weights: URL?
        var segments: [ReferenceSegment] = []
        var mode = ReferenceCleanupMode.standard, denoise: ReferenceDenoise?
        var index = 0
        func value(_ flag: String) throws -> String {
            guard index + 1 < arguments.count else { throw ReferencePreparationError.invalidRecipe("missing value for \(flag)") }
            index += 1; return arguments[index]
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--input": input = URL(fileURLWithPath: try value(flag))
            case "--output": output = URL(fileURLWithPath: try value(flag), isDirectory: true)
            case "--transcript-file": transcript = URL(fileURLWithPath: try value(flag))
            case "--source-identity": sourceIdentity = try value(flag)
            case "--weights": weights = URL(fileURLWithPath: try value(flag), isDirectory: true)
            case "--mode":
                let raw = try value(flag)
                guard let parsed = ["standard": ReferenceCleanupMode.standard,
                                    "isolate-vocals": .isolateVocals][raw] else {
                    throw ReferencePreparationError.invalidRecipe("unknown mode \(raw)")
                }; mode = parsed
            case "--denoise":
                let raw = try value(flag)
                guard let parsed = ReferenceDenoise(rawValue: raw) else {
                    throw ReferencePreparationError.invalidRecipe("unknown denoise \(raw)")
                }; denoise = parsed
            case "--segment":
                let raw = try value(flag).split(separator: ":", omittingEmptySubsequences: false)
                guard raw.count == 2, let start = Double(raw[0]), let end = Double(raw[1]) else {
                    throw ReferencePreparationError.invalidRecipe("segment must be start:end seconds")
                }
                segments.append(.init(startSeconds: start, endSeconds: end))
            default: throw ReferencePreparationError.invalidRecipe("unknown option \(flag)")
            }
            index += 1
        }
        guard let input, let output, let transcript, !segments.isEmpty else {
            throw ReferencePreparationError.invalidRecipe("input, output, transcript-file, and segment are required")
        }
        var recipe = mode == .standard ? ReferenceCleanupRecipe.standard(segments: segments)
                                       : ReferenceCleanupRecipe.isolateVocals(segments: segments)
        if let denoise { recipe.denoise = denoise }
        if mode == .isolateVocals, recipe.denoise == .strong {
            throw ReferencePreparationError.invalidRecipe("strong denoise is invalid after isolation")
        }
        return .init(input: input, output: output, transcriptFile: transcript,
                     sourceIdentity: sourceIdentity, weights: weights, recipe: recipe)
    }
}
