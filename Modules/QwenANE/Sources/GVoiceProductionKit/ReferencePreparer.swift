import CryptoKit
import Foundation
import GVoiceKit

public struct ReferencePreparer: Sendable {
    private let separator: (any VoiceStemSeparating)?
    public init(separator: (any VoiceStemSeparating)?) { self.separator = separator }

    public func prepare(_ request: ReferencePreparationRequest) async throws -> PreparedReference {
        try Task.checkCancellation()
        let source = try NativeAudioProcessor.decode(request.sourceURL)
        let recipe = try request.recipe.validated(sourceDuration: source.durationSeconds)
        let transcript = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw ReferencePreparationError.verificationFailed(["reference transcript is empty"]) }
        if recipe.mode == .isolateVocals, separator == nil {
            throw ReferencePreparationError.separationUnavailable("no native vocal separator configured")
        }

        var pieces: [ReferenceAudioBuffer] = []
        for segment in recipe.segments {
            try Task.checkCancellation()
            var piece = try NativeAudioProcessor.slice(source, segment: segment)
            if recipe.mode == .isolateVocals {
                piece = NativeAudioProcessor.stereo(piece)   // Demucs separates stereo; a mono source is upmixed
                guard piece.channelCount == 2 else { throw ReferencePreparationError.stereoSourceRequired }
                piece = try await separator!.isolateVocals(piece)
            }
            piece = NativeAudioProcessor.mono(piece)
            piece = NativeAudioProcessor.bandLimit(piece, highpassHz: recipe.highpassHz, lowpassHz: recipe.lowpassHz)
            piece = NativeAudioProcessor.denoise(piece, strength: recipe.denoise)
            piece = NativeAudioProcessor.fade(piece, inSeconds: recipe.fadeInSeconds, outSeconds: recipe.fadeOutSeconds)
            pieces.append(piece)
        }
        let assembled = NativeAudioProcessor.join(pieces, silenceSeconds: recipe.joinSilenceSeconds)
        let packAudio = try NativeAudioProcessor.resample(NativeAudioProcessor.mono(assembled), to: recipe.packSampleRate)
        let before = Double(Loudness.lufs(packAudio.channels[0], sampleRate: packAudio.sampleRate))
        let rawWAV = try NativeAudioProcessor.pcm16WAV(packAudio)
        let wav = ReferenceStandard.applied(to: rawWAV)
        let final = try decodeTemporary(wav)
        let finalSamples = final.channels[0]
        let after = Double(Loudness.lufs(finalSamples, sampleRate: final.sampleRate))
        let peak = finalSamples.map { abs($0) }.max() ?? 0
        let sourceData = try Data(contentsOf: request.sourceURL, options: .mappedIfSafe)
        let metrics = ReferenceCleanupMetrics(
            sourceDurationSeconds: source.durationSeconds,
            retainedDurationSeconds: final.durationSeconds,
            sampleRate: final.sampleRate, channels: final.channelCount,
            loudnessBeforeLUFS: before.isFinite ? before : nil,
            loudnessAfterLUFS: after.isFinite ? after : nil,
            truePeakDbFS: peak > 0 ? 20 * log10(Double(peak)) : nil,
            clippedSampleCount: finalSamples.filter { abs($0) >= 1 }.count,
            sourceSHA256: Self.sha256(sourceData), referenceSHA256: Self.sha256(wav))
        let verification = ReferenceVerification(
            transcriber: nil, transcriberVersion: nil, speechOnly: nil,
            noOverlappingSpeaker: nil,
            musicRemoved: recipe.mode == .isolateVocals ? true : nil,
            warnings: ["not verified: speech-only and single-speaker (no check runs on the cleaned audio)",
                       "not verified: transcript was supplied by the caller and not checked against the audio"])
        let report = ReferenceCleanupReport(sourceIdentity: request.sourceIdentity,
                                            recipe: recipe, metrics: metrics,
                                            verification: verification)
        let provenance = try ReferenceCleanupProvenance.merging(report, into: nil)
        return .init(wav: wav, transcript: transcript, metrics: metrics,
                     verification: verification, provenance: provenance)
    }

    private func decodeTemporary(_ data: Data) throws -> ReferenceAudioBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gvoice-final-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        return try NativeAudioProcessor.decode(url)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
