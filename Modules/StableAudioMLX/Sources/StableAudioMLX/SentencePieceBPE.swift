import Foundation

/// A minimal SentencePiece BPE encoder for T5Gemma's `tokenizer.model`, so the app
/// needs no tokenizer binary.
///
/// It follows `bpe_model.cc`: the text is split into characters, user-defined symbols
/// are matched first (longest match) and never merged, then the adjacent pair whose
/// concatenation is in the vocabulary with the highest score is merged repeatedly
/// (ties go to the leftmost pair). Pieces without an id fall back to `<0xXX>` byte
/// tokens. Spaces become `▁`.
///
/// Only the configuration of the pinned model is supported (BPE, identity normaliser,
/// no dummy prefix, no extra-whitespace removal, byte fallback); `SA3Installer` checks
/// its SHA-256 and the test command `sa3-bench tokenize` compares it with Google's
/// library on a large corpus.
public struct SentencePieceBPE: Sendable {
    public enum TokenizerError: Error {
        case malformed
    }

    private enum PieceType: Int {
        case normal = 1, unknown = 2, control = 3, userDefined = 4, unused = 5, byte = 6
    }

    // Pieces are keyed by their UTF-8 bytes: Swift strings compare by canonical
    // equivalence and group grapheme clusters, SentencePiece compares bytes and splits
    // code points.
    /// Piece → id for pieces merges may produce (normal, user-defined).
    private let mergeable: [[UInt8]: (id: Int, score: Float)]
    /// Piece → id for every piece, as `PieceToId` resolves the final symbols.
    private let ids: [[UInt8]: Int]
    /// User-defined symbols grouped by their first byte, longest first.
    private let userDefined: [UInt8: [[UInt8]]]
    private let byteIDs: [Int]
    public let unknownID: Int

    public init(modelURL: URL) throws {
        try self.init(data: Data(contentsOf: modelURL))
    }

    public init(data: Data) throws {
        var reader = ProtoReader(data)
        var mergeable: [[UInt8]: (Int, Float)] = [:]
        var ids: [[UInt8]: Int] = [:]
        var user: [UInt8: [[UInt8]]] = [:]
        var byteIDs = Array(repeating: -1, count: 256)
        var unknown = 0
        var index = 0
        while let (field, wire) = try reader.nextKey() {
            guard field == 1, wire == 2 else {
                try reader.skip(wire)
                continue
            }
            var piece = ProtoReader(try reader.lengthDelimited())
            var text: [UInt8] = []
            var score: Float = 0
            var type = PieceType.normal
            while let (f, w) = try piece.nextKey() {
                switch (f, w) {
                case (1, 2): text = Array(try piece.lengthDelimited())
                case (2, 5): score = try piece.float()
                case (3, 0): type = PieceType(rawValue: Int(try piece.varint())) ?? .normal
                default: try piece.skip(w)
                }
            }
            if ids[text] == nil { ids[text] = index }
            switch type {
            case .normal, .userDefined:
                mergeable[text] = (index, score)
                if type == .userDefined, let first = text.first { user[first, default: []].append(text) }
            case .byte:
                // "<0x41>"
                let name = String(decoding: text, as: UTF8.self)
                if name.count == 6, let value = UInt8(name.dropFirst(3).dropLast(), radix: 16) { byteIDs[Int(value)] = index }
            case .unknown:
                unknown = index
            case .control, .unused:
                break
            }
            index += 1
        }
        guard index > 0, !byteIDs.contains(-1) else { throw TokenizerError.malformed }
        self.mergeable = mergeable
        self.ids = ids
        self.userDefined = user.mapValues { $0.sorted { $0.count > $1.count } }
        self.byteIDs = byteIDs
        self.unknownID = unknown
    }

    public func encode(_ text: String) -> [Int] {
        // Spaces become U+2581; everything else is kept (identity normaliser).
        var bytes: [UInt8] = []
        for byte in text.utf8 {
            if byte == 0x20 { bytes.append(contentsOf: [0xE2, 0x96, 0x81]) } else { bytes.append(byte) }
        }
        // Initial symbols: user-defined matches (frozen) or single code points.
        var symbols: [(piece: [UInt8], frozen: Bool)] = []
        var position = 0
        while position < bytes.count {
            let first = bytes[position]
            if let candidates = userDefined[first],
               let match = candidates.first(where: { candidate in
                   position + candidate.count <= bytes.count && bytes[position ..< (position + candidate.count)].elementsEqual(candidate)
               }) {
                symbols.append((match, true))
                position += match.count
            } else {
                let length = first < 0x80 ? 1 : first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1
                let end = min(position + length, bytes.count)
                symbols.append((Array(bytes[position ..< end]), false))
                position = end
            }
        }
        // Merge the best-scoring pair until none is in the vocabulary.
        while symbols.count > 1 {
            var best: (index: Int, score: Float)?
            for i in 0 ..< (symbols.count - 1) where !symbols[i].frozen && !symbols[i + 1].frozen {
                guard let entry = mergeable[symbols[i].piece + symbols[i + 1].piece] else { continue }
                if best == nil || entry.score > best!.score { best = (i, entry.score) }
            }
            guard let best else { break }
            symbols[best.index].piece += symbols[best.index + 1].piece
            symbols.remove(at: best.index + 1)
        }
        var result: [Int] = []
        for symbol in symbols {
            if let id = ids[symbol.piece], id != unknownID {
                result.append(id)
            } else {
                result.append(contentsOf: symbol.piece.map { byteIDs[Int($0)] })
            }
        }
        return result
    }
}

/// Just enough protobuf to read `ModelProto.pieces`.
private struct ProtoReader {
    let data: Data
    var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func nextKey() throws -> (Int, Int)? {
        guard offset < data.endIndex else { return nil }
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex, shift < 64 else { throw SentencePieceBPE.TokenizerError.malformed }
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    mutating func lengthDelimited() throws -> Data {
        let length = Int(try varint())
        guard offset + length <= data.endIndex else { throw SentencePieceBPE.TokenizerError.malformed }
        defer { offset += length }
        return data.subdata(in: offset ..< (offset + length))
    }

    mutating func float() throws -> Float {
        guard offset + 4 <= data.endIndex else { throw SentencePieceBPE.TokenizerError.malformed }
        var bits: UInt32 = 0
        for i in 0 ..< 4 { bits |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return Float(bitPattern: bits)
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: offset += 8
        case 2: _ = try lengthDelimited()
        case 5: offset += 4
        default: throw SentencePieceBPE.TokenizerError.malformed
        }
        guard offset <= data.endIndex else { throw SentencePieceBPE.TokenizerError.malformed }
    }
}
