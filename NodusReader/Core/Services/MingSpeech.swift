// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Ming 3.0 0.5B (inclusionAI, MIT), the 8-bit MLX checkpoint, run with
/// MLXAudio on the Mac's GPU. A model instance serves one request at a time,
/// so it lives in an actor.
actor MingSpeech {
    static let sampleRate: Double = 44_100

    private let model: MingDenseModel

    private init(model: MingDenseModel) {
        self.model = model
    }

    /// Loads a verified checkpoint folder: weights, tokenizer and the CAM++
    /// speaker encoder (`campplus.safetensors`) used to clone a voice.
    static func load(directory: URL) async throws -> MingSpeech {
        MingSpeech(model: try await MingDenseModel.fromModelDirectory(directory))
    }

    /// One sentence as mono Float PCM at 44.1 kHz, in a built-in `voice` or,
    /// with a `reference`, in the voice of that clip.
    func synthesize(_ text: String, voice: String?, reference: MingReference?,
                    language: String) async throws -> [Float] {
        let referenceAudio = reference.map { MLXArray($0.samples).materialized() }
        let audio = try await model.generate(
            text: text,
            voice: reference == nil ? voice : nil,
            refAudio: referenceAudio,
            refText: reference?.transcript,
            language: language,
            generationParameters: GenerateParameters(temperature: 0)
        )
        return audio.asArray(Float.self)
    }
}
#endif

/// A cloned voice's reference clip (mono, 44.1 kHz) and its exact transcript.
struct MingReference: Sendable {
    let samples: [Float]
    let transcript: String
}
