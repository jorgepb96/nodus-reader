// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import LinnetTTS

actor LinnetSpeech {
    private let model: LinnetModel
    private let female: LinnetTTS.Voice
    private let male: LinnetTTS.Voice
    init(directory root: URL = LinnetModels.directory) throws {
        model = try LinnetModel(weightsPath: root.appendingPathComponent("linnet-en-35m.fp16.safetensors").path,
                                tokenizerPath: root.appendingPathComponent("tokenizer.model").path)
        female = try model.loadVoice(path: root.appendingPathComponent("voices/linnet-en-f1.npy").path)
        male = try model.loadVoice(path: root.appendingPathComponent("voices/linnet-en-m1.npy").path)
    }
    static func load() async throws -> LinnetSpeech {
        try await Task.detached(priority: .userInitiated) { try LinnetSpeech() }.value
    }
    func synthesize(_ text: String, voice: String) throws -> NarrationSynthesis {
        let normalized = PronunciationTransformer.prepare(text, rules: LinnetText.rules(text)).spoken
        var samples: [Float] = []
        // Short parts leave substantial margin below the 24-second session cap.
        let words = normalized.split(whereSeparator: \.isWhitespace)
        var parts: [String] = []; var part = ""
        for word in words {
            if part.count + word.count > 120, !part.isEmpty { parts.append(part); part = "" }
            part += (part.isEmpty ? "" : " ") + word
        }
        if !part.isEmpty { parts.append(part) }
        for part in parts {
            try Task.checkCancellation()
            let session = try model.session(voice: voice == "linnet-en-m1" ? male : female, params: SynthParams())
            try session.prime(text: part)
            var chunk: [Float] = []
            while let next = try session.step() {
                try Task.checkCancellation()
                chunk += next
            }
            guard session.chunksEmitted < 301, SpeechQuality.accepts(samples: chunk, text: part, recognized: nil) else {
                throw NeuralNarrationError.invalidAudio
            }
            NarrationPCM.fadeEdges(&chunk, sampleRate: 24_000)
            NarrationPCM.append(chunk, to: &samples, sampleRate: 24_000)
        }
        return NarrationSynthesis(samples: samples, sampleRate: 24_000)
    }
}

enum LinnetText {
    static func rules(_ text: String) -> [PronunciationRule] {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.numberStyle = .spellOut
        let pattern = #"(?:[$£€]\s*)?\d+(?:[,.]\d+)*(?:%|:\d{2})?"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var rules = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let written = ns.substring(with: match.range)
            var value = written; var suffix = ""
            for (symbol, unit) in [("$", " dollars"), ("£", " pounds"), ("€", " euros"), ("%", " percent")] {
                if value.contains(symbol) { value = value.replacingOccurrences(of: symbol, with: ""); suffix = unit }
            }
            let spoken = value.replacingOccurrences(of: ",", with: "").split(separator: ":").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces)).flatMap { formatter.string(from: NSNumber(value: $0)) }
            }.joined(separator: " ")
            return spoken.isEmpty ? nil : PronunciationRule(written: written, spoken: spoken + suffix)
        }
        let dateRegex = try! NSRegularExpression(pattern: #"\b(?:\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})\b"#)
        for match in dateRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let written = ns.substring(with: match.range)
            let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.timeZone = TimeZone(secondsFromGMT: 0)
            input.dateFormat = written.contains("-") ? "yyyy-MM-dd" : "M/d/yyyy"
            if let date = input.date(from: written) {
                let output = DateFormatter(); output.locale = Locale(identifier: "en_US"); output.timeZone = input.timeZone; output.dateFormat = "MMMM d yyyy"
                let value = output.string(from: date)
                let expanded = PronunciationTransformer.prepare(value, rules: LinnetText.rules(value)).spoken
                rules.insert(PronunciationRule(written: written, spoken: expanded), at: 0)
            }
        }
        return rules
    }
}

extension ModelManager {
    static var linnetModel: Model {
        Model(id: LinnetModels.id, engine: .linnet, name: "LinnetTTS",
              detail: String(localized: "Lightweight English narration with two built-in voices."),
              language: String(localized: "English"), sizeText: String(localized: "About 83 MB download"),
              license: "Linnet Weights License 1.0", source: URL(string: "https://github.com/VoxRT/LinnetTTS")!,
              voices: [Voice(id: "linnet:linnet-en-f1", name: "Linnet Female", language: "en-US", engine: .linnet, gender: .female),
                       Voice(id: "linnet:linnet-en-m1", name: "Linnet Male", language: "en-US", engine: .linnet, gender: .male)],
              availability: .available)
    }
}
