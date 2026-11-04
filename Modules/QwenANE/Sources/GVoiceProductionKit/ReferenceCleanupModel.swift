import Foundation
import GVoiceKit

public struct ReferenceSegment: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public init(startSeconds: Double, endSeconds: Double) { self.startSeconds = startSeconds; self.endSeconds = endSeconds }
}

public enum ReferenceCleanupMode: String, Codable, Sendable { case standard, isolateVocals }
public enum ReferenceDenoise: String, Codable, Sendable { case none, light, strong }

public struct StemSeparationRecipe: Codable, Sendable, Equatable {
    public var backend: String
    public var backendVersion: String?
    public var model: String
    public var shifts: Int
    public var overlap: Double
    public init(backend: String = "swift-demucs-mlx", backendVersion: String? = nil,
                model: String = "htdemucs_ft", shifts: Int = 1, overlap: Double = 0.5) {
        self.backend = backend; self.backendVersion = backendVersion; self.model = model
        self.shifts = shifts; self.overlap = overlap
    }
}

public struct ReferenceCleanupRecipe: Codable, Sendable, Equatable {
    public static let schema = "gvoice.reference-cleanup.v1"
    public var mode: ReferenceCleanupMode
    public var segments: [ReferenceSegment]
    public var highpassHz: Double
    public var lowpassHz: Double
    public var denoise: ReferenceDenoise
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double
    public var joinSilenceSeconds: Double
    public var packSampleRate: Int
    public var packChannels: Int
    public var packPCMBitDepth: Int
    public var separation: StemSeparationRecipe?

    public static func standard(segments: [ReferenceSegment]) -> Self {
        .init(mode: .standard, segments: segments, highpassHz: 70, lowpassHz: 15_000,
              denoise: .light, fadeInSeconds: 0.05, fadeOutSeconds: 0.25,
              joinSilenceSeconds: 0.35, packSampleRate: 24_000, packChannels: 1,
              packPCMBitDepth: 16, separation: nil)
    }

    public static func isolateVocals(segments: [ReferenceSegment]) -> Self {
        var value = standard(segments: segments)
        value.mode = .isolateVocals; value.denoise = .none; value.separation = .init()
        return value
    }

    public func validated(sourceDuration: Double) throws -> Self {
        guard sourceDuration.isFinite, sourceDuration > 0, !segments.isEmpty else {
            throw ReferencePreparationError.invalidRecipe("source duration and segments must be non-empty")
        }
        var previousEnd = -Double.infinity
        for (index, segment) in segments.enumerated() {
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite,
                  segment.startSeconds >= 0, segment.endSeconds > segment.startSeconds,
                  segment.endSeconds <= sourceDuration else {
                throw ReferencePreparationError.invalidSegment(index: index, reason: "outside source bounds")
            }
            guard segment.startSeconds >= previousEnd else {
                throw ReferencePreparationError.invalidSegment(index: index, reason: "segments overlap or are unordered")
            }
            previousEnd = segment.endSeconds
        }
        if mode == .isolateVocals, denoise == .strong {
            throw ReferencePreparationError.invalidRecipe("strong denoise is not valid after vocal isolation")
        }
        return self
    }
}

public struct ReferenceCleanupMetrics: Codable, Sendable, Equatable {
    public var sourceDurationSeconds: Double; public var retainedDurationSeconds: Double
    public var sampleRate: Int; public var channels: Int
    public var loudnessBeforeLUFS: Double?; public var loudnessAfterLUFS: Double?
    public var truePeakDbFS: Double?; public var clippedSampleCount: Int
    public var sourceSHA256: String; public var referenceSHA256: String
    public init(sourceDurationSeconds: Double, retainedDurationSeconds: Double, sampleRate: Int,
                channels: Int, loudnessBeforeLUFS: Double?, loudnessAfterLUFS: Double?,
                truePeakDbFS: Double?, clippedSampleCount: Int, sourceSHA256: String,
                referenceSHA256: String) {
        self.sourceDurationSeconds = sourceDurationSeconds; self.retainedDurationSeconds = retainedDurationSeconds
        self.sampleRate = sampleRate; self.channels = channels; self.loudnessBeforeLUFS = loudnessBeforeLUFS
        self.loudnessAfterLUFS = loudnessAfterLUFS; self.truePeakDbFS = truePeakDbFS
        self.clippedSampleCount = clippedSampleCount; self.sourceSHA256 = sourceSHA256; self.referenceSHA256 = referenceSHA256
    }
}

public struct ReferenceVerification: Codable, Sendable, Equatable {
    public var transcriber: String?; public var transcriberVersion: String?
    /// nil = not verified (nothing in the native pipeline checks it); old reports stored a Bool here.
    public var speechOnly: Bool?; public var noOverlappingSpeaker: Bool?
    public var musicRemoved: Bool?; public var warnings: [String]
    public init(transcriber: String?, transcriberVersion: String?, speechOnly: Bool?,
                noOverlappingSpeaker: Bool?, musicRemoved: Bool?, warnings: [String]) {
        self.transcriber = transcriber; self.transcriberVersion = transcriberVersion
        self.speechOnly = speechOnly; self.noOverlappingSpeaker = noOverlappingSpeaker
        self.musicRemoved = musicRemoved; self.warnings = warnings
    }
}

public struct ReferenceCleanupReport: Codable, Sendable, Equatable {
    public var schema = ReferenceCleanupRecipe.schema
    public var sourceIdentity: String?
    public var recipe: ReferenceCleanupRecipe
    public var metrics: ReferenceCleanupMetrics
    public var verification: ReferenceVerification
    public init(sourceIdentity: String? = nil, recipe: ReferenceCleanupRecipe,
                metrics: ReferenceCleanupMetrics, verification: ReferenceVerification) {
        self.sourceIdentity = sourceIdentity; self.recipe = recipe
        self.metrics = metrics; self.verification = verification
    }
}

public enum ReferencePreparationError: Error, Sendable, Equatable {
    case invalidSegment(index: Int, reason: String)
    case invalidRecipe(String)
    case unreadableSource(String)
    case stereoSourceRequired
    case separationUnavailable(String)
    case verificationFailed([String])
    case cancelled
}

public struct ReferencePreparationRequest: Sendable {
    public var sourceURL: URL; public var sourceIdentity: String?
    public var transcript: String; public var language: String?
    public var recipe: ReferenceCleanupRecipe
    public init(sourceURL: URL, sourceIdentity: String? = nil, transcript: String,
                language: String? = nil, recipe: ReferenceCleanupRecipe) {
        self.sourceURL = sourceURL; self.sourceIdentity = sourceIdentity
        self.transcript = transcript; self.language = language; self.recipe = recipe
    }
}

public struct PreparedReference: Sendable {
    public var wav: Data; public var transcript: String
    public var metrics: ReferenceCleanupMetrics
    public var verification: ReferenceVerification
    public var provenance: JSONValue
    public init(wav: Data, transcript: String, metrics: ReferenceCleanupMetrics,
                verification: ReferenceVerification, provenance: JSONValue) {
        self.wav = wav; self.transcript = transcript; self.metrics = metrics
        self.verification = verification; self.provenance = provenance
    }
}
