import Foundation
import MLX

struct SA3Conditioning {
    let weights: [String: MLXArray]

    func makeConditioning(promptEncoding: T5PromptEncoding, seconds: Float) -> (crossAttention: MLXArray, globalCondition: MLXArray) {
        let paddedPrompt = applyPromptPadding(
            embeddings: promptEncoding.embeddings,
            mask: promptEncoding.mask,
            paddingEmbedding: weights["cond.padding_embedding"]!
        )
        let secondsEmbedding = secondsTotalEmbedding(seconds)
        let crossAttention = concatenated([paddedPrompt, secondsEmbedding.asType(paddedPrompt.dtype)], axis: 1)
        let globalCondition = secondsEmbedding[0..., 0, 0...].asType(.float16)
        eval(crossAttention, globalCondition)
        return (crossAttention, globalCondition)
    }

    private func applyPromptPadding(embeddings: MLXArray, mask: MLXArray, paddingEmbedding: MLXArray) -> MLXArray {
        let m = mask.asType(embeddings.dtype).expandedDimensions(axis: -1)
        let pad = paddingEmbedding.asType(embeddings.dtype).reshaped(1, 1, -1)
        return embeddings * m + pad * (1.0 - m)
    }

    private func secondsTotalEmbedding(_ seconds: Float) -> MLXArray {
        let minValue: Float = 0
        let maxValue: Float = 384
        let fourierDimension = 256
        let half = fourierDimension / 2

        var value = MLXArray([seconds], [1]).asType(.float32)
        value = clip(value, min: minValue, max: maxValue)
        let normalized = ((value - minValue) / (maxValue - minValue)).reshaped(-1, 1)

        let ramp = MLX.arange(half, dtype: .float32) / Float(max(half - 1, 1))
        let minFrequency: Float = 0.5
        let maxFrequency: Float = 10_000
        let frequencies = exp(ramp * (log(maxFrequency) - log(minFrequency)) + log(minFrequency))
        let args = normalized * frequencies * (2.0 * Float.pi)
        let features = concatenated([cos(args), sin(args)], axis: -1)

        let out = matmul(features, weights["cond.seconds_total_weight"]!.T) + weights["cond.seconds_total_bias"]!
        return out.expandedDimensions(axis: 1)
    }
}
