import Foundation

/// Qwen2 byte-level BPE, ported from the HF tokenizers.json the Python pipeline
/// uses (qonnx.Host.encode): isolated regex split -> ByteLevel -> BPE merges.
/// Special tokens (<|im_start|> etc.) are matched literally first.
final class QwenTokenizer {
    private var vocab: [String: Int] = [:]
    private var ranks: [String: Int] = [:]
    private var specials: [String: Int] = [:]
    private let splitRegex: NSRegularExpression
    private let specialRegex: NSRegularExpression?
    private var byteToUni: [String] = Array(repeating: "", count: 256)
    private var cache: [String: [Int]] = [:]

    init(tokenizerJSON path: String) throws {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let root = obj as? [String: Any], let model = root["model"] as? [String: Any],
              let v = model["vocab"] as? [String: Int], let merges = model["merges"] as? [Any] else {
            throw QwenANEError.invalid("tokenizer.json: unexpected layout")
        }
        vocab = v
        ranks.reserveCapacity(merges.count)
        for (i, m) in merges.enumerated() {
            if let s = m as? String { ranks[s] = i }
            else if let a = m as? [String], a.count == 2 { ranks[a[0] + " " + a[1]] = i }
        }
        if let added = root["added_tokens"] as? [[String: Any]] {
            for a in added { if let c = a["content"] as? String, let id = a["id"] as? Int { specials[c] = id } }
        }
        // pattern from pre_tokenizer.pretokenizers[0].pattern.Regex
        var pattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        if let pre = root["pre_tokenizer"] as? [String: Any], let list = pre["pretokenizers"] as? [[String: Any]],
           let pat = list.first?["pattern"] as? [String: Any], let rx = pat["Regex"] as? String { pattern = rx }
        splitRegex = try NSRegularExpression(pattern: pattern)
        let alt = specials.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        specialRegex = alt.isEmpty ? nil : try NSRegularExpression(pattern: alt)
        // GPT-2 bytes_to_unicode
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        for (b, c) in zip(bs, cs) { byteToUni[b] = String(UnicodeScalar(UInt32(c))!) }
    }

    func encode(_ text: String) -> [Int] {
        var out: [Int] = []
        let ns = text as NSString
        var last = 0
        let matches = specialRegex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches {
            if m.range.location > last { out += encodePlain(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            out.append(specials[ns.substring(with: m.range)]!)
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += encodePlain(ns.substring(from: last)) }
        return out
    }

    private func encodePlain(_ s: String) -> [Int] {
        var out: [Int] = []
        let ns = s as NSString
        var last = 0
        func word(_ w: String) {
            if w.isEmpty { return }
            if let c = cache[w] { out += c; return }
            let ids = bpe(w)
            cache[w] = ids
            out += ids
        }
        for m in splitRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { word(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            word(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        if last < ns.length { word(ns.substring(from: last)) }
        return out
    }

    private func bpe(_ w: String) -> [Int] {
        var parts: [String] = w.utf8.map { byteToUni[Int($0)] }
        while parts.count > 1 {
            var best = Int.max, bi = -1
            for i in 0..<(parts.count - 1) {
                if let r = ranks[parts[i] + " " + parts[i + 1]], r < best { best = r; bi = i }
            }
            if bi < 0 { break }
            let a = parts[bi], b = parts[bi + 1]
            var next: [String] = []
            var i = 0
            while i < parts.count {
                if i < parts.count - 1, parts[i] == a, parts[i + 1] == b { next.append(a + b); i += 2 }
                else { next.append(parts[i]); i += 1 }
            }
            parts = next
        }
        return parts.compactMap { vocab[$0] }
    }
}
