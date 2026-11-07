import Foundation
import MLX

/// The SAME-S transformer block shared by the decoder and the encoder: differential
/// attention, DyT norms, GLU feed-forward. Moved out of `SAMESDecoder` unchanged.
struct SAMETransformer {
    static let dimension = 768
    static let headCount = 12
    static let headDimension = 64
    static let ropeDimensions = 32

    let weights: [String: MLXArray]

    func block(index: Int, x: MLXArray) -> MLXArray {
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
