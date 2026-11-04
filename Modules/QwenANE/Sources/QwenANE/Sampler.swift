import Foundation

/// numpy's `np.random.default_rng(seed)`: PCG64 (XSL-RR 128/64) seeded through `SeedSequence`.
/// Reproduced bit for bit so a Swift render with seed N draws the same random stream as the
/// Python reference (tools/qonnx.py `Sampler`), which is what makes frame-level parity testable.
struct NumpyPCG64 {
    private var hi: UInt64 = 0, lo: UInt64 = 0          // 128-bit state
    private var incHi: UInt64 = 0, incLo: UInt64 = 0    // 128-bit stream increment (odd)
    private static let multHi: UInt64 = 0x2360_ED05_1FC6_5DA4, multLo: UInt64 = 0x4385_DF64_9FCC_F645

    init(seed: UInt64) {
        // SeedSequence(seed): the integer becomes little-endian 32-bit words.
        var entropy: [UInt32] = [UInt32(truncatingIfNeeded: seed)]
        if seed >> 32 != 0 { entropy.append(UInt32(truncatingIfNeeded: seed >> 32)) }
        let words = Self.generateState(pool: Self.mixEntropy(entropy), count: 8)
        func u64(_ i: Int) -> UInt64 { UInt64(words[2 * i]) | UInt64(words[2 * i + 1]) << 32 }
        // pcg64_set_seed: initstate = s0:s1, initseq = s2:s3 (hi:lo)
        let initHi = u64(0), initLo = u64(1), seqHi = u64(2), seqLo = u64(3)
        incHi = seqHi << 1 | seqLo >> 63
        incLo = seqLo << 1 | 1
        step()
        let (l, carry) = lo.addingReportingOverflow(initLo)
        lo = l
        hi = hi &+ initHi &+ (carry ? 1 : 0)
        step()
    }

    private mutating func step() {
        // state = state * MULT + inc (mod 2^128)
        let p = lo.multipliedFullWidth(by: Self.multLo)
        var newHi = p.high &+ lo &* Self.multHi &+ hi &* Self.multLo
        let (l, carry) = p.low.addingReportingOverflow(incLo)
        newHi = newHi &+ incHi &+ (carry ? 1 : 0)
        lo = l; hi = newHi
    }

    mutating func next() -> UInt64 {
        step()
        let x = hi ^ lo
        let rot = hi >> 58
        return (x >> rot) | (x << ((64 &- rot) & 63))
    }

    /// `Generator.random()`: 53 random bits in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }

    // MARK: SeedSequence (numpy/random/bit_generator.pyx)

    private static func hashmix(_ v: UInt32, _ c: inout UInt32) -> UInt32 {
        var value = v ^ c
        c = c &* 0x931e_8875
        value = value &* c
        return value ^ (value >> 16)
    }

    private static func mix(_ x: UInt32, _ y: UInt32) -> UInt32 {
        let r = 0xca01_f9dd &* x &- 0x4973_f715 &* y
        return r ^ (r >> 16)
    }

    private static func mixEntropy(_ entropy: [UInt32]) -> [UInt32] {
        var c: UInt32 = 0x43b0_d7e5
        var pool = [UInt32](repeating: 0, count: 4)
        for i in 0..<4 { pool[i] = hashmix(i < entropy.count ? entropy[i] : 0, &c) }
        for s in 0..<4 { for d in 0..<4 where s != d { pool[d] = mix(pool[d], hashmix(pool[s], &c)) } }
        if entropy.count > 4 {
            for s in 4..<entropy.count { for d in 0..<4 { pool[d] = mix(pool[d], hashmix(entropy[s], &c)) } }
        }
        return pool
    }

    private static func generateState(pool: [UInt32], count: Int) -> [UInt32] {
        var c: UInt32 = 0x8b51_f9dd
        return (0..<count).map { i in
            var v = pool[i % 4] ^ c
            c = c &* 0x58f3_8ded
            v = v &* c
            return v ^ (v >> 16)
        }
    }
}

/// First-codebook sampler (qonnx.Sampler): codec-control tokens suppressed (EOS kept),
/// repetition penalty over all generated first-codebook tokens, temperature softmax, then top-k.
/// temperature <= 0 is greedy. `topK` 0 is off (every token keeps its probability).
/// The draw is `Generator.choice(V, p=...)`: a cdf search with one `random()` per token.
struct Sampler {
    var temperature: Double = 0.9
    var repetition: Float = 1.05
    /// Keep only the `topK` most likely tokens (ties at the k-th logit included), like transformers'
    /// `TopKLogitsWarper`, which upstream Qwen3-TTS runs with k = 50. 0 = off.
    var topK: Int = 0
    let vocab: Int, eos: Int
    var rng: NumpyPCG64

    init(temperature: Double = 0.9, repetition: Float = 1.05, topK: Int = 0, vocab: Int = 3072, eos: Int = 2150, seed: UInt64 = 0) {
        self.temperature = temperature; self.repetition = repetition; self.topK = topK; self.vocab = vocab; self.eos = eos
        rng = NumpyPCG64(seed: seed)
    }

    mutating func sample(_ logits: UnsafePointer<Float>, history: [Int]) -> Int {
        var l = Array(UnsafeBufferPointer(start: logits, count: vocab))
        for i in (vocab - 1024)..<vocab where i != eos { l[i] = -Float.infinity }
        if !history.isEmpty && repetition != 1 {
            for u in Set(history) { l[u] = l[u] < 0 ? l[u] * repetition : l[u] / repetition }
        }
        if temperature <= 0 {
            var bi = 0; var bv = l[0]
            for i in 1..<vocab where l[i] > bv { bv = l[i]; bi = i }
            return bi
        }
        if topK > 0 && topK < vocab {
            // transformers TopKLogitsWarper: drop every logit below the k-th largest (ties survive)
            let kth = l.sorted(by: >)[topK - 1]
            for i in 0..<vocab where l[i] < kth { l[i] = -Float.infinity }
        }
        var mx = -Float.infinity
        for v in l where v > mx { mx = v }
        var p = [Double](repeating: 0, count: vocab)
        var sum = 0.0
        for i in 0..<vocab {
            let z = (Double(l[i]) - Double(mx)) / temperature
            let e = z == -Double.infinity ? 0 : exp(z)
            p[i] = e; sum += e
        }
        var acc = 0.0
        for i in 0..<vocab { acc += p[i] / sum; p[i] = acc }      // cdf of the normalised p
        let last = p[vocab - 1]
        let r = rng.uniform()
        for i in 0..<vocab where p[i] / last > r { return i }
        return vocab - 1
    }
}

/// The fixed cap (`QwenReadRules.frameCap` without a voice pace).
func effectiveMaxTokens(_ nTextTokens: Int, maxTokens: Int = 4096) -> Int {
    min(maxTokens, QwenReadRules.frameCap(textTokens: nTextTokens, voiceFramesPerToken: nil))
}
