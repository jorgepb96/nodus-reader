import Foundation

// Backend-neutral seam: the Demucs adapter lives in GVoiceDemucsKit so this
// target stays free of MLX and can ship in an iOS app. With no separator
// injected, isolate-vocals mode throws ReferencePreparationError.separationUnavailable.
public protocol VoiceStemSeparating: Sendable {
    var backendIdentifier: String { get }
    var modelIdentifier: String { get }
    func isolateVocals(_ input: ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer
}
