// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Darwin
import Foundation
import QwenANE

// The original six positional arguments remain supported. Additional options
// produce a reproducible matrix in one process, with cold and warm costs apart.
let args = CommandLine.arguments
setbuf(stdout, nil)
func fail(_ message: String) -> Never { fputs("\(message)\n", stderr); exit(1) }
guard args.count >= 7, (args.count - 7) % 2 == 0 else {
    fail("Usage: qwen-probe MODELS REFERENCE TRANSCRIPT LANGUAGE TEXT OUTPUT.wav [--cases FILE.json] [--report FILE.json] [--repetitions N] [--warmup N] [--experimental-cp MODEL.mlmodelc]")
}
struct ProbeCase: Codable { let id: String; let language: String; let text: String }
var flags: [String: String] = [:]
for i in stride(from: 7, to: args.count, by: 2) {
    guard ["--cases", "--report", "--repetitions", "--warmup", "--experimental-cp"].contains(args[i]), flags[args[i]] == nil else {
        fail("Unknown or repeated option: \(args[i])")
    }
    flags[args[i]] = args[i + 1]
}
func count(_ name: String, fallback: Int, minimum: Int) -> Int {
    guard let raw = flags[name] else { return fallback }
    guard let n = Int(raw), n >= minimum, n <= 20 else { fail("Invalid \(name): \(raw)") }
    return n
}
let repetitions = count("--repetitions", fallback: 1, minimum: 1)
let warmups = count("--warmup", fallback: 0, minimum: 0)
let outputURL = URL(fileURLWithPath: args[6])
let reportURL = URL(fileURLWithPath: flags["--report"] ?? outputURL.deletingPathExtension().path + ".json")
var report: [String: Any] = ["schema": 1, "models": args[1], "reference": args[2],
    "system": ProcessInfo.processInfo.operatingSystemVersionString, "processorCount": ProcessInfo.processInfo.processorCount,
    "warmupRequests": warmups, "repetitions": repetitions,
    "note": "Vocoder busy time overlaps generation. Stage times describe kept takes; request time includes retries. Footprint is this process, not total system memory."]
var rows: [[String: Any]] = []
func saveReport() throws {
    report["runs"] = rows
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
}
final class MemorySampler {
    private(set) var maximum: UInt64 = 0
    private var lastSample = -Double.infinity
    func sample(force: Bool = false) -> UInt64 {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSample >= 0.25 else { return maximum }
        lastSample = now
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        if code == KERN_SUCCESS { maximum = max(maximum, info.phys_footprint); return info.phys_footprint }
        return 0
    }
}
func writeAudio(_ samples: [Float], rate: Int, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    pcm.frameLength = pcm.frameCapacity
    samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: pcm)
}
func timings(_ t: QwenTimings) -> [String: Double] {
    ["prompt": t.prompt, "prefill": t.prefill, "loop": t.loop, "talker": t.talker,
     "codePredictor": t.codePredictor, "vocoderBusy": t.vocoder, "vocoderWait": t.vocoderWait, "total": t.total]
}
do {
    let cases = try flags["--cases"].map { try JSONDecoder().decode([ProbeCase].self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        ?? [ProbeCase(id: "single", language: args[4], text: args[5])]
    guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count,
          cases.allSatisfy({ !$0.text.isEmpty && !$0.id.isEmpty && $0.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else {
        fail("Cases need unique filename-safe IDs and nonempty text")
    }
    let root = URL(fileURLWithPath: args[1], isDirectory: true)
    let memory = MemorySampler()
    report["initialFootprintBytes"] = memory.sample(force: true)
    report["phase"] = "loading"
    if let candidate = flags["--experimental-cp"] { report["experimentalCodePredictor"] = candidate }
    try saveReport()
    var started = ProcessInfo.processInfo.systemUptime
    let engine = try QwenANEEngine(modelsDirectory: root,
        experimentalCodePredictor: flags["--experimental-cp"].map { URL(fileURLWithPath: $0) })
    report["modelLoadSeconds"] = ProcessInfo.processInfo.systemUptime - started
    report["loadedFootprintBytes"] = memory.sample(force: true)
    print("Engine loaded in \(report["modelLoadSeconds"]!) s")
    started = ProcessInfo.processInfo.systemUptime
    let voice = try QwenVoicePrep.prepared(referenceWAV: Data(contentsOf: URL(fileURLWithPath: args[2])),
        transcript: args[3], cacheDirectory: root.appendingPathComponent("probe-voice"), modelsDirectory: root)
    report["voicePreparationSeconds"] = ProcessInfo.processInfo.systemUptime - started
    report["referenceCodecFrames"] = voice.refCodes.first?.count ?? 0
    report["phase"] = "synthesis"
    print("Voice prepared in \(report["voicePreparationSeconds"]!) s")
    try saveReport()
    for warmup in 0..<warmups {
        let item = cases[0]
        let session = QwenTalkSession(engine: engine, voice: voice, language: item.language, seedText: item.text)
        _ = try session.renderBreak(item.text, pace: { _ = memory.sample() })
        print("Warmup \(warmup + 1) finished")
    }
    for repetition in 0..<repetitions {
        for item in cases {
            try autoreleasepool {
                let session = QwenTalkSession(engine: engine, voice: voice, language: item.language, seedText: item.text)
                let t0 = ProcessInfo.processInfo.systemUptime
                let result = try session.renderBreak(item.text, pace: { _ = memory.sample() }, onPart: { print($0.logLine) })
                let elapsed = ProcessInfo.processInfo.systemUptime - t0
                guard !result.samples.isEmpty, result.samples.allSatisfy(\.isFinite),
                      result.samples.contains(where: { abs($0) > 0.001 }), !result.parts.isEmpty,
                      result.parts.allSatisfy({ !$0.derailed }) else {
                    throw NSError(domain: "QwenProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty, silent, non-finite or truncated speech for \(item.id)"])
                }
                let url = cases.count == 1 && repetitions == 1 ? outputURL
                    : outputURL.deletingPathExtension().appendingPathExtension("\(item.id)-\(repetition + 1).wav")
                try writeAudio(result.samples, rate: result.sampleRate, to: url)
                let duration = Double(result.samples.count) / Double(result.sampleRate)
                let parts: [[String: Any]] = result.parts.map { part in
                    var row: [String: Any] = ["text": part.text, "frames": part.frames, "generatedFrames": part.generatedFrames, "takes": part.takes,
                        "stop": part.stopReason.rawValue, "audioSeconds": part.audioSeconds, "renderSeconds": part.renderSeconds]
                    if let t = part.timings { row["stagesSeconds"] = timings(t) }
                    return row
                }
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                rows.append(["id": item.id, "language": item.language, "text": item.text, "repetition": repetition + 1,
                    "seed": String(session.seed), "audioSeconds": duration, "synthesisSeconds": elapsed, "rtf": elapsed / duration,
                    "footprintBytes": memory.sample(force: true), "peakSampledFootprintBytes": memory.maximum,
                    "peakRSSBytes": usage.ru_maxrss, "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "output": url.path, "parts": parts])
                try saveReport()
                print("\(item.id) #\(repetition + 1): \(duration) s audio; \(elapsed) s synthesis; RTF \(elapsed / duration)")
            }
        }
    }
    _ = memory.sample(force: true)
    report["peakSampledFootprintBytes"] = memory.maximum
    report["completed"] = true
    report["phase"] = "complete"
    try saveReport()
} catch {
    report["completed"] = false
    report["error"] = String(describing: error)
    try? saveReport()
    fail(String(describing: error))
}
