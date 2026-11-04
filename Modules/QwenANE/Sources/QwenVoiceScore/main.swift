// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import QwenANE

// Uses the same frozen speaker encoder for every generated sample. This is an
// objective consistency check, not a human judgement of speaker likeness.
let args = CommandLine.arguments
setbuf(stdout, nil)
guard args.count >= 6 else {
    fputs("Usage: qwen-voice-score MODELS PREPARED_REFERENCE CACHE_DIRECTORY OUTPUT.json REPORT.json [REPORT.json ...]\n", stderr)
    exit(2)
}
func cosine(_ a: [Float], _ b: [Float]) throws -> Double {
    guard a.count == b.count, !a.isEmpty, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else {
        throw QwenANEError.invalid("invalid speaker vectors")
    }
    var dot = 0.0, aa = 0.0, bb = 0.0
    for (x, y) in zip(a, b) { dot += Double(x) * Double(y); aa += Double(x) * Double(x); bb += Double(y) * Double(y) }
    guard aa > 0, bb > 0 else { throw QwenANEError.invalid("zero speaker vector") }
    return dot / sqrt(aa * bb)
}
do {
    let models = URL(fileURLWithPath: args[1], isDirectory: true)
    let reference = try QwenVoiceFiles(directory: URL(fileURLWithPath: args[2], isDirectory: true))
    let cache = URL(fileURLWithPath: args[3], isDirectory: true)
    var scores: [[String: Any]] = []
    var vectors: [String: [Float]] = [:]
    for reportPath in args.dropFirst(5) {
        guard let report = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: reportPath))) as? [String: Any],
              let rows = report["runs"] as? [[String: Any]] else { throw QwenANEError.invalid("invalid probe report") }
        for row in rows where row["repetition"] as? Int == 1 {
            guard let id = row["id"] as? String, let path = row["output"] as? String, let text = row["text"] as? String else {
                throw QwenANEError.invalid("invalid probe row")
            }
            let output = URL(fileURLWithPath: path)
            let voice = try QwenVoicePrep.prepared(referenceWAV: Data(contentsOf: output), transcript: text,
                cacheDirectory: cache.appendingPathComponent(output.deletingPathExtension().lastPathComponent), modelsDirectory: models)
            let value = try cosine(reference.spkEmbedding, voice.spkEmbedding)
            var score: [String: Any] = ["report": reportPath, "id": id, "cosineToReference": value, "output": path]
            if let baseline = vectors[id] { score["cosineToFirstVariant"] = try cosine(baseline, voice.spkEmbedding) }
            else { vectors[id] = voice.spkEmbedding }
            scores.append(score)
            print("\(reportPath) \(id): reference cosine \(value)")
        }
    }
    let result: [String: Any] = ["note": "Same Qwen speaker encoder for all variants; first repetition only. Cosine is not a listening judgement or an independently validated likeness metric.", "scores": scores]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: args[4]), options: .atomic)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
