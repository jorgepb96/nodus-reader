import Foundation
import MLX

struct DiTSmallMusic {
    static let ioChannels = 256
    static let embedDimension = 1024
    static let layerCount = 20
    static let headCount = 16
    static let headDimension = 64
    static let ropeDimensions = 32
    static let localAddConditionDimension = 257
    static let memoryTokenCount = 64
    static let feedForwardInner = 4096
    static let timestepFeatureDimension = 256

    let weights: [String: MLXArray]
    let latentLength: Int

    func callAsFunction(_ x: MLXArray, timestep: MLXArray, crossAttention: MLXArray, globalCondition: MLXArray) -> MLXArray {
        let batch = x.dim(0)

        var context = linear(crossAttention, weight: weights["to_cond_embed.0.weight"]!)
        context = silu(context)
        context = linear(context, weight: weights["to_cond_embed.2.weight"]!)

        var global = linear(globalCondition, weight: weights["to_global_embed.0.weight"]!)
        global = silu(global)
        let globalPre = linear(global, weight: weights["to_global_embed.2.weight"]!)

        var timeFeatures = timestepFeatures(timestep)
        timeFeatures = linear(timeFeatures, weight: weights["to_timestep_embed.0.weight"]!, bias: weights["to_timestep_embed.0.bias"]!)
        timeFeatures = silu(timeFeatures)
        let timeEmbed = linear(timeFeatures, weight: weights["to_timestep_embed.2.weight"]!, bias: weights["to_timestep_embed.2.bias"]!)
        let globalEmbed = globalPre + timeEmbed

        var h = x.transposed(0, 2, 1)
        h = conv1d(h, weights["preprocess_conv.weight"]!) + h

        h = continuousTransformer(h, context: context, globalEmbed: globalEmbed, batch: batch)
        let out = conv1d(h, weights["postprocess_conv.weight"]!) + h
        return out.transposed(0, 2, 1)
    }

    private func continuousTransformer(_ x: MLXArray, context: MLXArray, globalEmbed: MLXArray, batch: Int) -> MLXArray {
        var h = linear(x, weight: weights["transformer.project_in.weight"]!)
        let memory = weights["transformer.memory_tokens"]!.asType(h.dtype).expandedDimensions(axis: 0)
        let memoryBatched = broadcast(memory, to: [batch, Self.memoryTokenCount, Self.embedDimension])
        h = concatenated([memoryBatched, h], axis: 1)

        var global = linear(globalEmbed, weight: weights["transformer.global_cond_embedder.0.weight"]!, bias: weights["transformer.global_cond_embedder.0.bias"]!)
        global = silu(global)
        global = linear(global, weight: weights["transformer.global_cond_embedder.2.weight"]!, bias: weights["transformer.global_cond_embedder.2.bias"]!)

        let localZeros = MLXArray.zeros([batch, latentLength, Self.localAddConditionDimension], dtype: h.dtype)
        for index in 0 ..< Self.layerCount {
            let prefix = "transformer.layers.\(index)"
            var local = linear(localZeros, weight: weights["\(prefix).to_local_embed.seq.0.weight"]!, bias: weights["\(prefix).to_local_embed.seq.0.bias"]!)
            local = silu(local)
            local = linear(local, weight: weights["\(prefix).to_local_embed.seq.2.weight"]!, bias: weights["\(prefix).to_local_embed.seq.2.bias"]!)
            let localPadding = MLXArray.zeros([batch, Self.memoryTokenCount, Self.embedDimension], dtype: local.dtype)
            let localPadded = concatenated([localPadding, local], axis: 1)
            h = transformerBlock(prefix: prefix, x: h, context: context, globalCondition: global, localEmbedded: localPadded)
            eval(h)
        }

        h = h[0..., Self.memoryTokenCount..., 0...]
        return linear(h, weight: weights["transformer.project_out.weight"]!)
    }

    private func transformerBlock(prefix: String, x: MLXArray, context: MLXArray, globalCondition: MLXArray, localEmbedded: MLXArray) -> MLXArray {
        let scaleShiftGate = (weights["\(prefix).to_scale_shift_gate"]! + globalCondition).expandedDimensions(axis: 1)
        let split = scaleShiftGate.split(parts: 6, axis: -1)
        let scaleSelf = split[0]
        let shiftSelf = split[1]
        let gateSelf = split[2]
        let scaleFF = split[3]
        let shiftFF = split[4]
        let gateFF = split[5]

        var h = rmsNorm(x, weight: weights["\(prefix).pre_norm.weight"]!, eps: 1e-5)
        h = h * (1.0 + scaleSelf) + shiftSelf
        h = selfAttention(prefix: "\(prefix).self_attn", x: h)
        h = h * sigmoid(1.0 - gateSelf)
        var out = x + h

        out = out + crossAttention(prefix: "\(prefix).cross_attn", x: rmsNorm(out, weight: weights["\(prefix).cross_attend_norm.weight"]!, eps: 1e-5), context: context)
        out = out + localEmbedded

        h = rmsNorm(out, weight: weights["\(prefix).ff_norm.weight"]!, eps: 1e-5)
        h = h * (1.0 + scaleFF) + shiftFF
        h = feedForward(prefix: "\(prefix).ff.ff", x: h)
        h = h * sigmoid(1.0 - gateFF)
        return out + h
    }

    private func selfAttention(prefix: String, x: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)
        let qkv = linear(x, weight: weights["\(prefix).to_qkv.weight"]!)
        let split = qkv.split(parts: 3, axis: -1)
        var q = toHeads(split[0], batch: batch, length: length)
        var k = toHeads(split[1], batch: batch, length: length)
        let v = toHeads(split[2], batch: batch, length: length)
        q = rmsNorm(q, weight: weights["\(prefix).q_norm.weight"]!, eps: 1e-6)
        k = rmsNorm(k, weight: weights["\(prefix).k_norm.weight"]!, eps: 1e-6)
        q = RoPE(q, dimensions: Self.ropeDimensions, traditional: false, base: 10_000, scale: 1, offset: 0)
        k = RoPE(k, dimensions: Self.ropeDimensions, traditional: false, base: 10_000, scale: 1, offset: 0)
        var out = scaledDotProductAttention(queries: q, keys: k, values: v, scale: pow(Float(Self.headDimension), -0.5), mask: nil)
        out = out.transposed(0, 2, 1, 3).reshaped(batch, length, Self.embedDimension)
        return linear(out, weight: weights["\(prefix).to_out.weight"]!)
    }

    private func crossAttention(prefix: String, x: MLXArray, context: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let xLength = x.dim(1)
        let contextLength = context.dim(1)
        var q = linear(x, weight: weights["\(prefix).to_q.weight"]!)
        let kv = linear(context, weight: weights["\(prefix).to_kv.weight"]!)
        let split = kv.split(parts: 2, axis: -1)
        var k = split[0]
        let v = split[1]
        q = toHeads(q, batch: batch, length: xLength)
        k = toHeads(k, batch: batch, length: contextLength)
        let vh = toHeads(v, batch: batch, length: contextLength)
        q = rmsNorm(q, weight: weights["\(prefix).q_norm.weight"]!, eps: 1e-6)
        k = rmsNorm(k, weight: weights["\(prefix).k_norm.weight"]!, eps: 1e-6)
        var out = scaledDotProductAttention(queries: q, keys: k, values: vh, scale: pow(Float(Self.headDimension), -0.5), mask: nil)
        out = out.transposed(0, 2, 1, 3).reshaped(batch, xLength, Self.embedDimension)
        return linear(out, weight: weights["\(prefix).to_out.weight"]!)
    }

    private func feedForward(prefix: String, x: MLXArray) -> MLXArray {
        let projected = linear(x, weight: weights["\(prefix).0.proj.weight"]!, bias: weights["\(prefix).0.proj.bias"]!)
        let split = projected.split(parts: 2, axis: -1)
        let activated = split[0] * silu(split[1])
        return linear(activated, weight: weights["\(prefix).2.weight"]!, bias: weights["\(prefix).2.bias"]!)
    }

    private func toHeads(_ x: MLXArray, batch: Int, length: Int) -> MLXArray {
        x.reshaped(batch, length, Self.headCount, Self.headDimension).transposed(0, 2, 1, 3)
    }

    private func timestepFeatures(_ timestep: MLXArray) -> MLXArray {
        let half = Self.timestepFeatureDimension / 2
        let ramp = MLX.linspace(Float(0), Float(1), count: half)
        let frequencies = exp(ramp * (log(Float(10_000)) - log(Float(0.5))) + log(Float(0.5))) * (2.0 * Float.pi)
        let args = timestep.asType(.float32).expandedDimensions(axis: 1) * frequencies
        return concatenated([cos(args), sin(args)], axis: -1)
    }
}
