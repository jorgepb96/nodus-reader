// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import QwenANE
import SwiftUI

@main
struct QwenDeviceProbeApp: App {
    @StateObject private var model = ProbeModel()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 20) {
                Text("Qwen · prueba local").font(.title.bold())
                Text(model.status)
                Text("Usa la grabación CC0 incluida. No accede a tu biblioteca ni graba el micrófono.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Probar clonación") { model.start("smoke") }.disabled(model.running)
                Button("Lectura continua · 5 minutos") { model.start("soak") }.disabled(model.running)
                Text("Durante la lectura continua puedes bloquear el iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .task {
                if let mode = CommandLine.arguments.dropFirst().first(where: { ["smoke", "soak"].contains($0) }) {
                    model.start(mode)
                }
            }
        }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var status = "Preparado. Copia los modelos en Documents/Models antes de empezar."
    @Published var running = false
    private let log = ProbeLog()
    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("QwenPlaybackStarted"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                UIApplication.shared.isIdleTimerDisabled = false
                self?.status = "Lectura en marcha. Ya puedes bloquear el iPhone."
            }
        })
        for (name, phase) in [(UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.didBecomeActiveNotification, "foreground"),
                              (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
                              (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [log] _ in
                log.setPhase(phase)
            })
        }
    }

    func start(_ mode: String) {
        guard !running else { return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Preparando la voz y cargando Qwen…"
        log.emit("start", ["mode": mode, "system": UIDevice.current.systemVersion,
                           "batteryLevel": UIDevice.current.batteryLevel, "batteryState": UIDevice.current.batteryState.rawValue])
        let log = log
        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
                try await Task.detached(priority: .userInitiated) {
                    let worker = try ProbeWorker(log: log)
                    if mode == "smoke" { try worker.smoke() }
                    else { try worker.soak(seconds: 300) }
                }.value
                status = "Prueba terminada. Los resultados están guardados en el dispositivo."
                log.emit("complete", ["batteryLevel": UIDevice.current.batteryLevel,
                                       "batteryState": UIDevice.current.batteryState.rawValue])
            } catch {
                status = "Error: \(error.localizedDescription)"
                log.emit("error", ["message": String(describing: error)])
            }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

final class ProbeLog: @unchecked Sendable {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let lock = NSLock()
    private var phase = "foreground"
    private var events: [[String: Any]] = []
    private let runID = UUID().uuidString

    func setPhase(_ value: String) {
        lock.lock(); phase = value; lock.unlock()
        emit("lifecycle", ["state": value])
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var row = fields
        row["event"] = event
        row["time"] = Date().timeIntervalSince1970
        row["phase"] = phase
        row["thermal"] = ProcessInfo.processInfo.thermalState.rawValue
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        row["peakRSSBytes"] = usage.ru_maxrss
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if code == KERN_SUCCESS { row["footprintBytes"] = info.phys_footprint }
        events.append(row)
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
            for name in ["events.json", "events-\(runID).json"] {
                try? data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        print("QWEN_PROBE \(event) \(fields)")
        fflush(stdout)
    }
}

final class ProbeWorker {
    let log: ProbeLog
    let engine: QwenANEEngine
    let voice: QwenVoiceFiles
    let outputs: URL

    init(log: ProbeLog) throws {
        self.log = log
        outputs = log.root.appendingPathComponent("Outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: outputs.path)
        let models = log.root.appendingPathComponent("Models", isDirectory: true)
        log.emit("verify_begin")
        try Self.verify(models)
        log.emit("verify_end")
        // Mirror QwenSpeech: the synthesis engine is resident while a new
        // reference is prepared, so this includes the app's memory overlap.
        log.emit("load_begin")
        let t1 = Date()
        engine = try QwenANEEngine(modelsDirectory: models)
        log.emit("load_end", ["seconds": Date().timeIntervalSince(t1)])
        let clip = Bundle.main.url(forResource: "es-dave", withExtension: "wav")!
        let transcript = try String(contentsOf: Bundle.main.url(forResource: "es-dave", withExtension: "txt")!, encoding: .utf8)
        let cache = log.root.appendingPathComponent("Voice-\(UUID().uuidString)")
        log.emit("clone_begin", ["cache": cache.lastPathComponent])
        let t0 = Date()
        voice = try QwenVoicePrep.prepared(referenceWAV: Data(contentsOf: clip), transcript: transcript,
                                           cacheDirectory: cache, modelsDirectory: models)
        log.emit("clone_end", ["seconds": Date().timeIntervalSince(t0), "frames": voice.refCodes[0].count,
                               "speakerDimensions": voice.spkEmbedding.count, "cache": cache.lastPathComponent])
    }

    func smoke() throws {
        _ = try render("La lluvia caía sobre la plaza mientras cerrábamos la biblioteca. Al día siguiente revisamos las fuentes.", language: "es", name: "baseline-es")
        _ = try render("The rain was falling on the square as we closed the library. The next day, we reviewed the sources.", language: "en", name: "baseline-en")
        let deadline = Date().addingTimeInterval(0.25)
        let cancelled = try engine.render(text: "Esta frase debe detenerse antes de terminar.", voice: voice,
            seed: 7, language: "es", cancelled: { Date() >= deadline })
        guard cancelled.stopReason == .cancelled else { throw failure("Cancellation did not stop inference") }
        log.emit("cancelled", ["frames": cancelled.frames])
        _ = try render("La voz vuelve a funcionar después de detener la lectura.", language: "es", name: "after-cancel")
    }

    func render(_ text: String, language: String, name: String, until deadline: Date? = nil) throws -> [Float] {
        log.emit("render_begin", ["name": name, "text": text, "language": language])
        let started = Date()
        let session = QwenTalkSession(engine: engine, voice: voice, language: language, seedText: text)
        let result = try session.renderBreak(text, cancelled: { deadline.map { Date() >= $0 } ?? false })
        if let deadline, Date() >= deadline { throw CancellationError() }
        let elapsed = Date().timeIntervalSince(started)
        guard !result.samples.isEmpty, result.samples.allSatisfy(\.isFinite),
              result.samples.contains(where: { abs($0) > 0.001 }), result.parts.allSatisfy({ !$0.derailed }) else {
            throw failure("Silent, non-finite or truncated output: \(name)")
        }
        try write(result.samples, name: name)
        let seconds = Double(result.samples.count) / 24_000
        log.emit("render_end", ["name": name, "audioSeconds": seconds, "wallSeconds": elapsed,
                               "rtf": elapsed / seconds, "takes": result.parts.reduce(0) { $0 + $1.takes }])
        return result.samples
    }

    func soak(seconds: Int) throws {
        let audio = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: format)
        try audio.start()
        defer { player.stop(); audio.stop() }
        let queue = PlaybackCount()
        let phrases = [
            "La lluvia caía sobre la plaza mientras cerrábamos la biblioteca. Al día siguiente revisamos las fuentes.",
            "Durante el siglo diecinueve las ciudades crecieron con rapidez, y la población cambió muchas de sus costumbres.",
            "Al llegar a casa, dejamos los libros sobre la mesa y abrimos la ventana para escuchar el sonido de la calle.",
            "Los resultados de la investigación deben interpretarse con cautela y compararse con las observaciones anteriores.",
            "Aquella mañana, el tren salió de la estación con unos minutos de retraso. Nadie parecía tener demasiada prisa.",
            "El autor explica su hipótesis con varios ejemplos y dedica el último capítulo a comentar las preguntas pendientes."
        ]
        var index = 0
        func enqueue(until deadline: Date? = nil) throws {
            let samples = try render(phrases[index % phrases.count], language: "es", name: "soak-\(index)", until: deadline)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            queue.add()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in queue.played() }
            index += 1
        }
        // A two-sentence lead mirrors the reader's prefetch and avoids calling
        // a first model load a playback underrun.
        try enqueue(); try enqueue()
        player.play()
        log.emit("playback_started", ["durationSeconds": seconds])
        NotificationCenter.default.post(name: Notification.Name("QwenPlaybackStarted"), object: nil)
        let playbackStart = Date()
        let deadline = playbackStart.addingTimeInterval(Double(seconds))
        while Date() < deadline {
            if queue.count < 3 {
                do { try enqueue(until: deadline) }
                catch is CancellationError { break }
            }
            else { Thread.sleep(forTimeInterval: 0.1) }
        }
        queue.finish()
        log.emit("soak_end", ["utterances": index, "underruns": queue.underruns,
                              "elapsedSeconds": Date().timeIntervalSince(playbackStart)])
    }

    private func write(_ samples: [Float], name: String) throws {
        let url = outputs.appendingPathComponent(name + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "QwenDeviceProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func verify(_ root: URL) throws {
        struct Manifest: Decodable {
            struct File: Decodable { let path: String; let bytes: Int64; let sha256: String }
            let files: [File]
        }
        let data = try Data(contentsOf: Bundle.main.url(forResource: "QwenModelManifest", withExtension: "json")!)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        for file in manifest.files {
            let url = root.appendingPathComponent(file.path)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256(), bytes: Int64 = 0
            while true {
                let count = try autoreleasepool { () throws -> Int in
                    guard let block = try handle.read(upToCount: 8 << 20), !block.isEmpty else { return 0 }
                    hasher.update(data: block)
                    return block.count
                }
                if count == 0 { break }
                bytes += Int64(count)
            }
            guard bytes == file.bytes, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw NSError(domain: "QwenDeviceProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model integrity: \(file.path)"])
            }
        }
    }
}

final class PlaybackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = 0, empty = 0
    private var draining = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return queued }
    var underruns: Int { lock.lock(); defer { lock.unlock() }; return empty }
    func add() { lock.lock(); queued += 1; lock.unlock() }
    func finish() { lock.lock(); draining = true; lock.unlock() }
    func played() { lock.lock(); queued -= 1; if queued == 0 && !draining { empty += 1 }; lock.unlock() }
}
