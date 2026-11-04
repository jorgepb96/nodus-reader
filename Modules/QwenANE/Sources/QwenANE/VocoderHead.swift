import Foundation
import Accelerate

/// Streaming vocoder head: codes -> RVQ dequantize -> pre_conv -> 8-layer causal transformer
/// (KV cache) -> hidden (T x 1024). A Swift port of tools/voc_torch.Head with Accelerate;
/// weights are .npy files (fp16 as shipped, fp32 also accepted; memory mapped). fp16 matrices are widened into a
/// scratch buffer per matmul, so the resident cost stays at the mapped (clean) pages.
/// Exact in streaming: the conv keeps its last 2 input frames, attention keeps all past K/V.
final class VocoderHead {
    static let nLayers = 8, nHeads = 16, headDim = 64, dModel = 512, dInner = 1024, dFF = 1024, dHidden = 1024

    /// A weight matrix as stored: fp32 used in place, fp16 widened on use.
    private struct Mat {
        let npy: NPY
        var count: Int { npy.count }
    }
    private struct Layer {
        let inLN, postLN: UnsafePointer<Float>
        let q, k, v, o, gate, up, down: Mat
        let sa, sm: UnsafePointer<Float>
    }

    private var keep: [NPY] = []
    private let embed: [Mat]                             // 16 x (2048 x 256)
    private let wFirst, wRest: Mat                       // (512 x 256) each
    private let preW: Mat, preB: UnsafePointer<Float>    // (1024 x 1536), (1024)
    private let inW: Mat, inB: UnsafePointer<Float>      // (512 x 1024), (512)
    private let normW: UnsafePointer<Float>
    private let outW: Mat, outB: UnsafePointer<Float>    // (1024 x 512), (1024)
    private var owned: [UnsafeMutablePointer<Float>] = []   // widened copies of the small vectors
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 1024 * 1536)   // widest matrix (pre_conv)
    private let layers: [Layer]
    private var invFreq = [Float](repeating: 0, count: 32)

    // streaming state
    private var preBuf = [Float](repeating: 0, count: 2 * 512)       // last 2 quantized frames
    private var kCache: [[Float]] = [], vCache: [[Float]] = []        // per layer, (S x 1024) frame-major
    private var off = 0

    init(dir: String) throws {
        var keepers: [NPY] = []
        var ownedLocal: [UnsafeMutablePointer<Float>] = []
        func mat(_ n: String) throws -> Mat {
            let a = try NPY(path: dir + "/" + n + ".npy"); keepers.append(a); return Mat(npy: a)
        }
        /// Small vectors (biases, norms, scales): used directly when fp32, widened once when fp16.
        func load(_ n: String) throws -> UnsafePointer<Float> {
            let a = try NPY(path: dir + "/" + n + ".npy"); keepers.append(a)
            if !a.isHalf { return a.f32 }
            let p = UnsafeMutablePointer<Float>.allocate(capacity: a.count)
            widenHalf(a.f16, p, a.count); ownedLocal.append(p); return UnsafePointer(p)
        }
        var em: [Mat] = []
        em.append(try mat("quantizer.rvq_first.vq.layers.0._codebook.embed"))
        for i in 0..<15 { em.append(try mat("quantizer.rvq_rest.vq.layers.\(i)._codebook.embed")) }
        embed = em
        wFirst = try mat("quantizer.rvq_first.output_proj.weight")
        wRest = try mat("quantizer.rvq_rest.output_proj.weight")
        preW = try mat("pre_conv.conv.weight"); preB = try load("pre_conv.conv.bias")
        inW = try mat("pre_transformer.input_proj.weight"); inB = try load("pre_transformer.input_proj.bias")
        normW = try load("pre_transformer.norm.weight")
        outW = try mat("pre_transformer.output_proj.weight"); outB = try load("pre_transformer.output_proj.bias")
        var ls: [Layer] = []
        for i in 0..<Self.nLayers {
            let p = "pre_transformer.layers.\(i)."
            ls.append(Layer(inLN: try load(p + "input_layernorm.weight"), postLN: try load(p + "post_attention_layernorm.weight"),
                            q: try mat(p + "self_attn.q_proj.weight"), k: try mat(p + "self_attn.k_proj.weight"),
                            v: try mat(p + "self_attn.v_proj.weight"), o: try mat(p + "self_attn.o_proj.weight"),
                            gate: try mat(p + "mlp.gate_proj.weight"), up: try mat(p + "mlp.up_proj.weight"),
                            down: try mat(p + "mlp.down_proj.weight"),
                            sa: try load(p + "self_attn_layer_scale.scale"), sm: try load(p + "mlp_layer_scale.scale")))
        }
        layers = ls
        keep = keepers
        owned = ownedLocal
        for i in 0..<32 { invFreq[i] = 1.0 / powf(10000.0, Float(2 * i) / 64.0) }
        reset()
    }

    /// Streaming state, so a primed state (a voice's reference codes) can be saved once and reused per line.
    struct State { var preBuf: [Float]; var k: [[Float]]; var v: [[Float]]; var off: Int }
    var state: State {
        get { State(preBuf: preBuf, k: kCache, v: vCache, off: off) }
        set { preBuf = newValue.preBuf; kCache = newValue.k; vCache = newValue.v; off = newValue.off }
    }

    func reset() {
        preBuf = [Float](repeating: 0, count: 2 * 512)
        kCache = [[Float]](repeating: [], count: Self.nLayers)
        vCache = [[Float]](repeating: [], count: Self.nLayers)
        off = 0
    }

    deinit {
        scratch.deallocate()
        for p in owned { p.deallocate() }
    }

    // y (M x N) = x (M x K) * W^T, W is (N x K) row-major; beta=1 accumulates into y
    @inline(__always)
    private func gemm(_ x: UnsafePointer<Float>, _ wm: Mat, _ y: UnsafeMutablePointer<Float>,
                      m: Int, n: Int, k: Int, beta: Float = 0, ldx: Int? = nil) {
        let w: UnsafePointer<Float>
        if wm.npy.isHalf { widenHalf(wm.npy.f16, scratch, n * k); w = UnsafePointer(scratch) } else { w = wm.npy.f32 }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(m), Int32(n), Int32(k), 1, x, Int32(ldx ?? k), w, Int32(k), beta, y, Int32(n))
    }

    private func rms(_ x: UnsafePointer<Float>, _ w: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, rows: Int, dim: Int) {
        for r in 0..<rows {
            let a = x + r * dim, o = out + r * dim
            var ss: Float = 0
            vDSP_svesq(a, 1, &ss, vDSP_Length(dim))
            let s = 1.0 / sqrtf(ss / Float(dim) + 1e-5)
            for i in 0..<dim { o[i] = w[i] * (a[i] * s) }
        }
    }

    /// codes: T frames x 16 (frame-major). Returns hidden (T x 1024) frame-major.
    func process(codes: UnsafePointer<Int64>, frames T: Int) -> [Float] {
        let D = Self.dModel, DI = Self.dInner
        // ---- quantizer: e1 / er (T x 256) -> q (T x 512)
        var e1 = [Float](repeating: 0, count: T * 256), er = [Float](repeating: 0, count: T * 256)
        for t in 0..<T {
            let c = codes + t * 16
            embed[0].npy.copyFloats(from: Int(c[0]) * 256, count: 256, to: &e1[t * 256])
            var acc = [Float](repeating: 0, count: 256)
            var row = [Float](repeating: 0, count: 256)
            for i in 0..<15 {
                embed[i + 1].npy.copyFloats(from: Int(c[i + 1]) * 256, count: 256, to: &row)
                vDSP_vadd(acc, 1, row, 1, &acc, 1, 256)
            }
            for j in 0..<256 { er[t * 256 + j] = acc[j] }
        }
        // qq: (T+2) x 512, first 2 rows = conv history
        var qq = [Float](repeating: 0, count: (T + 2) * D)
        for j in 0..<(2 * D) { qq[j] = preBuf[j] }
        qq.withUnsafeMutableBufferPointer { qp in
            let qnew = qp.baseAddress! + 2 * D
            gemm(e1, wFirst, qnew, m: T, n: D, k: 256)
            gemm(er, wRest, qnew, m: T, n: D, k: 256, beta: 1)
        }
        for j in 0..<(2 * D) { preBuf[j] = qq[T * D + j] }          // last 2 frames of (history + new)
        // ---- pre_conv as im2col matmul: X[t][c*3+k] = qq[t+k][c]
        var X = [Float](repeating: 0, count: T * D * 3)
        for t in 0..<T { for kk in 0..<3 {
            let src = (t + kk) * D
            for c in 0..<D { X[t * D * 3 + c * 3 + kk] = qq[src + c] }
        } }
        var y = [Float](repeating: 0, count: T * DI)
        for t in 0..<T { memcpy(&y[t * DI], preB, DI * 4) }
        gemm(X, preW, &y, m: T, n: DI, k: D * 3, beta: 1)
        // ---- transformer
        var h = [Float](repeating: 0, count: T * D)
        for t in 0..<T { memcpy(&h[t * D], inB, D * 4) }
        gemm(y, inW, &h, m: T, n: D, k: DI, beta: 1)

        var cosT = [Float](repeating: 0, count: T * 32), sinT = [Float](repeating: 0, count: T * 32)
        for t in 0..<T { for i in 0..<32 {
            let fr = Float(off + t) * invFreq[i]
            cosT[t * 32 + i] = cosf(fr); sinT[t * 32 + i] = sinf(fr)
        } }
        var a = [Float](repeating: 0, count: T * D)
        var q = [Float](repeating: 0, count: T * DI), k = [Float](repeating: 0, count: T * DI), v = [Float](repeating: 0, count: T * DI)
        var att = [Float](repeating: 0, count: T * DI)
        var o = [Float](repeating: 0, count: T * D)
        var g = [Float](repeating: 0, count: T * Self.dFF), u = [Float](repeating: 0, count: T * Self.dFF)
        let nh = Self.nHeads, hd = Self.headDim
        for li in 0..<Self.nLayers {
            let L = layers[li]
            rms(h, L.inLN, &a, rows: T, dim: D)
            gemm(a, L.q, &q, m: T, n: DI, k: D); gemm(a, L.k, &k, m: T, n: DI, k: D); gemm(a, L.v, &v, m: T, n: DI, k: D)
            for t in 0..<T { for hh in 0..<nh {
                let base = t * DI + hh * hd
                for i in 0..<32 {
                    let c = cosT[t * 32 + i], s = sinT[t * 32 + i]
                    let q0 = q[base + i], q1 = q[base + i + 32]
                    q[base + i] = q0 * c - q1 * s; q[base + i + 32] = q1 * c + q0 * s
                    let k0 = k[base + i], k1 = k[base + i + 32]
                    k[base + i] = k0 * c - k1 * s; k[base + i + 32] = k1 * c + k0 * s
                }
            } }
            kCache[li].append(contentsOf: k); vCache[li].append(contentsOf: v)
            let total = off + T
            let scores = UnsafeMutablePointer<Float>.allocate(capacity: total)
            defer { scores.deallocate() }
            kCache[li].withUnsafeBufferPointer { kp in vCache[li].withUnsafeBufferPointer { vp in
                q.withUnsafeBufferPointer { qp in att.withUnsafeMutableBufferPointer { ap in
                    for t in 0..<T {
                        let S = off + t + 1                                  // causal: keys 0...off+t
                        for hh in 0..<nh {
                            // scores = K_h (S x 64, row stride 1024) * q_h / 8
                            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(S), Int32(hd), 0.125, kp.baseAddress! + hh * hd, Int32(DI),
                                        qp.baseAddress! + t * DI + hh * hd, 1, 0, scores, 1)
                            var mx: Float = -Float.infinity
                            vDSP_maxv(scores, 1, &mx, vDSP_Length(S))
                            var sum: Float = 0
                            for j in 0..<S { let e = expf(scores[j] - mx); scores[j] = e; sum += e }
                            let inv = 1 / sum
                            for j in 0..<S { scores[j] *= inv }
                            // out_h = V_h^T (64 x S) * p
                            cblas_sgemv(CblasRowMajor, CblasTrans, Int32(S), Int32(hd), 1, vp.baseAddress! + hh * hd, Int32(DI),
                                        scores, 1, 0, ap.baseAddress! + t * DI + hh * hd, 1)
                        }
                    }
                } }
            } }
            gemm(att, L.o, &o, m: T, n: D, k: DI)
            for t in 0..<T { for j in 0..<D { h[t * D + j] += L.sa[j] * o[t * D + j] } }
            rms(h, L.postLN, &a, rows: T, dim: D)
            gemm(a, L.gate, &g, m: T, n: Self.dFF, k: D); gemm(a, L.up, &u, m: T, n: Self.dFF, k: D)
            for i in 0..<(T * Self.dFF) { let x = g[i]; g[i] = (x / (1 + expf(-x))) * u[i] }
            gemm(g, L.down, &o, m: T, n: D, k: Self.dFF)
            for t in 0..<T { for j in 0..<D { h[t * D + j] += L.sm[j] * o[t * D + j] } }
        }
        off += T
        rms(h, normW, &a, rows: T, dim: D)
        var out = [Float](repeating: 0, count: T * Self.dHidden)
        for t in 0..<T { memcpy(&out[t * Self.dHidden], outB, Self.dHidden * 4) }
        gemm(a, outW, &out, m: T, n: Self.dHidden, k: D, beta: 1)
        return out
    }
}
