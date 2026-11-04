import Foundation

/// The talker's key/value state for the leading prompt rows of one voice (see `VoicePrompt`), copied out of
/// the Core ML `MLState` buffers after the voice's first prefill and copied back before a later line's
/// prefill, which then starts at row `rows` instead of row 0.
///
/// Why this is exact: prefill runs in fixed chunks of 64 rows and a row's key/value depends only on the
/// rows before it. `rows` is always a whole number of chunks, so the chunks that produced these rows
/// ran with exactly the inputs a fresh prefill gives them. `matches` additionally compares the prompt's own
/// embeddings against the ones the snapshot was made from, bit for bit, so a stale or foreign entry can
/// never be used.
final class KVPrefix {
    /// Prompt rows covered (a multiple of the prefill chunk).
    let rows: Int
    /// The embeddings (rows x 1024) the snapshot was computed from.
    let embeds: [Float]
    /// One compact fp16 block per state array ("k0", "v0", "k1", ... in layer order), heads x rows x headDim.
    let buffers: [Data]

    init(rows: Int, embeds: [Float], buffers: [Data]) {
        self.rows = rows; self.embeds = embeds; self.buffers = buffers
    }

    var byteCount: Int { buffers.reduce(0) { $0 + $1.count } + embeds.count * 4 }

    /// True when the first `rows` rows of `prompt` are bit-identical to the rows this snapshot was made from.
    func matches(_ prompt: [Float]) -> Bool {
        guard prompt.count >= embeds.count else { return false }
        return embeds.withUnsafeBytes { a in
            prompt.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 }
        }
    }
}
