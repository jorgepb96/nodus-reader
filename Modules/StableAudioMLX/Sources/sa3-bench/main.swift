// sa3-bench — measures Stable Audio 3 Small on this Mac (MLX, Metal).
//
//   sa3-bench convert <downloads> <models>
//   sa3-bench tokenize <tokenizer.model> <strings.json>   ids for parity checks
//   sa3-bench loop <in.wav> <out.wav> [seam]   trimmed seamless loop + seam metrics (JSON)
//   sa3-bench run <models> <outdir> <music|sfx> <seconds,...> [--steps 8] [--residency staged|resident]
//                 [--repeat 1] [--seed N] [--prompt "..."] [--loop-seam 2]
//
// Each run prints one JSON line (SA3Measurement plus audio levels) and writes a WAV.
// Mac numbers say nothing about an iPhone; the in-app lab measures the device.
import AVFoundation
import Foundation
import StableAudioMLX

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: sa3-bench convert|run …") }

switch arguments[1] {
case "convert":
    guard arguments.count >= 4 else { fail("usage: sa3-bench convert <downloads> <models>") }
    let downloads = URL(fileURLWithPath: arguments[2])
    let directory = SA3ModelDirectory(root: URL(fileURLWithPath: arguments[3]))
    let start = Date()
    for file in SA3Manifest.files(for: [.music, .sfx]) {
        do {
            try SA3Installer.verify(downloads.appendingPathComponent(file.fileName), against: file)
        } catch {
            fail("verify \(file.fileName): \(error)")
        }
    }
    let verified = Date().timeIntervalSince(start)
    do {
        try SA3Installer.prepare(kinds: [.music, .sfx], downloads: downloads, directory: directory, deleteArchives: false)
    } catch {
        fail("convert: \(error)")
    }
    let report: [String: Any] = [
        "verifySeconds": verified,
        "convertSeconds": Date().timeIntervalSince(start) - verified,
        "bytesOnDisk": directory.bytesOnDisk(),
        "peakFootprintBytes": ProcessMemory.footprint(),
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case "run":
    guard arguments.count >= 6 else { fail("usage: sa3-bench run <models> <outdir> <music|sfx> <seconds,...>") }
    let directory = SA3ModelDirectory(root: URL(fileURLWithPath: arguments[2]))
    let outdir = URL(fileURLWithPath: arguments[3])
    try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
    guard let kind = SA3ModelKind(rawValue: arguments[4]) else { fail("kind must be music or sfx") }
    let durations = arguments[5].split(separator: ",").compactMap { Float($0) }
    let steps = Int(option("--steps", in: arguments) ?? "8") ?? 8
    let residency = SA3Engine.Residency(rawValue: option("--residency", in: arguments) ?? "staged") ?? .staged
    let repeats = Int(option("--repeat", in: arguments) ?? "1") ?? 1
    let seed = UInt64(option("--seed", in: arguments) ?? "20261106") ?? 20_261_106
    let seam = Double(option("--loop-seam", in: arguments) ?? "2") ?? 2
    let prompt = option("--prompt", in: arguments) ?? (kind == .music
        ? "Melancholic instrumental piano, soft cello, slow tempo, no vocals."
        : "Heavy rain on windows, distant thunder, no music or voices.")
    let label = option("--label", in: arguments) ?? kind.rawValue

    let engine = SA3Engine(directory: directory, residency: residency, cacheLimitBytes: 64 << 20)
    let tokens = (try? await engine.tokenCount(prompt)) ?? -1
    for seconds in durations {
        for run in 0 ..< repeats {
            do {
                let output = try await engine.generate(.init(kind: kind, prompt: prompt, seconds: seconds, steps: steps, seed: seed &+ UInt64(run)))
                let name = "\(label)-\(Int(seconds))s-\(steps)st-\(residency.rawValue)-r\(run)"
                let wav = outdir.appendingPathComponent(name + ".wav")
                try SA3Audio.writeWAV(output.channels, sampleRate: output.sampleRate, to: wav)
                var loopName: String?
                if let looped = SA3Audio.loop(output.channels, sampleRate: output.sampleRate, seam: seam) {
                    let loopURL = outdir.appendingPathComponent(name + "-loop.wav")
                    try SA3Audio.writeWAV(looped, sampleRate: output.sampleRate, to: loopURL)
                    loopName = loopURL.lastPathComponent
                }
                let levels = SA3Audio.levels(output.channels, sampleRate: output.sampleRate)
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(output.measurement)) as! [String: Any]
                object["run"] = run
                object["promptTokens"] = tokens
                object["wav"] = wav.lastPathComponent
                object["loop"] = loopName ?? NSNull()
                object["peakDB"] = levels.peakDB
                object["rmsDB"] = levels.rmsDB
                object["oneSecondRMSSpreadDB"] = levels.oneSecondRMSSpreadDB
                object["realtimeFactor"] = output.measurement.realtimeFactor
                object["finite"] = output.channels.allSatisfy { $0.allSatisfy(\.isFinite) }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                fflush(stdout)
            } catch {
                fail("generate \(seconds)s: \(error)")
            }
        }
    }

case "inpaint":
    // sa3-bench inpaint <models> <in.wav> <out.wav> <keepUntil> <seconds> [--prompt] [--seed] [--kind music|sfx]
    guard arguments.count >= 7 else { fail("usage: sa3-bench inpaint <models> <in.wav> <out.wav> <keepUntil> <seconds>") }
    let directory = SA3ModelDirectory(root: URL(fileURLWithPath: arguments[2]))
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[3]))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let channels = (0 ..< Int(buffer.format.channelCount)).map {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
    }
    let keepUntil = Double(arguments[5])!
    let seconds = Float(arguments[6])!
    let kind = SA3ModelKind(rawValue: option("--kind", in: arguments) ?? "music") ?? .music
    let prompt = option("--prompt", in: arguments) ?? "TrackType: Music, VocalType: Instrumental. Mysterious harp and low strings, slowly evolving, gradual build."
    let seed = UInt64(option("--seed", in: arguments) ?? "23") ?? 23
    let engine = SA3Engine(directory: directory, residency: .staged, cacheLimitBytes: 64 << 20)
    let output = try await engine.generate(.init(kind: kind, prompt: prompt, seconds: seconds, steps: 8, seed: seed),
                                           inpaint: .init(channels: channels, keep: [0 ... keepUntil])) { stage in
        FileHandle.standardError.write("stage \(stage) footprint \(ProcessMemory.footprint() / 1_000_000) MB mlx \(SA3Engine.memoryReport)\n".data(using: .utf8)!)
    }
    try SA3Audio.writeWAV(output.channels, sampleRate: output.sampleRate, to: URL(fileURLWithPath: arguments[4]))
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(output.measurement)) as! [String: Any]
    object["realtimeFactor"] = output.measurement.realtimeFactor
    print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))

case "tokenize":
    // Reads a JSON array of strings, prints a JSON array of id arrays.
    guard arguments.count >= 4 else { fail("usage: sa3-bench tokenize <tokenizer.model> <strings.json>") }
    let tokenizer = try SentencePieceBPE(modelURL: URL(fileURLWithPath: arguments[2]))
    let strings = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
    let start = Date()
    let encoded = strings.map(tokenizer.encode)
    FileHandle.standardError.write("\(strings.count) strings in \(Date().timeIntervalSince(start)) s\n".data(using: .utf8)!)
    print(String(decoding: try JSONEncoder().encode(encoded), as: UTF8.self))

case "loudness":
    // Integrated loudness and true peak of WAV files, to check against ffmpeg's ebur128.
    for path in arguments.dropFirst(2) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channels = (0 ..< Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
        let rate = Int(file.processingFormat.sampleRate)
        print(String(format: "%@ I %.2f LUFS, TP %.2f dBTP", (path as NSString).lastPathComponent,
                     SA3Audio.integratedLoudness(channels, sampleRate: rate), SA3Audio.truePeak(channels)))
    }

case "loop":
    guard arguments.count >= 4 else { fail("usage: sa3-bench loop <in.wav> <out.wav> [seam]") }
    let seam = arguments.count > 4 ? Double(arguments[4]) ?? 2 : 2
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let rate = Int(file.processingFormat.sampleRate)
    let channels = (0 ..< Int(buffer.format.channelCount)).map {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
    }
    let range = SA3Audio.loopableRange(channels, sampleRate: rate)
    guard let looped = SA3Audio.loop(channels, sampleRate: rate, seam: seam) else { fail("clip too short to loop") }
    try SA3Audio.writeWAV(looped, sampleRate: rate, to: URL(fileURLWithPath: arguments[3]))
    let levels = SA3Audio.levels(looped, sampleRate: rate)
    let report: [String: Any] = [
        "keptFrom": Double(range.lowerBound) / Double(rate),
        "keptTo": Double(range.upperBound) / Double(rate),
        "clipSeconds": Double(channels[0].count) / Double(rate),
        "loopSeconds": Double(looped[0].count) / Double(rate),
        "seamLevelDeltaDB": SA3Audio.seamLevelDelta(looped, sampleRate: rate),
        "untrimmedSeamLevelDeltaDB": SA3Audio.loop(channels, sampleRate: rate, seam: seam, trim: false)
            .map { SA3Audio.seamLevelDelta($0, sampleRate: rate) } ?? 0,
        "loopRMSSpreadDB": levels.oneSecondRMSSpreadDB,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

default:
    fail("unknown command \(arguments[1])")
}
