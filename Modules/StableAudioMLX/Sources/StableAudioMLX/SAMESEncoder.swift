import Foundation
import MLX

/// SAME-S encoder, ported from Stability AI's MLX runtime
/// (`optimized/mlx/models/defs/same_s_encoder.py`, MIT): audio patches
/// `[B, 512, T_lat·16]` → latents `[B, 256, T_lat]` in the DiT's softnorm space.
/// Always runs in FP32 (the bottleneck is sensitive to precision).
struct SAMESEncoder {
    static let inputChannels = 512
    static let latentDimension = 256
    static let stride = 16
    static let subChunkSize = 17
    static let effectiveChunk = 34
    static let shift = 17
    static let blockCount = 6
    /// The audio-patch length must be a multiple of the chunk size (32).
    static let padModulo = 32

    let weights: [String: MLXArray]

    func callAsFunction(_ patches: MLXArray) -> MLXArray {
        let batch = patches.dim(0)
        let audioLength = patches.dim(2)
        precondition(audioLength % Self.padModulo == 0, "patch length must be a multiple of \(Self.padModulo)")
        let dimension = SAMETransformer.dimension
        let transformer = SAMETransformer(weights: weights)

        var x = linear(patches.transposed(0, 2, 1), weight: weights["mapping.weight"]!, bias: weights["mapping.bias"]!)
        let latentLength = audioLength / Self.stride
        x = x.reshaped(batch * latentLength, Self.stride, dimension)
        let newTokens = broadcast(weights["new_tokens"]!, to: [batch * latentLength, 1, dimension])
        x = concatenated([x, newTokens], axis: 1)
        let internalLength = latentLength * Self.subChunkSize
        x = x.reshaped(batch, internalLength, dimension)

        let firstChunks = internalLength / Self.effectiveChunk
        x = x.reshaped(batch * firstChunks, Self.effectiveChunk, dimension)
        // Evaluate block by block: at 120 s a single block's qkv is ~340 MB in FP32.
        for index in 0 ..< Self.blockCount / 2 {
            x = transformer.block(index: index, x: x)
            eval(x)
        }
        x = x.reshaped(batch, internalLength, dimension)

        let left = x[0..., 0 ..< Self.shift, 0...]
        let right = x[0..., (internalLength - Self.shift) ..< internalLength, 0...]
        x = concatenated([left, x, right], axis: 1)
        let secondChunks = (internalLength + Self.effectiveChunk) / Self.effectiveChunk
        x = x.reshaped(batch * secondChunks, Self.effectiveChunk, dimension)
        for index in Self.blockCount / 2 ..< Self.blockCount {
            x = transformer.block(index: index, x: x)
            eval(x)
        }
        x = x.reshaped(batch, internalLength + Self.effectiveChunk, dimension)
        x = x[0..., Self.shift ..< (internalLength + Self.shift), 0...]

        // The output at each sub-chunk's new token is that position's latent.
        x = x.reshaped(batch * latentLength, Self.subChunkSize, dimension)
        x = x[0..., (Self.subChunkSize - 1)..., 0...]
        x = x.reshaped(batch, latentLength, dimension)

        x = linear(x, weight: weights["project_out.weight"]!, bias: weights["project_out.bias"]!)
        x = x.transposed(0, 2, 1)
        x = x * weights["scaling_factor"]! + weights["bias"]!
        return x / weights["running_std"]!
    }

    /// `rearrange("b c (l h) -> b (c h) l", h: 256)`: stereo audio `[B, 2, T]` → `[B, 512, T/256]`.
    static func patchAudio(_ audio: MLXArray, patchSize: Int = 256) -> MLXArray {
        let batch = audio.dim(0)
        let channels = audio.dim(1)
        let samples = audio.dim(2)
        precondition(samples % patchSize == 0)
        let length = samples / patchSize
        return audio.reshaped(batch, channels, length, patchSize)
            .transposed(0, 1, 3, 2)
            .reshaped(batch, channels * patchSize, length)
    }
}
