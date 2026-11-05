// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import QwenANE

extension ProbeWorker {
    /// One resident CPU/ANE engine, interleaved candidates, fixed seeds, no redraws and no playback.
    /// The released predictor is greedy: these are talker ablations, not full upstream sampling parity.
    func samplingDiagnostics(until deadline: Double) throws {
        struct Case { let id: String; let text: String; let language: String }
        let cases = [
            Case(id: "es-short", text: "La lluvia caía sobre la plaza mientras cerrábamos la biblioteca.", language: "es"),
            Case(id: "es-numbers", text: "El diecinueve de noviembre, Lucía pagó veintitrés euros con cincuenta céntimos.", language: "es"),
            Case(id: "es-names", text: "Jorge, Lucía y Joaquín visitaron Zaragoza el miércoles por la mañana.", language: "es"),
            Case(id: "en-short", text: "The rain was falling on the square as we closed the library.", language: "en")
        ]
        let candidates: [(String, QwenSampling)] = [
            ("baseline", QwenSampling()),
            ("top50", QwenSampling(topK: 50)),
            ("top50-sampled-eos", QwenSampling(topK: 50, eosOnArgmax: false))
        ]
        let cancelled = { ProcessInfo.processInfo.systemUptime >= deadline }
        engine.options.capPauses = false
        log.emit("diagnostic_begin", ["residualSampling": "greedy", "deadlineUptime": deadline,
                                      "reference": "CC0 es-dave, full ICL", "redraws": 0])
        _ = try engine.warm(voice: voice, cancelled: cancelled)
        var replay: (QwenRender, String)?
        for (pass, seed) in [UInt64(7), UInt64(42)].enumerated() {
            for (index, item) in cases.enumerated() {
                for turn in candidates.indices {
                    if cancelled() { throw CancellationError() }
                    // Rotate order so the same candidate does not always pay the colder/warmer run.
                    let candidate = candidates[(turn + index + pass) % candidates.count]
                    engine.options.sampling = candidate.1
                    let name = "sampling-\(item.id)-\(seed)-\(candidate.0)"
                    log.emit("diagnostic_render_begin", ["name": name, "text": item.text, "seed": String(seed),
                                                        "topK": candidate.1.topK, "eosOnArgmax": candidate.1.eosOnArgmax])
                    var raw: QwenRender?
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = try engine.render(text: item.text, voice: voice, seed: seed,
                                                   language: item.language, cancelled: cancelled,
                                                   onRawRender: { raw = $0 })
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    if cancelled() { throw CancellationError() }
                    guard let raw else {
                        log.emit("diagnostic_render_empty", ["name": name, "stop": result.stopReason.rawValue])
                        continue
                    }
                    try write(raw.samples, name: name + "-raw")
                    try write(result.samples, name: name)
                    let codes = try JSONEncoder().encode(raw.codes)
                    try codes.write(to: outputs.appendingPathComponent(name + "-codes.json"), options: .atomic)
                    let t = result.timings
                    let row: [String: Any] = [
                        "name": name, "text": item.text, "language": item.language, "candidate": candidate.0,
                        "seed": String(seed), "topK": candidate.1.topK, "eosOnArgmax": candidate.1.eosOnArgmax,
                        "audioSeconds": result.audioSeconds, "rawAudioSeconds": raw.audioSeconds,
                        "synthesisSeconds": elapsed, "rtf": elapsed / max(0.001, result.audioSeconds),
                        "frames": result.frames, "generatedFrames": result.generatedFrames,
                        "rawStop": raw.stopReason.rawValue, "stop": result.stopReason.rawValue,
                        "derailed": QwenTalkSession.derailed(result), "longestPause": result.silenceBefore.longestPause,
                        "finite": raw.samples.allSatisfy(\.isFinite), "sampleCount": raw.samples.count,
                        "expectedSamples": raw.frames * 1920, "codesSHA256": Self.hash(codes),
                        "stagesSeconds": ["prompt": t.prompt, "prefill": t.prefill, "talker": t.talker,
                                          "codePredictor": t.codePredictor, "vocoderBusy": t.vocoder,
                                          "vocoderWait": t.vocoderWait, "total": t.total]
                    ]
                    log.emit("diagnostic_render_end", row)
                    if replay == nil { replay = (raw, name) }
                }
            }
        }
        if let (raw, name) = replay { try replayDiagnostics(raw, name: name, cancelled: cancelled) }
        engine.options = QwenANEEngine.Options()
        log.emit("diagnostic_end")
    }

    private func replayDiagnostics(_ raw: QwenRender, name: String, cancelled: () -> Bool) throws {
        let paths: [(String, [Int], Bool)] = [("inline12", [12], false), ("overlap1", [1], true),
                                             ("overlap4-8-12", [4, 8, 12], true)]
        for (id, schedule, overlap) in paths {
            if cancelled() { throw CancellationError() }
            let started = ProcessInfo.processInfo.systemUptime
            let pcm = try engine.decodeCodesForDiagnostics(raw.codes, voice: voice, chunkFrames: schedule,
                                                          overlap: overlap, cancelled: cancelled)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            var signal = 0.0, error = 0.0, maxError = 0.0
            for (a, b) in zip(raw.samples, pcm) {
                let delta = Double(a) - Double(b)
                signal += Double(a) * Double(a); error += delta * delta; maxError = max(maxError, abs(delta))
            }
            try write(pcm, name: name + "-replay-" + id)
            log.emit("diagnostic_replay", ["name": name, "path": id, "seconds": elapsed,
                "sampleCount": pcm.count, "expectedSamples": raw.frames * 1920,
                "sameLength": pcm.count == raw.samples.count, "exact": pcm == raw.samples,
                "maxAbsoluteError": maxError, "snrDB": 10 * log10(max(1e-30, signal) / max(1e-30, error)),
                "finite": pcm.allSatisfy(\.isFinite)])
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
