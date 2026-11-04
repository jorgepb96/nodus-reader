import CoreML
import CryptoKit
import Foundation
import GVoiceKit
import GVoiceProductionKit

public enum QwenVoicePrepError: Error, Equatable, LocalizedError {
    /// The trimmed reference is longer than the speech encoder's fixed input (40 s; 20 s on older model sets). Internal signal, not a refusal: `QwenANESpeechModel.prepare` answers it by picking a window of the master.
    case referenceTooLong(seconds: Double)
    case referenceTooShort(seconds: Double)
    /// Not audio at all (any rate, channel count or sample format AVFoundation reads is converted).
    case unsupportedWAV(String)
    case modelMissing(String)
    case modelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .referenceTooLong(let s): return "QwenVoicePrep: reference is \(s) s, longer than the encoder's input; a window of it is needed"
        case .referenceTooShort(let s): return "QwenVoicePrep: reference is \(s) s, too short to clone from"
        case .unsupportedWAV(let m): return "QwenVoicePrep: \(m)"
        case .modelMissing(let m): return "QwenVoicePrep: missing model \(m)"
        case .modelFailed(let m): return "QwenVoicePrep: \(m)"
        }
    }
}

/// Turns a prepared reference (mono 24 kHz WAV, already through `ReferenceStandard`, plus its exact
/// transcript) into a Qwen voice: speech-tokenizer codes (16 x T) and the x-vector speaker embedding.
/// Both encoders are Core ML fp32 on the CPU (`.cpuOnly`): exactness matters and it runs once per
/// voice. Never CPU_AND_NE: that hung the Mac's ANE compiler for 1.5 h. Spec and parity numbers:
/// qwen-onnx-cpu/docs/voice-prep-coreml.md.
///
/// Models (compiled) under `<modelsDirectory>/coreml/`: `QwenSpeechEncoder.mlmodelc`, `QwenSpeakerEncoder.mlmodelc`.
public enum QwenVoicePrep {
    /// Bump when the recipe changes (mel, tail rule, encoders): cached voices are recomputed.
    public static let prepVersion = 1
    public static let melKind = "upstream"
    /// The shipped speech encoder's fixed input (40 s since 2026-10-04; it was 20 s). The real limit is
    /// read from the model file at prep time, so an older 20 s model set keeps working.
    public static let maxSamples = 960_000
    public static let minSamples = 12_000           // 0.5 s
    static let speakerFrames = 4096
    static let sampleRate = 24_000

    // MARK: cache API

    /// Returns the cached voice in `cacheDirectory` when its source sha256, transcript and prep version
    /// match; otherwise prepares it and (re)writes `voice.json`, `ref_codes.npy`, `spk_embed.npy`
    /// (the layout `QwenVoiceFiles(directory:)` reads). A pure function of its inputs: no global state.
    public static func prepared(referenceWAV: Data, transcript: String, cacheDirectory: URL,
                                modelsDirectory: URL, kind: QwenEngineFiles.Kind = .qwen06) throws -> QwenVoiceFiles {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = sha256Hex(referenceWAV)
        if let hit = cached(directory: cacheDirectory, sha: sha, text: text, kind: kind) { return hit }

        let voice = try prepare(referenceWAV: referenceWAV, transcript: text, modelsDirectory: modelsDirectory, kind: kind)
        try write(voice, sha: sha, to: cacheDirectory)
        return voice
    }

    /// Prepares without touching any cache.
    public static func prepare(referenceWAV: Data, transcript: String, modelsDirectory: URL,
                               kind: QwenEngineFiles.Kind = .qwen06) throws -> QwenVoiceFiles {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same order as tools/prep_voice.py: trim a cut-off tail, then encode.
        let all = try samples(of: referenceWAV)
        let samples = Array(all[0..<ReferenceTail.end(of: all, sampleRate: sampleRate)])
        let seconds = Double(samples.count) / Double(sampleRate)
        // Cheap check first (no model load): nothing past the largest encoder ever shipped.
        guard samples.count <= maxSamples else { throw QwenVoicePrepError.referenceTooLong(seconds: seconds) }
        guard samples.count >= minSamples else { throw QwenVoicePrepError.referenceTooShort(seconds: seconds) }

        let coreml = modelsDirectory.appendingPathComponent("coreml")
        let speech = try load(coreml.appendingPathComponent("QwenSpeechEncoder.mlmodelc"))
        let speaker = try load(coreml.appendingPathComponent("QwenSpeakerEncoder.mlmodelc"))
        guard samples.count <= inputLength(speech, "wav", axis: 2, default: maxSamples) else {
            throw QwenVoicePrepError.referenceTooLong(seconds: seconds)
        }
        return QwenVoiceFiles(refText: text,
                              refCodes: try codes(speech, samples),
                              spkEmbedding: try embedding(speaker, samples, dimension: kind.speakerDimension))
    }

    /// The longest section a Qwen voice may store: the encoder's input, but never more than 256 codec
    /// frames (20.48 s at 12.5 Hz) -- the pack format's ref_codes limit, which keeps the voice prefix
    /// small enough to leave the ANE talker's 1024-slot KV for the speech it generates.
    public static let maxRefFrames = 256
    public static func sectionLimitSamples(modelsDirectory: URL) -> Int {
        min(encoderLimitSamples(modelsDirectory: modelsDirectory), maxRefFrames * 1920)
    }

    /// The speech encoder's real input length in samples, read from the model file (40 s, or 20 s on an
    /// older model set); `maxSamples` when the model can't be loaded (prep then reports that itself).
    public static func encoderLimitSamples(modelsDirectory: URL) -> Int {
        let url = modelsDirectory.appendingPathComponent("coreml").appendingPathComponent("QwenSpeechEncoder.mlmodelc")
        guard let speech = try? load(url) else { return maxSamples }
        return min(maxSamples, inputLength(speech, "wav", axis: 2, default: maxSamples))
    }

    // MARK: encoders

    private static func load(_ url: URL) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw QwenVoicePrepError.modelMissing(url.lastPathComponent) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        do { return try MLModel(contentsOf: url, configuration: cfg) }
        catch { throw QwenVoicePrepError.modelFailed("loading \(url.lastPathComponent): \(error)") }
    }

    /// Length of a fixed-shape model input along `axis` (the encoders are built for one padded size).
    static func inputLength(_ model: MLModel, _ name: String, axis: Int, default d: Int) -> Int {
        let shape = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape ?? []
        return axis < shape.count ? shape[axis].intValue : d
    }

    /// T = ceil(ceil(ceil(ceil(ceil(n/4)/5)/6)/8)/2)
    static func codeFrames(samples n: Int) -> Int {
        [4, 5, 6, 8, 2].reduce(n) { ($0 + $1 - 1) / $1 }
    }

    private static func codes(_ model: MLModel, _ x: [Float]) throws -> [[Int]] {
        let N = inputLength(model, "wav", axis: 2, default: maxSamples)
        let wav = try MLMultiArray(shape: [1, 1, NSNumber(value: N)], dataType: .float32)
        let p = wav.dataPointer.bindMemory(to: Float.self, capacity: N)
        p.initialize(repeating: 0, count: N)
        x.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: x.count) }
        let n = try MLMultiArray(shape: [1], dataType: .int32)
        n[0] = NSNumber(value: x.count)
        let out: MLFeatureProvider
        do {
            out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["wav": wav, "n_samples": n]))
        } catch { throw QwenVoicePrepError.modelFailed("speech encoder: \(error)") }
        guard let c = out.featureValue(for: "codes")?.multiArrayValue, c.shape.count == 3, c.shape[1].intValue == 16 else {
            throw QwenVoicePrepError.modelFailed("speech encoder returned no (1,16,T) codes")
        }
        let T = codeFrames(samples: x.count)
        guard T <= c.shape[2].intValue else { throw QwenVoicePrepError.modelFailed("speech encoder returned too few frames") }
        // Multi-index subscripts: the output may be row-padded, so a flat offset would be wrong.
        return (0..<16).map { g in (0..<T).map { t in c[[0, g, t] as [NSNumber]].intValue } }
    }

    private static func embedding(_ model: MLModel, _ x: [Float], dimension: Int) throws -> [Float] {
        let (mel, frames) = QwenMel.logMel(x)
        let F = inputLength(model, "mel", axis: 1, default: speakerFrames)
        guard frames <= F else { throw QwenVoicePrepError.referenceTooLong(seconds: Double(x.count) / Double(sampleRate)) }
        let arr = try MLMultiArray(shape: [1, NSNumber(value: F), NSNumber(value: QwenMel.nMels)], dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: F * QwenMel.nMels)
        p.initialize(repeating: 0, count: F * QwenMel.nMels)
        mel.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: mel.count) }
        let n = try MLMultiArray(shape: [1], dataType: .int32)
        n[0] = NSNumber(value: frames)
        let out: MLFeatureProvider
        do {
            out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": arr, "n_frames": n]))
        } catch { throw QwenVoicePrepError.modelFailed("speaker encoder: \(error)") }
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue, e.count == dimension else {
            throw QwenVoicePrepError.modelFailed("speaker encoder returned no \(dimension)-value embedding (is this model set the other size's?)")
        }
        return (0..<dimension).map { e[$0].floatValue }
    }

    // MARK: WAV

    /// Mono 24 kHz samples in [-1, 1) from WAV bytes of ANY sample rate and channel count: other rates are
    /// resampled (`NativeAudioProcessor`, AVAudioConverter at maximum quality) and channels averaged, so a
    /// 48 kHz or stereo reference is prepared like any other and never refused for its format. PCM16 and
    /// float32 are parsed directly; anything else AVFoundation reads is decoded through a temporary file.
    static func samples(of wav: Data) throws -> [Float] {
        let wav = Data(wav)   // zero-based indices
        guard let c = RefLoudness.dataChunk(in: wav) else { return try decodeThroughAVFoundation(wav) }
        let width = c.format == .pcm16 ? 2 : 4
        let channels = max(1, c.channels)
        let count = c.length / width
        guard count >= channels else { throw QwenVoicePrepError.unsupportedWAV("no audio") }
        let interleaved: [Float] = wav.withUnsafeBytes { raw -> [Float] in
            let base = raw.baseAddress!.advanced(by: c.offset)
            if c.format == .pcm16 {
                return (0..<count).map { Float(base.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self).littleEndian) / 32768 }
            }
            return (0..<count).map { Float(bitPattern: base.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) }
        }
        if channels == 1, c.sampleRate == sampleRate { return interleaved }
        let frames = count / channels
        let planar = (0..<channels).map { ch in (0..<frames).map { interleaved[$0 * channels + ch] } }
        return try mono24k(ReferenceAudioBuffer(sampleRate: c.sampleRate, channels: planar))
    }

    private static func mono24k(_ buffer: ReferenceAudioBuffer) throws -> [Float] {
        do {
            let out = try NativeAudioProcessor.resample(NativeAudioProcessor.mono(buffer), to: sampleRate)
            guard let samples = out.channels.first, !samples.isEmpty else { throw QwenVoicePrepError.unsupportedWAV("no audio") }
            return samples
        } catch let e as QwenVoicePrepError { throw e }
        catch { throw QwenVoicePrepError.unsupportedWAV("could not convert to 24 kHz mono: \(error)") }
    }

    private static func decodeThroughAVFoundation(_ wav: Data) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-prep-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try wav.write(to: tmp)
            return try mono24k(NativeAudioProcessor.decode(tmp))
        } catch let e as QwenVoicePrepError { throw e }
        catch { throw QwenVoicePrepError.unsupportedWAV("not a readable WAV") }
    }

    // MARK: cache files

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func cached(directory: URL, sha: String, text: String, kind: QwenEngineFiles.Kind = .qwen06) -> QwenVoiceFiles? {
        guard let raw = try? Data(contentsOf: directory.appendingPathComponent("voice.json")),
              let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              j["source_sha256"] as? String == sha,
              j["prep_version"] as? Int == prepVersion,
              j["mel"] as? String == melKind,
              (j["ref_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == text,
              let v = try? QwenVoiceFiles(directory: directory),
              v.refCodes.count == 16, !(v.refCodes[0].isEmpty), v.spkEmbedding.count == kind.speakerDimension else { return nil }
        return v
    }

    static func write(_ v: QwenVoiceFiles, sha: String, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // voice.json is the commit marker: remove it first, write it last.
        try? fm.removeItem(at: directory.appendingPathComponent("voice.json"))
        let T = v.refCodes[0].count
        let (codes, spk) = npyFiles(v)
        try codes.write(to: directory.appendingPathComponent("ref_codes.npy"), options: .atomic)
        try spk.write(to: directory.appendingPathComponent("spk_embed.npy"), options: .atomic)
        let meta: [String: Any] = ["ref_text": v.refText, "source_sha256": sha, "prep_version": prepVersion,
                                   "mel": melKind, "frames": T]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("voice.json"), options: .atomic)
    }

    /// `ref_codes.npy` (int32 (1,16,T)) and `spk_embed.npy` (float32 (dimension,)) bytes for a voice.
    static func npyFiles(_ v: QwenVoiceFiles) -> (codes: Data, spk: Data) {
        let T = v.refCodes[0].count
        var codes = [Int32](); codes.reserveCapacity(16 * T)
        for g in 0..<16 { codes.append(contentsOf: v.refCodes[g].map { Int32($0) }) }
        return (npy(codes, descr: "<i4", shape: "(1, 16, \(T))"), npy(v.spkEmbedding, descr: "<f4", shape: "(\(v.spkEmbedding.count),)"))
    }

    /// .npy v1.0, little-endian, C order.
    private static func npy<T>(_ values: [T], descr: String, shape: String) -> Data {
        var header = "{'descr': '\(descr)', 'fortran_order': False, 'shape': \(shape), }"
        let total = 10 + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - total % 64) % 64) + "\n"
        var d = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        let n = UInt16(header.utf8.count)
        d.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8)])
        d.append(Data(header.utf8))
        values.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
