import Foundation
import MLX

struct SAMESDecoder {
    static let latentDimension = 256
    static let dimension = 768
    static let headCount = 12
    static let headDimension = 64
    static let ropeDimensions = 32
    static let blockCount = 6
    static let feedForwardInner = 2304
    static let outputChannels = 512
    static let stride = 16
    static let subChunkSize = 17
    static let chunkSizeLatent = 32
    static let effectiveChunk = 34
    static let shift = 17

    let weights: [String: MLXArray]

    func decodeChunked(latents: MLXArray, chunkSize: Int = 8, overlap: Int = 2) -> MLXArray {
        let latentLength = latents.dim(-1)
        let kernel = chunkSize + 2 * overlap
        if latentLength <= kernel {
            return callAsFunction(latents)
        }

        var pieces: [MLXArray] = []
        let firstOutput = callAsFunction(latents[0..., 0..., 0 ..< kernel])
        let validFirst = chunkSize + overlap
        pieces.append(firstOutput[0..., 0..., 0 ..< (validFirst * Self.stride)])
        var index = validFirst

        while index + chunkSize + overlap <= latentLength {
            let out = callAsFunction(latents[0..., 0..., (index - overlap) ..< (index + chunkSize + overlap)])
            pieces.append(out[0..., 0..., (overlap * Self.stride) ..< ((overlap + chunkSize) * Self.stride)])
            index += chunkSize
        }

        let remaining = latentLength - index
        if remaining > 0 {
            let out = callAsFunction(latents[0..., 0..., (latentLength - kernel) ..< latentLength])
            let start = out.dim(-1) - remaining * Self.stride
            pieces.append(out[0..., 0..., start...])
        }

        return concatenated(pieces, axis: -1)
    }

    func callAsFunction(_ latents: MLXArray) -> MLXArray {
        let batch = latents.dim(0)
        let latentLength = latents.dim(2)

        var x = latents.asType(.float32) * weights["running_std"]!
        x = linear(x.transposed(0, 2, 1), weight: weights["project_in.weight"]!, bias: weights["project_in.bias"]!)

        let expanded = x.expandedDimensions(axis: 2)
        let newTokens = broadcast(weights["new_tokens"]!.expandedDimensions(axis: 0), to: [batch, latentLength, Self.stride, Self.dimension])
        x = concatenated([expanded, newTokens], axis: 2)
        x = x.reshaped(batch, latentLength * Self.subChunkSize, Self.dimension)

        let internalLength = latentLength * Self.subChunkSize
        let firstChunks = internalLength / Self.effectiveChunk
        x = x.reshaped(batch * firstChunks, Self.effectiveChunk, Self.dimension)
        for index in 0 ..< 3 {
            x = block(index: index, x: x)
        }
        x = x.reshaped(batch, internalLength, Self.dimension)

        let left = x[0..., 0 ..< Self.shift, 0...]
        let right = x[0..., (internalLength - Self.shift) ..< internalLength, 0...]
        x = concatenated([left, x, right], axis: 1)
        let secondChunks = (internalLength + Self.effectiveChunk) / Self.effectiveChunk
        x = x.reshaped(batch * secondChunks, Self.effectiveChunk, Self.dimension)
        for index in 3 ..< Self.blockCount {
            x = block(index: index, x: x)
        }
        x = x.reshaped(batch, internalLength + Self.effectiveChunk, Self.dimension)
        x = x[0..., Self.shift ..< (internalLength + Self.shift), 0...]

        x = x.reshaped(batch * latentLength, Self.subChunkSize, Self.dimension)
        x = x[0..., 1..., 0...]
        x = x.reshaped(batch, latentLength * Self.stride, Self.dimension)

        var out = conv1d(x, weights["mapping.weight"]!.transposed(0, 2, 1), padding: 1)
        out = out + weights["mapping.bias"]!
        return out.transposed(0, 2, 1)
    }

    private func block(index: Int, x: MLXArray) -> MLXArray {
        let prefix = "blocks.\(index)"
        var out = x + attention(prefix: "\(prefix).attn", x: dyt(prefix: "\(prefix).pre_norm", x: x))
        out = out + feedForward(prefix: "\(prefix).ff", x: dyt(prefix: "\(prefix).ff_norm", x: out))
        return out
    }

    private func attention(prefix: String, x: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)
        let qkv = linear(x, weight: weights["\(prefix).to_qkv.weight"]!)
        let split = qkv.split(parts: 5, axis: -1)
        var q = toHeads(split[0], batch: batch, length: length)
        var k = toHeads(split[1], batch: batch, length: length)
        let v = toHeads(split[2], batch: batch, length: length)
        var qDiff = toHeads(split[3], batch: batch, length: length)
        var kDiff = toHeads(split[4], batch: batch, length: length)

        q = dyt(prefix: "\(prefix).q_norm", x: q)
        k = dyt(prefix: "\(prefix).k_norm", x: k)
        qDiff = dyt(prefix: "\(prefix).q_norm", x: qDiff)
        kDiff = dyt(prefix: "\(prefix).k_norm", x: kDiff)

        q = RoPE(q, dimensions: Self.ropeDimensions, traditional: false, base: 10_000, scale: 1, offset: 0)
        k = RoPE(k, dimensions: Self.ropeDimensions, traditional: false, base: 10_000, scale: 1, offset: 0)
        qDiff = RoPE(qDiff, dimensions: Self.ropeDimensions, traditional: false, base: 10_000, scale: 1, offset: 0)
        kDiff = RoPE(kDiff, dimensions: Self.ropeDimensions, traditional: false, base: 10_000, scale: 1, offset: 0)

        let main = scaledDotProductAttention(queries: q, keys: k, values: v, scale: pow(Float(Self.headDimension), -0.5), mask: nil)
        let diff = scaledDotProductAttention(queries: qDiff, keys: kDiff, values: v, scale: pow(Float(Self.headDimension), -0.5), mask: nil)
        let out = (main - diff).transposed(0, 2, 1, 3).reshaped(batch, length, Self.dimension)
        return linear(out, weight: weights["\(prefix).to_out.weight"]!)
    }

    private func feedForward(prefix: String, x: MLXArray) -> MLXArray {
        let projected = linear(x, weight: weights["\(prefix).glu_proj.weight"]!, bias: weights["\(prefix).glu_proj.bias"]!)
        let split = projected.split(parts: 2, axis: -1)
        let activated = split[0] * silu(split[1])
        return linear(activated, weight: weights["\(prefix).proj_out.weight"]!, bias: weights["\(prefix).proj_out.bias"]!)
    }

    private func dyt(prefix: String, x: MLXArray) -> MLXArray {
        weights["\(prefix).gamma"]! * tanh(weights["\(prefix).alpha"]! * x) + weights["\(prefix).beta"]!
    }

    private func toHeads(_ x: MLXArray, batch: Int, length: Int) -> MLXArray {
        x.reshaped(batch, length, Self.headCount, Self.headDimension).transposed(0, 2, 1, 3)
    }
}

