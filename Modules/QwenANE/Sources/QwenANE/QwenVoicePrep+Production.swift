import Foundation
import GVoiceProductionKit

extension QwenVoicePrep {
    /// Bridges GVoiceProductionKit's output (mono 24 kHz PCM16 WAV already through ReferenceStandard,
    /// transcript of the final waveform) into a cached Qwen voice.
    public static func prepared(from reference: PreparedReference, cacheDirectory: URL,
                                modelsDirectory: URL) throws -> QwenVoiceFiles {
        try prepared(referenceWAV: reference.wav, transcript: reference.transcript,
                     cacheDirectory: cacheDirectory, modelsDirectory: modelsDirectory)
    }
}
