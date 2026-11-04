import Foundation

/// A prepared voice: what the engine needs to speak in it. Made once per voice (tools/prep_voice.py
/// on the Mac) and cached; the engine caches the vocoder priming per distinct `refCodes`.
public struct QwenVoiceFiles: Sendable {
    /// Transcript of the reference clip.
    public var refText: String
    /// Speech-tokenizer codes of the reference clip: 16 codebooks x T frames.
    public var refCodes: [[Int]]
    /// x-vector speaker embedding (1024 floats).
    public var spkEmbedding: [Float]

    public init(refText: String, refCodes: [[Int]], spkEmbedding: [Float]) {
        self.refText = refText; self.refCodes = refCodes; self.spkEmbedding = spkEmbedding
    }

    /// Loads `voice.json` (`ref_text`), `ref_codes.npy` (int32, 1x16xT) and `spk_embed.npy` (float32) from `directory`.
    public init(directory: URL) throws {
        let d = directory.path
        guard let j = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("voice.json"))) as? [String: Any],
              let rt = j["ref_text"] as? String else { throw QwenANEError.invalid("bad voice.json in \(d)") }
        let rc = try NPY(path: d + "/ref_codes.npy")
        guard rc.shape.count == 3, rc.descr == "<i4" else { throw QwenANEError.invalid("ref_codes.npy must be int32 (1,16,T) in \(d)") }
        let G = rc.shape[1], T = rc.shape[2]
        let sp = try NPY(path: d + "/spk_embed.npy")
        guard sp.descr == "<f4" else { throw QwenANEError.invalid("spk_embed.npy must be float32 in \(d)") }
        guard G == 16, T > 0 else { throw QwenANEError.invalid("ref_codes.npy must be (1,16,T>0) in \(d)") }
        let codes: [[Int]] = withExtendedLifetime(rc) { (0..<G).map { g in (0..<T).map { Int(rc.i32[g * T + $0]) } } }
        let spk: [Float] = withExtendedLifetime(sp) { Array(UnsafeBufferPointer(start: sp.f32, count: sp.count)) }
        try Self.validate(refCodes: codes)
        self.init(refText: rt, refCodes: codes, spkEmbedding: spk)
    }

    /// Codebook size of every one of the 16 groups (talker codes and code-predictor sub-codes alike).
    public static let codebookSize = 2048

    /// Throws unless `refCodes` is 16 equal-length, non-empty rows of codes in `0..<codebookSize`.
    /// Out-of-range codes would index the memory-mapped embedding tables past their end.
    public static func validate(refCodes: [[Int]]) throws {
        guard refCodes.count == 16, let t = refCodes.first?.count, t > 0, refCodes.allSatisfy({ $0.count == t }) else {
            throw QwenANEError.invalid("refCodes must be 16 rows of equal, non-zero length")
        }
        for (g, row) in refCodes.enumerated() {
            if let bad = row.first(where: { $0 < 0 || $0 >= codebookSize }) {
                throw QwenANEError.invalid("refCodes[\(g)] has code \(bad) outside 0..<\(codebookSize)")
            }
        }
    }

    /// T x 16, frame-major (the vocoder's context).
    var referenceFrames: [Int64] {
        let T = refCodes[0].count
        var out = [Int64](repeating: 0, count: T * 16)
        for g in 0..<16 { for t in 0..<T { out[t * 16 + g] = Int64(refCodes[g][t]) } }
        return out
    }
}
