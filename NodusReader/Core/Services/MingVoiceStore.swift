// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Speech

/// Voices cloned for Ming from a short reference clip: recorded on this Mac or
/// added from an audio file, with the exact words spoken in it. Each voice is a
/// folder with `reference.wav` (mono, 44.1 kHz, 16-bit) and `voice.json`, under
/// Application Support. Like models, voices stay on this device and never sync.
enum MingVoiceStore {
    struct ClonedVoice: Codable, Identifiable, Hashable, Sendable {
        enum Origin: String, Codable, Sendable {
            case recorded
            case imported
            case bundled
        }

        let id: String
        var name: String
        /// BCP 47 tag of the language spoken in the clip ("es-ES", "en-US").
        var language: String
        var transcript: String
        var durationS: Double
        var createdAt: Date
        var origin: Origin

        var voiceID: String { MingVoiceStore.voiceIDPrefix + id }
        var isBundled: Bool { origin == .bundled }
    }

    /// The clip prepared for a reference: mono 44.1 kHz, trimmed and normalized.
    struct PreparedClip: Sendable {
        let samples: [Float]
        var durationS: Double { Double(samples.count) / sampleRate }
    }

    enum StoreError: LocalizedError, Equatable {
        case unreadableAudio
        case tooShort
        case tooLong
        case transcriptTooShort(Int)
        case missingConsent

        var errorDescription: String? {
            switch self {
            case .unreadableAudio:
                String(localized: "This file could not be read as audio.")
            case .tooShort:
                String(localized: "The clip needs at least 3 seconds of speech.")
            case .tooLong:
                String(localized: "The clip can last 30 seconds at most. Use one of 6 to 15 seconds.")
            case .transcriptTooShort(let minimum):
                String(localized: "Write the exact words spoken in the clip (at least \(minimum) characters for its length).")
            case .missingConsent:
                String(localized: "Confirm that this is your voice or that you have its owner's permission.")
            }
        }
    }

    static let voiceIDPrefix = "ming-clone:"
    static let sampleRate: Double = 44_100
    static let minimumSeconds: Double = 3
    static let recommendedSeconds: ClosedRange<Double> = 6...15
    static let maximumSeconds: Double = 30

    /// Languages Ming speaks, as the tag stored with a cloned voice.
    static let languages = ["es-ES", "en-US", "en-GB", "fr-FR", "de-DE", "zh-CN", "ja-JP", "ko-KR"]

    nonisolated static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Voices/Ming", isDirectory: true)

    /// Ming conditions the cloned voice on the transcript, so a file name or a
    /// single word gives stuttering audio: about three characters per second
    /// of speech, never fewer than twelve.
    static func minimumTranscriptCharacters(forDuration durationS: Double) -> Int {
        let seconds = durationS.isFinite && durationS > 0 ? durationS : minimumSeconds
        return max(12, Int((seconds * 3).rounded(.up)))
    }

    // MARK: Library

    /// The bundled voice first (a CC0 Castilian clip), then the user's voices,
    /// newest first.
    static func voices() -> [ClonedVoice] {
        let bundled = bundledVoices()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let user = names.compactMap { name -> ClonedVoice? in
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("voice.json")),
                  var voice = try? JSONDecoder.mingVoices.decode(ClonedVoice.self, from: data),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference.wav").path)
            else { return nil }
            voice.origin = voice.origin == .bundled ? .imported : voice.origin
            return voice
        }
        return bundled + user.sorted { $0.createdAt > $1.createdAt }
    }

    /// Validates and saves a new voice; returns it.
    @discardableResult
    static func save(_ clip: PreparedClip, name: String, language: String, transcript: String,
                     origin: ClonedVoice.Origin, consent: Bool) throws -> ClonedVoice {
        guard consent else { throw StoreError.missingConsent }
        try validate(clip)
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimum = minimumTranscriptCharacters(forDuration: clip.durationS)
        guard words.count >= minimum else { throw StoreError.transcriptTooShort(minimum) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = ClonedVoice(id: UUID().uuidString.lowercased(),
                                name: trimmedName.isEmpty ? String(localized: "My voice") : trimmedName,
                                language: language, transcript: words, durationS: clip.durationS,
                                createdAt: Date(), origin: origin == .bundled ? .imported : origin)
        let folder = directory.appendingPathComponent(voice.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try writeWAV(clip.samples, to: folder.appendingPathComponent("reference.wav"))
            try JSONEncoder.mingVoices.encode(voice).write(to: folder.appendingPathComponent("voice.json"),
                                                           options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return voice
    }

    static func delete(id: String) {
        guard !bundledVoices().contains(where: { $0.id == id }), isSafeID(id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }

    static func voice(id: String) -> ClonedVoice? {
        voices().first { $0.id == id }
    }

    /// The clip and transcript Ming is conditioned on for this voice.
    static func reference(id: String) throws -> MingReference {
        guard let voice = voice(id: id), let url = referenceURL(for: voice) else {
            throw StoreError.unreadableAudio
        }
        return MingReference(samples: try prepare(url: url).samples, transcript: voice.transcript)
    }

    static func referenceURL(for voice: ClonedVoice) -> URL? {
        if voice.isBundled {
            return Bundle.main.url(forResource: voice.id, withExtension: "wav", subdirectory: "MingVoices")
                ?? Bundle.main.url(forResource: voice.id, withExtension: "wav")
        }
        guard isSafeID(voice.id) else { return nil }
        return directory.appendingPathComponent(voice.id, isDirectory: true).appendingPathComponent("reference.wav")
    }

    private static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..")
    }

    /// The clip that ships with the app: `es-dave` from OHF-Voice/voice-datasets (CC0).
    private static func bundledVoices() -> [ClonedVoice] {
        guard let url = Bundle.main.url(forResource: "es-dave", withExtension: "txt", subdirectory: "MingVoices")
                ?? Bundle.main.url(forResource: "es-dave", withExtension: "txt"),
              let transcript = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return [ClonedVoice(id: "es-dave", name: "Dave", language: "es-ES",
                            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                            durationS: 9.8, createdAt: .distantPast, origin: .bundled)]
    }

    // MARK: Audio

    static func validate(_ clip: PreparedClip) throws {
        guard clip.durationS >= minimumSeconds else { throw StoreError.tooShort }
        guard clip.durationS <= maximumSeconds else { throw StoreError.tooLong }
    }

    /// Reads any audio file AVFoundation can decode as mono 44.1 kHz Float PCM,
    /// trims leading and trailing silence and normalizes the peak to −1 dBFS.
    static func prepare(url: URL) throws -> PreparedClip {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw StoreError.unreadableAudio }
        let source = file.processingFormat
        guard file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: target)
        else { throw StoreError.unreadableAudio }
        let ratio = sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw StoreError.unreadableAudio
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, let channel = output.floatChannelData?[0] else {
            throw StoreError.unreadableAudio
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        return PreparedClip(samples: normalized(trimmed(samples)))
    }

    /// Drops silence before the first and after the last 20 ms frame louder
    /// than −45 dBFS, keeping 150 ms of room on each side.
    static func trimmed(_ samples: [Float]) -> [Float] {
        let frame = Int(sampleRate * 0.02)
        guard samples.count > frame * 2 else { return samples }
        let threshold: Float = 0.0056
        let frames = samples.count / frame
        func loud(_ index: Int) -> Bool {
            var peak: Float = 0
            for sample in samples[(index * frame)..<min((index + 1) * frame, samples.count)] {
                peak = max(peak, abs(sample))
            }
            return peak > threshold
        }
        guard let first = (0..<frames).first(where: loud), let last = (0..<frames).last(where: loud) else {
            return []
        }
        let margin = Int(sampleRate * 0.15)
        let start = max(0, first * frame - margin)
        let end = min(samples.count, (last + 1) * frame + margin)
        return Array(samples[start..<end])
    }

    static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0001 else { return samples }
        let gain = 0.89 / peak
        return samples.map { $0 * gain }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw StoreError.unreadableAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: Transcription

    /// The words spoken in `clip`, recognized on this device with Apple's
    /// speech model for `language` (macOS 26 or later). Nil when the model is
    /// not installed yet (it is requested) or nothing was recognized; the
    /// user then types the transcript.
    static func transcribe(_ clip: PreparedClip, language: String) async -> String? {
        guard #available(iOS 26.0, macOS 26.0, *) else { return nil }
        let words = try? await SpeechWordAligner.recognizedText(samples: clip.samples, sampleRate: sampleRate,
                                                                language: language)
        let text = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Reading prompts

    /// Paragraphs to read aloud when recording, about 10 to 15 seconds each,
    /// with the sounds that give an accent away (from Nodus).
    static func sampleParagraphs(for language: String) -> [String] {
        switch String(language.prefix(2)) {
        case "es":
            [
                "En este capítulo analizaremos la hipótesis principal del estudio. Los resultados sugieren que la concentración de zinc influye directamente en la eficacia del proceso, aunque conviene interpretarlos con cautela.",
                "Durante el siglo diecinueve, las ciudades crecieron con rapidez y la población cambió sus costumbres. Muchos cronistas describieron aquel proceso con una mezcla de entusiasmo, sorpresa y cierta preocupación.",
                "La lluvia caía sobre la plaza mientras cerrábamos la biblioteca. Al día siguiente, decidimos revisar de nuevo las fuentes, comparar las citas y escribir una conclusión más precisa.",
            ]
        case "fr":
            ["Dans ce chapitre, nous analyserons l'hypothèse principale de l'étude. Les résultats suggèrent que la concentration de zinc influence directement l'efficacité du processus, mais il convient de les interpréter avec prudence."]
        case "de":
            ["In diesem Kapitel untersuchen wir die zentrale Hypothese der Studie. Die Ergebnisse deuten darauf hin, dass die Zinkkonzentration die Wirksamkeit des Verfahrens direkt beeinflusst, sollten aber vorsichtig interpretiert werden."]
        case "zh":
            ["在本章中，我们将分析这项研究的主要假设。结果表明，锌的浓度会直接影响整个过程的效率，但我们仍需谨慎解读这些数据。"]
        case "ja":
            ["この章では、研究の主要な仮説を分析します。結果は、亜鉛の濃度が工程の効率に直接影響することを示していますが、慎重に解釈する必要があります。"]
        case "ko":
            ["이 장에서는 연구의 주요 가설을 분석합니다. 결과는 아연 농도가 공정의 효율에 직접적인 영향을 준다는 것을 보여 주지만, 신중하게 해석해야 합니다."]
        default:
            [
                "In this chapter we examine the study's main hypothesis. The results suggest that zinc concentration directly affects the efficiency of the process, although they should be interpreted with caution.",
                "Throughout the nineteenth century, cities grew quickly and daily life changed with them. Many writers described that transformation with a mix of enthusiasm, surprise and some concern.",
            ]
        }
    }
}

private extension JSONEncoder {
    static var mingVoices: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var mingVoices: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
