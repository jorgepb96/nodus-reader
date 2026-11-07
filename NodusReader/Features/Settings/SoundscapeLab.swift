// SPDX-License-Identifier: AGPL-3.0-only
//
// Soundscape Lab: the feasibility harness for generated music and ambience
// (Stable Audio 3 Small on MLX). Compiled only with the NODUS_SOUNDSCAPE_LAB
// condition, never in a regular or App Store build. Its text is developer-only
// and deliberately not localized.
#if NODUS_SOUNDSCAPE_LAB
import AVFoundation
import Foundation
import os
import StableAudioMLX
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class SoundscapeLab {
    static let shared = SoundscapeLab()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var test: String
        var measurement: SA3Measurement?
        var peakDB: Double?
        var rmsDB: Double?
        var oneSecondRMSSpreadDB: Double?
        var file: String?
        var loopFile: String?
        var batteryLevel: Float?
        var batteryState: String?
        var availableMemoryBytes: Int64?
        var note: String?
        var date = Date()
    }

    struct Report: Codable {
        var device: String
        var system: String
        var physicalMemoryBytes: UInt64
        var started: Date
        var entries: [Entry] = []
        /// Set before each run and cleared after it: a value left here after a relaunch
        /// means the app died during that run (most likely a jetsam memory kill).
        var runInProgress: String?
    }

    private(set) var status = "Idle"
    private(set) var isBusy = false
    private(set) var report: Report
    private(set) var downloadProgress: Double?
    private(set) var liveFootprint: Int64 = 0
    private(set) var liveThermal = ThermalStateName.current
    private(set) var narrationStallSeconds: Double = 0
    private(set) var narrationStallCount = 0
    private(set) var previousRunDied: String?
    var includeLongClips = false
    private(set) var nowPlaying: String?
    var musicVolume = 0.5 { didSet { player?.setVolume(.music, slider: musicVolume) } }
    var ambienceVolume = 0.5 { didSet { player?.setVolume(.ambience, slider: ambienceVolume) } }
    var sustainedMinutes = 10.0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var engine: SA3Engine?
    @ObservationIgnored private var player: ImmersiveAudioEngine?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored weak var playback: PlaybackController?
    @ObservationIgnored weak var library: LibraryService?
    @ObservationIgnored weak var immersive: ImmersiveAudioController?

    let directory: SA3ModelDirectory
    let downloads: URL
    let output: URL
    private let reportURL: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var root = support.appendingPathComponent("SoundscapeLab/Models", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        directory = SA3ModelDirectory(root: root)
        downloads = caches.appendingPathComponent("SoundscapeLab/Downloads", isDirectory: true)
        output = documents.appendingPathComponent("SoundscapeLab", isDirectory: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        reportURL = output.appendingPathComponent("report.json")

        if let data = try? Data(contentsOf: reportURL),
           var saved = try? JSONDecoder.lab.decode(Report.self, from: data) {
            previousRunDied = saved.runInProgress
            if let died = saved.runInProgress {
                saved.entries.append(Entry(test: "crash", note: "The app ended during \(died) (likely a memory kill)"))
                saved.runInProgress = nil
            }
            report = saved
        } else {
            report = Report(device: Self.deviceModel, system: Self.systemVersion,
                            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, started: Date())
        }
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        startMonitor()
        save()
    }

    // MARK: Models

    func isInstalled(_ kind: SA3ModelKind) -> Bool { directory.isReady(kind) }

    var bytesOnDisk: Int64 { directory.bytesOnDisk() }

    func install(_ kind: SA3ModelKind) {
        run("install \(kind.rawValue)") { try await $0.installBody(kind) }
    }

    private func installBody(_ kind: SA3ModelKind) async throws {
        let lab = self
        do {
            let files = SA3Manifest.shared + [SA3Manifest.dit(kind)]
            let total = Double(files.reduce(0) { $0 + $1.bytes })
            var done = 0.0
            let start = Date()
            for file in files {
                if lab.directory.isReady(kind) { break }
                let alreadyConverted = lab.alreadyConverted(file, kind: kind)
                if !alreadyConverted {
                    lab.status = "Downloading \(file.fileName)"
                    _ = try await LabDownloader.download(file, into: lab.downloads) { fraction in
                        Task { @MainActor in lab.downloadProgress = (done + fraction * Double(file.bytes)) / total }
                    }
                }
                done += Double(file.bytes)
                lab.downloadProgress = done / total
            }
            let downloaded = Date().timeIntervalSince(start)
            lab.status = "Converting"
            let convertStart = Date()
            let sampler = PeakFootprintSampler()
            sampler.start()
            let directory = lab.directory
            let downloads = lab.downloads
            try await Task.detached(priority: .utility) {
                try SA3Installer.prepare(kinds: [kind], downloads: downloads, directory: directory, deleteArchives: true)
            }.value
            let peak = sampler.stop()
            lab.downloadProgress = nil
            lab.append(Entry(test: "install-\(kind.rawValue)",
                             note: String(format: "download %.0f s, convert %.1f s, convert peak footprint %@, on disk %@",
                                          downloaded, Date().timeIntervalSince(convertStart),
                                          Self.bytes(peak), Self.bytes(lab.bytesOnDisk))))
        }
    }

    private func alreadyConverted(_ file: SA3RemoteFile, kind: SA3ModelKind) -> Bool {
        let fm = FileManager.default
        switch file {
        case SA3Manifest.t5: return fm.fileExists(atPath: directory.t5.path)
        case SA3Manifest.decoder: return fm.fileExists(atPath: directory.decoder.path)
        case SA3Manifest.dit(kind): return fm.fileExists(atPath: directory.dit(kind).path)
        case SA3Manifest.tokenizer: return fm.fileExists(atPath: directory.tokenizer.path)
        default: return fm.fileExists(atPath: directory.root.appendingPathComponent(file.fileName).path)
        }
    }

    func remove(_ kind: SA3ModelKind) {
        Task { await engine?.unloadAll() }
        engine = nil
        SA3Installer.remove(kind, from: directory)
        try? FileManager.default.createDirectory(at: directory.root, withIntermediateDirectories: true)
        status = "Removed \(kind.displayName)"
    }

    // MARK: Tests

    /// Load, generation time and memory for several durations, step counts and
    /// residencies. Every result is saved as it arrives.
    func runSuite() {
        run("suite") { try await $0.suiteBody() }
    }

    private func suiteBody() async throws {
        let lab = self
        do {
            for kind in SA3ModelKind.allCases where lab.isInstalled(kind) {
                let prompt = kind == .music
                    ? "Melancholic instrumental piano, soft cello, slow tempo, no vocals."
                    : "Heavy rain on windows, distant thunder, no music or voices."
                var durations: [Float] = [5, 10, 30, 60]
                if lab.includeLongClips { durations.append(120) }
                for seconds in durations {
                    try await lab.generate("staged-8", kind: kind, prompt: prompt, seconds: seconds, steps: 8, residency: .staged)
                }
                for seconds: Float in [10, 30] {
                    try await lab.generate("staged-4", kind: kind, prompt: prompt, seconds: seconds, steps: 4, residency: .staged)
                }
                for index in 0 ..< 3 {
                    try await lab.generate("resident-\(index)", kind: kind, prompt: prompt, seconds: 10, steps: 8, residency: .resident)
                }
                await lab.engine?.unloadAll()
            }
        }
    }

    /// Back-to-back 30 s clips for `sustainedMinutes`: generation time drift, thermal
    /// state and battery level over time. Run it unplugged for battery figures.
    func runSustained() {
        run("sustained") { try await $0.sustainedBody() }
    }

    private func sustainedBody() async throws {
        let lab = self
        do {
            let kind: SA3ModelKind = lab.isInstalled(.music) ? .music : .sfx
            let end = Date().addingTimeInterval(lab.sustainedMinutes * 60)
            var index = 0
            while Date() < end {
                try Task.checkCancellation()
                try await lab.generate("sustained-\(index)", kind: kind,
                                       prompt: "Calm ambient pads, warm strings, slow, no vocals.",
                                       seconds: 30, steps: 8, residency: .resident, keepFile: index == 0)
                index += 1
            }
            await lab.engine?.unloadAll()
        }
    }

    /// Baseline for the sustained test: the same screen-on time with nothing generated,
    /// logging battery and thermal state every minute.
    private func idleBody() async throws {
        await engine?.unloadAll()
        let minutes = Int(sustainedMinutes.rounded())
        for minute in 0 ... minutes {
            if minute > 0 { try await Task.sleep(for: .seconds(60)) }
            status = "Idle baseline \(minute)/\(minutes) min"
            append(Entry(test: "idle-\(minute)", note: "thermal \(ThermalStateName.current), footprint \(Self.bytes(ProcessMemory.footprint()))"))
        }
    }

    /// Generates while narration plays and counts narration stalls (playing but waiting
    /// for an uncached sentence) before, during and after; then plays the loop on the
    /// Immersive Audio engine under narration.
    func runCoexistence(kind: SA3ModelKind) {
        run("coexistence") { try await $0.coexistenceBody(kind: kind, long: false) }
    }

    /// Phases: voice only (reference) → generation while the voice plays → voice plus the
    /// generated loop on the Immersive Audio engine → (long) voice only again, loop stopped.
    /// Each phase records how often and how long narration waited for a sentence.
    private func coexistenceBody(kind: SA3ModelKind, long: Bool) async throws {
        guard let playback, playback.isPlaying else {
            status = "Start narration on an uncached part of a book first"
            append(Entry(test: "coexistence-skipped", note: "narration was not playing"))
            return
        }
        let reference: Double = long ? 60 : 30
        let together: Double = long ? 120 : 60
        func phase(_ name: String, seconds: Double, label: String) async throws {
            resetStalls()
            status = label
            event("phase \(name) begins")
            try await Task.sleep(for: .seconds(seconds))
            append(Entry(test: name, note: "stalls \(narrationStallCount), \(String(format: "%.1f", narrationStallSeconds)) s in \(Int(seconds)) s; footprint \(Self.bytes(ProcessMemory.footprint()))"))
        }
        try await phase("coexistence-baseline", seconds: reference, label: "1/3 Voice only, reference (\(Int(reference)) s): no music yet")

        resetStalls()
        status = "2/3 Generating \(kind.rawValue) while the voice plays"
        let start = Date()
        let file = try await generate("coexistence-generate", kind: kind,
                                      prompt: kind == .music
                                          ? "Mysterious instrumental, soft harp, low strings, slow, no vocals."
                                          : "Night forest, gentle wind, distant owls, no music or voices.",
                                      seconds: 30, steps: 8, residency: .staged)
        let during = Date().timeIntervalSince(start)
        append(Entry(test: "coexistence-during", note: "stalls \(narrationStallCount), \(String(format: "%.1f", narrationStallSeconds)) s in \(String(format: "%.0f", during)) s of generation"))

        guard let file else { return }
        play(file, layer: kind == .music ? .music : .ambience)
        try await phase("coexistence-playback", seconds: together,
                        label: "3/3 Voice + generated loop (\(Int(together)) s): \(kind.rawValue) is playing under the voice")
        if long {
            stopPlayback()
            try await phase("coexistence-after", seconds: reference, label: "Voice only again, loop stopped (\(Int(reference)) s)")
        }
    }

    /// The shipping AI soundscape path, end to end on a device: Settings choices, model
    /// download and conversion through `SoundscapeModels`, narration, the book's pack
    /// through the controller (SA3Generator with continuation, quality gate, AAC) and
    /// playback. Logs every piece, the generation status, memory and heat.
    private func aiEndToEnd() async throws {
        guard let immersive else {
            append(Entry(test: "ai-e2e-skipped", note: "no controller"))
            return
        }
        immersive.preferences.source = .ai
        if !immersive.preferences.isEnabled { immersive.setEnabled(true) }
        let models = immersive.soundscapeModels
        let installStart = Date()
        if !(models.isInstalled(.music) && models.isInstalled(.sfx)) {
            models.install([.music, .sfx])
            var last = ""
            while Date().timeIntervalSince(installStart) < 1_800 {
                try await Task.sleep(for: .seconds(2))
                let state = "\(models.state[.music].map { "\($0)" } ?? "-") / \(models.state[.sfx].map { "\($0)" } ?? "-")"
                if state != last, !state.contains("downloading") || Int(Date().timeIntervalSince(installStart)) % 20 == 0 {
                    event("models: \(state)")
                    last = state
                }
                if models.isInstalled(.music) && models.isInstalled(.sfx) { break }
                if case .failed = models.state[.music] { break }
            }
        }
        append(Entry(test: "ai-e2e-install", note: String(format: "music %@, sfx %@, %.0f s, on disk %@",
                                                         models.isInstalled(.music) ? "installed" : "missing",
                                                         models.isInstalled(.sfx) ? "installed" : "missing",
                                                         Date().timeIntervalSince(installStart), Self.bytes(models.bytesOnDisk))))
        guard models.isInstalled(.music) else { return }
        try await startNarration()
        try await Task.sleep(for: .seconds(5))
        let before = immersive.generated.pieces.count
        let start = Date()
        immersive.prepareSoundscapes()
        append(Entry(test: "ai-e2e-prepare", note: "status \(immersive.generation), style \(immersive.bookStyle.rawValue)"))
        var seen = Set(immersive.generated.pieces.map(\.id))
        var lastStatus = ""
        while Date().timeIntervalSince(start) < 1_800 {
            try await Task.sleep(for: .seconds(1))
            let status = "\(immersive.generation)"
            if status != lastStatus {
                event("generation: \(status)")
                lastStatus = status
            }
            for piece in immersive.generated.pieces where !seen.contains(piece.id) {
                seen.insert(piece.id)
                append(Entry(test: "ai-e2e-piece", note: String(format: "%@ %@ %@, %.1f s, %.1f LUFS, %.1f dBTP, tail %@, after %.0f s, footprint %@, %@",
                                                              piece.layer.rawValue, piece.mood?.rawValue ?? piece.bed?.rawValue ?? "-",
                                                              piece.style.rawValue, Double(piece.frames) / Double(piece.sampleRate),
                                                              piece.lufs, piece.truePeak, piece.tailStart.map { String(format: "%.0f", $0) } ?? "-",
                                                              Date().timeIntervalSince(start), Self.bytes(ProcessMemory.footprint()),
                                                              ThermalStateName.current)))
                if let url = immersive.generated.url(for: piece.track) {
                    try? FileManager.default.copyItem(at: url, to: output.appendingPathComponent("ai-\(piece.mood?.rawValue ?? piece.bed?.rawValue ?? "x")-\(piece.id.prefix(6)).m4a"))
                }
            }
            if case .idle = immersive.generation, Date().timeIntervalSince(start) > 10 { break }
            if case .paused = immersive.generation { break }
        }
        let playing = [immersive.musicTrack, immersive.ambienceTrack].compactMap { $0 }
            .map { "\($0.layer.rawValue): \($0.semantics.origin ?? "catalog") \($0.id.prefix(8))" }.joined(separator: ", ")
        append(Entry(test: "ai-e2e-done", note: String(format: "%d new pieces in %.0f s; now playing %@; status %@; stalls %d / %.1f s",
                                                      immersive.generated.pieces.count - before, Date().timeIntervalSince(start),
                                                      playing.isEmpty ? "nothing" : playing, "\(immersive.generation)",
                                                      narrationStallCount, narrationStallSeconds)))
    }

    /// Installs both models through the app's own path (download, verify, convert).
    private func installAIModels() async throws {
        for _ in 0 ..< 80 where immersive == nil { try await Task.sleep(for: .milliseconds(250)) }
        guard let models = immersive?.soundscapeModels else { return }
        let start = Date()
        if !(models.isInstalled(.music) && models.isInstalled(.sfx)) {
            models.install([.music, .sfx])
            var last = ""
            while Date().timeIntervalSince(start) < 1_800 {
                try await Task.sleep(for: .seconds(2))
                let state = "\(models.state[.music].map { "\($0)" } ?? "-") / \(models.state[.sfx].map { "\($0)" } ?? "-")"
                if state.prefix(12) != last.prefix(12) { event("models: \(state)"); last = state }
                if models.isInstalled(.music) && models.isInstalled(.sfx) { break }
                if case .failed = models.state[.music] { break }
            }
        }
        append(Entry(test: "install-ai", note: String(format: "music %@, sfx %@, %.0f s",
                                                     models.isInstalled(.music) ? "installed" : "missing",
                                                     models.isInstalled(.sfx) ? "installed" : "missing",
                                                     Date().timeIntervalSince(start))))
    }

    /// As a reader would: delete both models, download Music, ask for Ambience two seconds
    /// later (it must queue, not be refused) and wait until both are installed.
    private func queuedInstall() async throws {
        for _ in 0 ..< 80 where immersive == nil { try await Task.sleep(for: .milliseconds(250)) }
        guard let models = immersive?.soundscapeModels else { return }
        models.remove(.music)
        models.remove(.sfx)
        let start = Date()
        models.install([.music])
        try await Task.sleep(for: .seconds(2))
        models.install([.sfx])
        event("after asking for Ambience: music \(models.state[.music].map { "\($0)" } ?? "-"), queued \(models.installQueue.queued.map(\.rawValue))")
        var last = ""
        while Date().timeIntervalSince(start) < 1_800 {
            try await Task.sleep(for: .seconds(2))
            let state = "\(models.state[.music].map { "\($0)" } ?? "-") / \(models.state[.sfx].map { "\($0)" } ?? "-") queued \(models.installQueue.queued.map(\.rawValue))"
            if state.prefix(30) != last.prefix(30) { event("models: \(state)"); last = state }
            if models.isInstalled(.music) && models.isInstalled(.sfx) { break }
            if case .failed = models.state[.sfx] { break }
        }
        append(Entry(test: "queue-install", note: String(format: "music %@, sfx %@, %.0f s",
                                                        models.isInstalled(.music) ? "installed" : "missing",
                                                        models.isInstalled(.sfx) ? "installed" : "missing",
                                                        Date().timeIntervalSince(start))))
    }

    /// Imports every EPUB copied into Documents/SoundscapeLab (duplicates are skipped).
    private func importBooks() async throws {
        for _ in 0 ..< 80 where library == nil { try await Task.sleep(for: .milliseconds(250)) }
        guard let library else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "epub" } ?? []
        _ = await library.importFiles(files, progress: { _ in })
        event("library: " + library.allBooks().map { "\($0.title) [\($0.language)]" }.joined(separator: ", "))
    }

    /// Installs Phonon 31M (English) as a reader would from Models, and selects it.
    private func installPhonon() async throws {
        for _ in 0 ..< 80 where playback == nil { try await Task.sleep(for: .milliseconds(250)) }
        guard let models = playback?.models,
              let model = models.models.first(where: { $0.id == "phonon-31m-en" }) else { return }
        let start = Date()
        if !models.isInstalled(model) {
            models.install(model)
            while Date().timeIntervalSince(start) < 900, !models.isInstalled(model) {
                try await Task.sleep(for: .seconds(2))
                if case .failed(let message) = models.state(for: model) { event("phonon failed: \(message)"); break }
            }
        }
        models.selectModel(model)
        append(Entry(test: "install-phonon", note: String(format: "%@ in %.0f s", models.isInstalled(model) ? "installed" : "missing",
                                                         Date().timeIntervalSince(start))))
    }

    /// Voice only (30 s), then a three-piece session composed while the voice plays,
    /// then voice only again (30 s); stalls are counted in each phase.
    private func narrateWhileComposing() async throws {
        guard let playback, playback.isPlaying, let immersive, let book = playback.activeBook else {
            append(Entry(test: "narrate-compose-skipped", note: "narration was not playing"))
            return
        }
        immersive.preferences.source = .ai
        if !immersive.preferences.isEnabled { immersive.setEnabled(true) }
        func phase(_ name: String, seconds: Double) async throws {
            resetStalls()
            try await Task.sleep(for: .seconds(seconds))
            append(Entry(test: name, note: "stalls \(narrationStallCount), \(String(format: "%.1f", narrationStallSeconds)) s in \(Int(seconds)) s"))
        }
        // Every 5 s, what the narration has ready (to see why it stalls).
        let probe = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let playback = self.playback else { return }
                self.event(String(format: "buffer %.0f s; ", playback.narrationBufferedAhead ?? -1) + playback.prefetchDescription)
            }
        }
        defer { probe.cancel() }
        try await phase("voice-only", seconds: 30)
        resetStalls()
        let start = Date()
        GenerationWorker.trace = { [weak self] line in Task { @MainActor in self?.event(line) } }
        immersive.prepareSession(for: book, count: 3)
        while Date().timeIntervalSince(start) < 300 {
            try await Task.sleep(for: .milliseconds(500))
            if case .preparing = immersive.generation { continue }
            if Date().timeIntervalSince(start) > 3 { break }
        }
        immersive.sessionStarted()
        GenerationWorker.trace = nil
        append(Entry(test: "voice-while-composing", note: String(format: "stalls %d, %.1f s in %.0f s of composing",
                                                                narrationStallCount, narrationStallSeconds, Date().timeIntervalSince(start))))
        try await phase("voice-after", seconds: 30)
    }

    /// The app's own session path: `prepareSession` for the last opened book with the
    /// voice waiting, timing every stage (worker trace) until the pack is done.
    private func sessionBody(count: Int) async throws {
        // The autorun starts with the app: wait for the controller and the library.
        for _ in 0 ..< 80 where immersive == nil || (library?.allBooks().isEmpty ?? true) {
            try await Task.sleep(for: .milliseconds(250))
        }
        // An empty lab library: import the EPUB copied into Documents/SoundscapeLab.
        if let library, library.allBooks().isEmpty {
            let epub = output.appendingPathComponent("book.epub")
            if FileManager.default.fileExists(atPath: epub.path) {
                _ = await library.importFiles([epub], progress: { _ in })
                event("imported book.epub: \(library.allBooks().count) books")
            }
        }
        guard let immersive, let book = library?.continueBook() ?? library?.allBooks().first else {
            append(Entry(test: "session-skipped", note: "controller \(immersive != nil), books \(library?.allBooks().count ?? -1)"))
            return
        }
        immersive.preferences.source = .ai
        if !immersive.preferences.isEnabled { immersive.setEnabled(true) }
        guard immersive.soundscapeModels.isInstalled(.music) else {
            append(Entry(test: "session-skipped", note: "music model not installed"))
            return
        }
        let start = Date()
        GenerationWorker.trace = { [weak self] line in
            Task { @MainActor in self?.event(String(format: "[%.1f s] ", Date().timeIntervalSince(start)) + line) }
        }
        defer { GenerationWorker.trace = nil }
        let before = Set(immersive.generated.pieces.map(\.id))
        // As in the app: the sheet warms the composer while the reader chooses (~5 s).
        immersive.prewarmSoundscapes()
        try await Task.sleep(for: .seconds(5))
        event("chose \(count) pieces")
        let chosen = Date()
        immersive.prepareSession(for: book, count: count)
        var firstPiece: Double?
        var seen = before
        while Date().timeIntervalSince(start) < 600 {
            try await Task.sleep(for: .milliseconds(250))
            for piece in immersive.generated.pieces where !seen.contains(piece.id) {
                seen.insert(piece.id)
                let at = Date().timeIntervalSince(chosen)
                if firstPiece == nil { firstPiece = at }
                append(Entry(test: "session-piece", note: String(format: "%@ %@ %.0f s long, ready after %.1f s, footprint %@, %@",
                                                                piece.layer.rawValue, piece.mood?.rawValue ?? piece.bed?.rawValue ?? "-",
                                                                Double(piece.frames) / Double(piece.sampleRate), at,
                                                                Self.bytes(ProcessMemory.footprint()), ThermalStateName.current)))
            }
            if case .preparing = immersive.generation { continue }
            if Date().timeIntervalSince(start) > 3 { break }
        }
        immersive.sessionStarted()
        append(Entry(test: "session-done", note: String(format: "%d pieces, first after %.1f s, all after %.1f s, %@",
                                                       seen.count - before.count, firstPiece ?? -1,
                                                       Date().timeIntervalSince(chosen), ThermalStateName.current)))
    }

    /// Resumes the most recently opened book with narration and waits until it plays.
    private func startNarration(language: String? = nil) async throws {
        if let language, let book = library?.allBooks().first(where: { $0.language.hasPrefix(language) }) {
            book.lastOpenedAt = Date()
        }
        guard let playback, let book = library?.continueBook() else {
            append(Entry(test: "narrate-skipped", note: "no opened book or no playback controller"))
            return
        }
        event("starting narration of \(book.title)")
        await playback.start(book: book, mode: .listen)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !(playback.isPlaying && !playback.isLoading) {
            try await Task.sleep(for: .milliseconds(250))
        }
        append(Entry(test: "narrate", note: playback.isPlaying ? "playing \(book.title), \(sentenceDescription)" : "narration did not start"))
    }

    /// `-SoundscapeLabAutorun install-music,install-sfx,suite,sustained,idle` runs those steps
    /// at launch (for unattended device runs); `-SoundscapeLabMinutes 10` sets the
    /// sustained length and `-SoundscapeLabLong` adds 120 s clips.
    func autorunIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SoundscapeLabAutorun"), index + 1 < arguments.count else { return }
        let steps = arguments[index + 1].split(separator: ",").map(String.init)
        if let m = arguments.firstIndex(of: "-SoundscapeLabMinutes"), m + 1 < arguments.count, let value = Double(arguments[m + 1]) {
            sustainedMinutes = value
        }
        includeLongClips = arguments.contains("-SoundscapeLabLong")
        run("autorun") { lab in
            lab.append(Entry(test: "autorun", note: steps.joined(separator: ",")))
            for step in steps {
                switch step {
                case "install-music": try await lab.installBody(.music)
                case "install-sfx": try await lab.installBody(.sfx)
                case "suite": try await lab.suiteBody()
                case "sustained": try await lab.sustainedBody()
                case "idle": try await lab.idleBody()
                case "narrate": try await lab.startNarration()
                case "coexist-music": try await lab.coexistenceBody(kind: .music, long: true)
                case "coexist-sfx": try await lab.coexistenceBody(kind: .sfx, long: true)
                case "stop-narration": lab.playback?.pause(); lab.stopPlayback()
                case "ai-e2e": try await lab.aiEndToEnd()
                case "install-ai": try await lab.installAIModels()
                case "import-books": try await lab.importBooks()
                case "install-phonon": try await lab.installPhonon()
                case "narrate-en": try await lab.startNarration(language: "en")
                case "narrate-compose": try await lab.narrateWhileComposing()
                case "queue-install": try await lab.queuedInstall()
                case "session1": try await lab.sessionBody(count: 1)
                case "session3": try await lab.sessionBody(count: 3)
                default: lab.append(Entry(test: "autorun", note: "unknown step \(step)"))
                }
            }
            lab.append(Entry(test: "autorun-finished"))
        }
    }

    func cancel() {
        task?.cancel()
        status = "Cancelling…"
    }

    func clearReport() {
        report = Report(device: Self.deviceModel, system: Self.systemVersion,
                        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, started: Date())
        save()
    }

    // MARK: Playback

    func play(_ url: URL, layer: ImmersiveAudioEngine.Layer) {
        let engine = player ?? ImmersiveAudioEngine()
        player = engine
        AudioSessionCoordinator.shared.claim(.immersive)
        engine.setVolume(.music, slider: musicVolume, duration: 0)
        engine.setVolume(.ambience, slider: ambienceVolume, duration: 0)
        engine.setNarrationAudible(playback?.isPlaying == true)
        engine.start(fadeIn: 1)
        engine.play(.init(id: url.lastPathComponent, url: url, layer: layer, loop: true), crossfade: 3)
        nowPlaying = "\(layer.rawValue): \(url.deletingPathExtension().lastPathComponent)"
        event("lab engine plays \(url.lastPathComponent) on \(layer.rawValue); engine \(ObjectIdentifier(engine))")
    }

    func stopPlayback() {
        player?.stop(.music, fadeOut: 1)
        player?.stop(.ambience, fadeOut: 1)
        nowPlaying = nil
    }

    var generatedLoops: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-loop.wav") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Internals

    @discardableResult
    private func generate(_ test: String, kind: SA3ModelKind, prompt: String, seconds: Float, steps: Int,
                          residency: SA3Engine.Residency, keepFile: Bool = true) async throws -> URL? {
        try Task.checkCancellation()
        let engine = self.engine ?? SA3Engine(directory: directory, residency: residency, cacheLimitBytes: 64 << 20)
        self.engine = engine
        await engine.setResidency(residency)
        let name = "\(kind.rawValue)-\(test)-\(Int(seconds))s-\(steps)st"
        report.runInProgress = name
        save()
        status = "Generating \(name)"
        event("generation starts: \(name)")
        let output = try await Task.detached(priority: .userInitiated) {
            try await engine.generate(.init(kind: kind, prompt: prompt, seconds: seconds, steps: steps)) { stage in
                Task { @MainActor in SoundscapeLab.shared.status = "\(name): \(stage)" }
            }
        }.value
        report.runInProgress = nil
        let levels = SA3Audio.levels(output.channels, sampleRate: output.sampleRate)
        var entry = Entry(test: test, measurement: output.measurement,
                          peakDB: levels.peakDB, rmsDB: levels.rmsDB, oneSecondRMSSpreadDB: levels.oneSecondRMSSpreadDB)
        var loopURL: URL?
        if keepFile {
            let url = self.output.appendingPathComponent(name + ".wav")
            try SA3Audio.writeWAV(output.channels, sampleRate: output.sampleRate, to: url)
            entry.file = url.lastPathComponent
            if let looped = SA3Audio.loop(output.channels, sampleRate: output.sampleRate, seam: 2) {
                // Same targets as the catalog pipeline: music −20 LUFS / −1.5 dBTP,
                // ambience −28 LUFS / −3 dBTP, one fixed gain.
                let levelStart = Date()
                let target = kind == .music ? (-20.0, -1.5) : (-28.0, -3.0)
                let rate = output.sampleRate
                let leveled = await Task.detached(priority: .userInitiated) {
                    SA3Audio.level(looped, sampleRate: rate, targetLUFS: target.0, ceilingDBTP: target.1)
                }.value
                entry.note = String(format: "loop levelled %+.1f dB to %.1f LUFS, %.1f dBTP in %.2f s",
                                    leveled.gainDB, leveled.loudness, leveled.truePeak, Date().timeIntervalSince(levelStart))
                let loop = self.output.appendingPathComponent(name + "-loop.wav")
                try SA3Audio.writeWAV(leveled.channels, sampleRate: output.sampleRate, to: loop)
                entry.loopFile = loop.lastPathComponent
                loopURL = loop
            }
        }
        append(entry)
        return loopURL
    }

    private func run(_ name: String, _ body: @escaping @MainActor (SoundscapeLab) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        status = "Running \(name)"
        #if canImport(UIKit)
        // A locked phone suspends the app mid-download or mid-measurement.
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self)
                if self.status.hasPrefix("Running") || self.status.hasPrefix("Generating") || self.status.contains(":") {
                    self.status = "Finished \(name)"
                }
            } catch is CancellationError {
                self.status = "Cancelled \(name)"
            } catch {
                self.status = "\(name) failed: \(error)"
                self.append(Entry(test: "\(name)-error", note: "\(error)"))
            }
            self.report.runInProgress = nil
            self.downloadProgress = nil
            self.isBusy = false
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            self.save()
        }
    }

    private func append(_ entry: Entry) {
        event("entry \(entry.test)\(entry.note.map { ": " + $0 } ?? "")")
        var entry = entry
        #if canImport(UIKit)
        entry.batteryLevel = UIDevice.current.batteryLevel
        entry.batteryState = switch UIDevice.current.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        #endif
        #if os(iOS)
        entry.availableMemoryBytes = Int64(os_proc_available_memory())
        #endif
        report.entries.append(entry)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder.lab.encode(report) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    private func resetStalls() {
        narrationStallCount = 0
        narrationStallSeconds = 0
    }

    private func startMonitor() {
        observeSystemEvents()
        monitor = Task { [weak self] in
            var wasStalled = false
            var stallStart = Date()
            var wasPlaying = false
            var lastThermal = ThermalStateName.current
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.liveFootprint = ProcessMemory.footprint()
                self.liveThermal = ThermalStateName.current
                if self.liveThermal != lastThermal {
                    self.event("thermal \(lastThermal) → \(self.liveThermal)")
                    lastThermal = self.liveThermal
                }
                let playing = self.playback?.isPlaying ?? false
                if playing != wasPlaying {
                    self.event(playing ? "narration playing" : "narration stopped (paused or ended)")
                    wasPlaying = playing
                }
                let stalled = playing && (self.playback?.isLoading ?? false)
                if stalled {
                    self.narrationStallSeconds += 0.1
                    if !wasStalled {
                        self.narrationStallCount += 1
                        stallStart = Date()
                        self.event("stall begins at \(self.sentenceDescription); \(self.playback?.prefetchDescription ?? "")")
                    }
                } else if wasStalled {
                    self.event(String(format: "stall ends after %.1f s", Date().timeIntervalSince(stallStart)))
                }
                wasStalled = stalled
            }
        }
    }

    private var sentenceDescription: String {
        guard let playback, playback.sentences.indices.contains(playback.currentIndex) else { return "no sentence" }
        return "sentence \(playback.currentIndex) (\((playback.sentences[playback.currentIndex].text as NSString).length) chars)"
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private lazy var eventsURL = output.appendingPathComponent("events.log")

    /// Appends a timestamped line to Documents/SoundscapeLab/events.log.
    func event(_ text: String) {
        let line = "\(ISO8601DateFormatter.lab.string(from: Date())) [\(status)] footprint \(Self.bytes(ProcessMemory.footprint())): \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: eventsURL)
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ describe: @escaping @Sendable (Notification) -> String) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let text = describe(notification)
                Task { @MainActor in SoundscapeLab.shared.event(text) }
            })
        }
        #if canImport(UIKit)
        observe(UIApplication.didReceiveMemoryWarningNotification) { _ in "memory warning" }
        observe(UIApplication.didEnterBackgroundNotification) { _ in "app entered background" }
        observe(UIApplication.willEnterForegroundNotification) { _ in "app entering foreground" }
        #endif
        #if os(iOS)
        observe(AVAudioSession.interruptionNotification) { n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == 1 ? "began" : "ended"
            let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            return "audio session interruption \(type), reason \(reason.map(String.init) ?? "none")"
        }
        observe(AVAudioSession.routeChangeNotification) { n in
            "route change, reason \((n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "?")"
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in "media services reset" }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification) { n in
            "silence secondary audio hint \((n.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt).map(String.init) ?? "?")"
        }
        #endif
        observe(.AVAudioEngineConfigurationChange) { n in
            "AVAudioEngine configuration change on \(n.object.map { String(describing: ObjectIdentifier($0 as AnyObject)) } ?? "?")"
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}

extension ISO8601DateFormatter {
    static let lab: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()
}

extension JSONEncoder {
    static var lab: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var lab: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A download with progress, verified against the pinned size and SHA-256.
enum LabDownloader {
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        let destination: URL

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            do {
                guard code == 200 else { throw SA3Installer.InstallError.badResponse(destination.lastPathComponent, code) }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                continuation?.resume(returning: destination)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    static func download(_ file: SA3RemoteFile, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.fileName)
        if (try? SA3Installer.verify(destination, against: file)) != nil { return destination }
        let delegate = Delegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                delegate.continuation = continuation
                session.downloadTask(with: SA3Manifest.url(file)).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        try SA3Installer.verify(url, against: file)
        return url
    }
}
#endif
