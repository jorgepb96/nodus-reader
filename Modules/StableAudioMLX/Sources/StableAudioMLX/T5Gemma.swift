import Foundation
import MLX
import MLXNN

struct T5GemmaConfig {
    let hiddenSize = 768
    let layerCount = 12
    let attentionHeadCount = 12
    let headDimension = 64
    let intermediateSize = 2048
    let ropeTheta: Float = 10_000
    let rmsNormEpsilon: Float = 1e-6
    let attentionLogitSoftcap: Float = 50
    let queryPreAttentionScalar: Float = 64
    let normalizer: Float = sqrt(768)
}

struct T5PromptEncoding {
    let embeddings: MLXArray
    let mask: MLXArray
    let tokenCount: Int
}

struct T5GemmaEncoder {
    let config = T5GemmaConfig()
    let weights: [String: MLXArray]

    init(weights: [String: MLXArray]) throws {
        self.weights = weights
        try Self.validate(weights)
    }

    func encodeTokenIDs(_ tokenIDs: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        let batch = tokenIDs.dim(0)
        let sequenceLength = tokenIDs.dim(1)

        var x = weights["embed_tokens.weight"]![tokenIDs].asType(.float16)
        x = x * MLXArray(config.normalizer, dtype: .float16)

        let (cos, sin) = ropeCosSin(sequenceLength: sequenceLength)
        let addMask = attentionMask.map(makeAttentionAddMask)

        for layerIndex in 0 ..< config.layerCount {
            x = runLayer(index: layerIndex, x: x, cos: cos, sin: sin, addMask: addMask, batch: batch, sequenceLength: sequenceLength)
        }

        return rmsNorm(x, weight: weights["norm.weight"]!)
    }

    private func runLayer(
        index: Int,
        x: MLXArray,
        cos: MLXArray,
        sin: MLXArray,
        addMask: MLXArray?,
        batch: Int,
        sequenceLength: Int
    ) -> MLXArray {
        let prefix = "layers.\(index)"
        var y = rmsNorm(x, weight: weights["\(prefix).pre_self_attn_layernorm.weight"]!)
        y = selfAttention(prefix: "\(prefix).self_attn", x: y, cos: cos, sin: sin, addMask: addMask, batch: batch, sequenceLength: sequenceLength)
        y = rmsNorm(y, weight: weights["\(prefix).post_self_attn_layernorm.weight"]!)
        var out = x + y

        y = rmsNorm(out, weight: weights["\(prefix).pre_feedforward_layernorm.weight"]!)
        y = mlp(prefix: "\(prefix).mlp", x: y)
        y = rmsNorm(y, weight: weights["\(prefix).post_feedforward_layernorm.weight"]!)
        out = out + y
        return out
    }

    private func selfAttention(
        prefix: String,
        x: MLXArray,
        cos: MLXArray,
        sin: MLXArray,
        addMask: MLXArray?,
        batch: Int,
        sequenceLength: Int
    ) -> MLXArray {
        let heads = config.attentionHeadCount
        let headDimension = config.headDimension

        var query = linear(x, weight: weights["\(prefix).q_proj.weight"]!)
            .reshaped(batch, sequenceLength, heads, headDimension)
            .transposed(0, 2, 1, 3)
        var key = linear(x, weight: weights["\(prefix).k_proj.weight"]!)
            .reshaped(batch, sequenceLength, heads, headDimension)
            .transposed(0, 2, 1, 3)
        let value = linear(x, weight: weights["\(prefix).v_proj.weight"]!)
            .reshaped(batch, sequenceLength, heads, headDimension)
            .transposed(0, 2, 1, 3)

        (query, key) = applyRoPE(query: query, key: key, cos: cos, sin: sin)

        var scores = matmul(query, key.transposed(0, 1, 3, 2)) * pow(config.queryPreAttentionScalar, -0.5)
        scores = tanh(scores / config.attentionLogitSoftcap) * config.attentionLogitSoftcap
        if let addMask {
            scores = scores + addMask
        }

        let probabilities = softmax(scores.asType(.float32), axis: -1).asType(value.dtype)
        let attended = matmul(probabilities, value)
            .transposed(0, 2, 1, 3)
            .reshaped(batch, sequenceLength, heads * headDimension)

        return linear(attended, weight: weights["\(prefix).o_proj.weight"]!)
    }

    private func mlp(prefix: String, x: MLXArray) -> MLXArray {
        let gate = geluApproximate(linear(x, weight: weights["\(prefix).gate_proj.weight"]!))
        let up = linear(x, weight: weights["\(prefix).up_proj.weight"]!)
        return linear(gate * up, weight: weights["\(prefix).down_proj.weight"]!)
    }

    private func rmsNorm(_ x: MLXArray, weight: MLXArray) -> MLXArray {
        let dtype = x.dtype
        let x32 = x.asType(.float32)
        let variance = (x32 * x32).mean(axis: -1, keepDims: true)
        let normalized = x32 * rsqrt(variance + config.rmsNormEpsilon)
        return (normalized * (weight.asType(.float32) + 1.0)).asType(dtype)
    }

    private func linear(_ x: MLXArray, weight: MLXArray) -> MLXArray {
        matmul(x, weight.T)
    }

    private func ropeCosSin(sequenceLength: Int) -> (MLXArray, MLXArray) {
        let invFreq: MLXArray
        if let saved = weights["rope_inv_freq"] {
            invFreq = saved.asType(.float32)
        } else {
            let arange = MLX.arange(0, config.headDimension, step: 2, dtype: .float32)
            invFreq = 1.0 / pow(MLXArray(config.ropeTheta), arange / Float(config.headDimension))
        }

        let positions = MLX.arange(sequenceLength, dtype: .float32)
        let frequencies = outer(positions, invFreq)
        let embedding = concatenated([frequencies, frequencies], axis: -1)
        return (cos(embedding), sin(embedding))
    }

    private func applyRoPE(query: MLXArray, key: MLXArray, cos: MLXArray, sin: MLXArray) -> (MLXArray, MLXArray) {
        let cos = cos.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
        let sin = sin.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
        let rotatedQuery = (query * cos.asType(query.dtype)) + (rotateHalf(query) * sin.asType(query.dtype))
        let rotatedKey = (key * cos.asType(key.dtype)) + (rotateHalf(key) * sin.asType(key.dtype))
        return (rotatedQuery, rotatedKey)
    }

    private func rotateHalf(_ x: MLXArray) -> MLXArray {
        let halves = x.split(axis: -1)
        return concatenated([-halves.1, halves.0], axis: -1)
    }

    private func makeAttentionAddMask(_ attentionMask: MLXArray) -> MLXArray {
        let keep = attentionMask.asType(.float32)
        return ((1.0 - keep) * -1e9)
            .expandedDimensions(axis: 1)
            .expandedDimensions(axis: 1)
            .asType(.float16)
    }

    private static func validate(_ weights: [String: MLXArray]) throws {
        let requiredKeys = [
            "embed_tokens.weight",
            "norm.weight",
            "layers.0.self_attn.q_proj.weight",
            "layers.0.mlp.gate_proj.weight",
            "layers.11.self_attn.o_proj.weight",
            "layers.11.mlp.down_proj.weight",
        ]
        for key in requiredKeys where weights[key] == nil {
            throw T5GemmaError.missingWeight(key)
        }
    }
}

enum T5GemmaError: LocalizedError {
    case missingWeight(String)

    var errorDescription: String? {
        switch self {
        case .missingWeight(let key):
            return "Missing T5Gemma weight: \(key)"
        }
    }
}
