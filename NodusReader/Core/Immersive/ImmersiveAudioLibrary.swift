// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Observation

/// Downloaded Immersive Audio packs on this device: install, pause, delete,
/// and which moods and beds can play. Files live in
/// `<storage>/ImmersiveAudio/`, excluded from backups and never synced.
/// Every file is checked against the manifest's size and SHA-256 before it
/// is used; a download tries each host in order (Hugging Face, then the
/// GitHub Release mirror).
@MainActor
@Observable
final class ImmersiveAudioLibrary {
    enum PackState: Equatable, Sendable {
        case notInstalled
        case downloading(Double)
        case paused(Double)
        case installed
        case failed(String)
    }

    enum LibraryError: LocalizedError {
        case unavailable
        case integrity(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "The atmosphere sounds could not be downloaded. Check the connection and try again.")
            case .integrity(let name):
                String(localized: "\(name) did not match the published file and was discarded.")
            case .http(let code):
                String(localized: "The download server answered with error \(code).")
            }
        }
    }

    let catalog: ImmersiveCatalog?
    let root: URL
    private(set) var states: [String: PackState] = [:]
    private(set) var installedTrackIDs: Set<String> = [] {
        didSet { if oldValue != installedTrackIDs { onInstalledChanged?() } }
    }
    /// Called when the playable files change (a pack finished or was deleted).
    @ObservationIgnored var onInstalledChanged: (() -> Void)?
    private(set) var bytesOnDisk: Int64 = 0
    /// A test or development pack stands in for the catalog (DEBUG only).
    let isDevelopmentPack: Bool
    @ObservationIgnored private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    init(catalog: ImmersiveCatalog? = ImmersiveCatalog.bundled(), fileStore: FileStore = .shared) {
        var catalog = catalog
        var root = fileStore.root.appendingPathComponent("ImmersiveAudio", isDirectory: true)
        var development = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-NodusImmersiveTestPack") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImmersiveTestPack", isDirectory: true)
            catalog = ImmersiveTestPack.make(in: folder)
            root = folder
            development = true
        } else if let index = arguments.firstIndex(of: "-NodusImmersiveAudioPackRoot"), index + 1 < arguments.count {
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            development = true
        }
        #endif
        self.catalog = catalog
        self.root = root
        self.isDevelopmentPack = development
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        refresh()
        // Files that finished downloading while the app was in the background
        // or not running are installed by the session; show them.
        ImmersiveDownloadSession.shared.reconnect()
        finishedObserver = NotificationCenter.default.addObserver(
            forName: .immersiveDownloadFinished, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @ObservationIgnored private var finishedObserver: NSObjectProtocol?

    // MARK: Queries

    var packs: [ImmersiveCatalog.Pack] { catalog?.packs ?? [] }

    func state(_ pack: ImmersiveCatalog.Pack) -> PackState { states[pack.id] ?? .notInstalled }

    func url(for track: CatalogTrack) -> URL? {
        guard installedTrackIDs.contains(track.id) else { return nil }
        return root.appendingPathComponent(track.file.path)
    }

    var installedTracks: [CatalogTrack] {
        (catalog?.tracks ?? []).filter { installedTrackIDs.contains($0.id) }
    }

    var installedMoods: Set<MusicMood> {
        Set(installedTracks.filter { $0.layer == .music }.flatMap(\.moods))
    }

    var installedBeds: Set<BaseAmbience> {
        Set(installedTracks.compactMap(\.bed))
    }

    var hasAnything: Bool { !installedTrackIDs.isEmpty }

    func musicTracks(_ mood: MusicMood) -> [CatalogTrack] {
        installedTracks.filter { $0.layer == .music && $0.moods.contains(mood) }
    }

    func ambienceTracks(_ bed: BaseAmbience) -> [CatalogTrack] {
        installedTracks.filter { $0.layer == .ambience && $0.bed == bed }
    }

    /// Re-reads what is on disk. A file counts once its size matches the
    /// manifest (its hash was checked when it was downloaded).
    func refresh() {
        guard let catalog else { return }
        var installed = Set<String>()
        for track in catalog.tracks {
            let url = root.appendingPathComponent(track.file.path)
            if FileStore.fileSize(at: url) == track.file.bytes { installed.insert(track.id) }
        }
        installedTrackIDs = installed
        for pack in catalog.packs where tasks[pack.id] == nil {
            let all = pack.trackIDs.allSatisfy(installed.contains)
            let some = pack.trackIDs.contains(where: installed.contains)
            if all { states[pack.id] = .installed }
            else if case .failed = states[pack.id] { continue }
            else { states[pack.id] = some ? .paused(fraction(of: pack, installed: installed)) : .notInstalled }
        }
        bytesOnDisk = FileStore.directorySize(root, fileManager: .default)
    }

    private func fraction(of pack: ImmersiveCatalog.Pack, installed: Set<String>) -> Double {
        let total = max(Double(pack.bytes), 1)
        let done = Double((catalog?.tracks(in: pack) ?? []).filter { installed.contains($0.id) }.reduce(0) { $0 + $1.file.bytes })
        return min(done / total, 1)
    }

    // MARK: Install, pause, delete

    func install(_ pack: ImmersiveCatalog.Pack) {
        guard tasks[pack.id] == nil, let catalog else { return }
        let token = UUID()
        let tracks = catalog.tracks(in: pack).filter { !installedTrackIDs.contains($0.id) }
        states[pack.id] = .downloading(fraction(of: pack, installed: installedTrackIDs))
        let root = self.root
        let total = max(Double(pack.bytes), 1)
        let task = Task { [weak self] in
            do {
                // Every file is queued at once in the background session, so
                // the whole pack keeps downloading while the app is suspended.
                try await withThrowingTaskGroup(of: String.self) { group in
                    for track in tracks {
                        let urls = catalog.urls(for: track)
                        group.addTask {
                            try await Self.download(track, urls: urls, into: root) { fraction in
                                Task { @MainActor [weak self] in
                                    self?.progressed(pack, token: token, track: track, fraction: fraction, total: total)
                                }
                            }
                            return track.id
                        }
                    }
                    for try await id in group {
                        guard let self, self.tasks[pack.id]?.token == token else { return }
                        self.partial[pack.id]?[id] = nil
                        self.installedTrackIDs.insert(id)
                        self.states[pack.id] = .downloading(self.fraction(of: pack, installed: self.installedTrackIDs))
                        self.bytesOnDisk = FileStore.directorySize(root, fileManager: .default)
                    }
                }
                guard let self, self.tasks[pack.id]?.token == token else { return }
                self.tasks[pack.id] = nil
                self.partial[pack.id] = nil
                self.refresh()
            } catch is CancellationError {
                guard let self, self.tasks[pack.id]?.token == token else { return }
                self.tasks[pack.id] = nil
                self.states[pack.id] = .paused(self.fraction(of: pack, installed: self.installedTrackIDs))
            } catch {
                guard let self, self.tasks[pack.id]?.token == token else { return }
                self.tasks[pack.id] = nil
                self.states[pack.id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self.bytesOnDisk = FileStore.directorySize(root, fileManager: .default)
            }
        }
        tasks[pack.id] = (token, task)
    }

    /// Byte progress of files still downloading, per pack.
    @ObservationIgnored private var partial: [String: [String: Double]] = [:]

    private func progressed(_ pack: ImmersiveCatalog.Pack, token: UUID, track: CatalogTrack, fraction share: Double,
                            total: Double) {
        guard tasks[pack.id]?.token == token, !installedTrackIDs.contains(track.id) else { return }
        partial[pack.id, default: [:]][track.id] = Double(track.file.bytes) * share
        let done = fraction(of: pack, installed: installedTrackIDs)
        let value = min(done + (partial[pack.id]?.values.reduce(0, +) ?? 0) / total, 1)
        if case .downloading(let shown) = states[pack.id], value - shown < 0.005 { return }
        states[pack.id] = .downloading(value)
    }

    /// Stops a download; files already verified are kept for the resume.
    func pause(_ pack: ImmersiveCatalog.Pack) {
        tasks[pack.id]?.task.cancel()
    }

    /// Deletes a pack's files (tracks shared with another installed pack stay).
    func delete(_ pack: ImmersiveCatalog.Pack) {
        tasks[pack.id]?.task.cancel()
        tasks[pack.id] = nil
        guard let catalog else { return }
        let keep = Set(catalog.packs.filter { $0.id != pack.id && state($0) == .installed }.flatMap(\.trackIDs))
        for track in catalog.tracks(in: pack) where !keep.contains(track.id) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(track.file.path))
        }
        states[pack.id] = .notInstalled
        refresh()
    }

    func deleteAll() {
        for (_, entry) in tasks { entry.task.cancel() }
        tasks = [:]
        guard !isDevelopmentPack else { return }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        states = [:]
        refresh()
    }

    // MARK: Download

    /// Fetches one file from the first host that serves it intact.
    nonisolated static func download(_ track: CatalogTrack, urls: [URL], into root: URL,
                                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let destination = root.appendingPathComponent(track.file.path)
        let staging = root.appendingPathComponent(".partial", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !urls.isEmpty else { throw LibraryError.unavailable }
        var lastError: Error = LibraryError.unavailable
        for url in urls {
            try Task.checkCancellation()
            do {
                if !url.isFileURL {
                    // Web hosts: a background session, so the download goes on
                    // when the reader leaves the app; it verifies and installs.
                    let target = ImmersiveDownloadSession.Target(destination: destination.path, bytes: track.file.bytes,
                                                                 sha256: track.file.sha256, title: track.title)
                    try await ImmersiveDownloadSession.shared.download(url, target: target, onProgress: progress)
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                let delegate = DownloadProgress(progress)
                let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
                // A file: mirror (tests, local packs) has no HTTP status.
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    try? FileManager.default.removeItem(at: temporary)
                    throw LibraryError.http(http.statusCode)
                }
                let staged = staging.appendingPathComponent(track.file.sha256)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.moveItem(at: temporary, to: staged)
                guard FileStore.fileSize(at: staged) == track.file.bytes,
                      try ContentHash.sha256(of: staged) == track.file.sha256 else {
                    try? FileManager.default.removeItem(at: staged)
                    throw LibraryError.integrity(track.title)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staged, to: destination)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Reports a download's byte progress (0…1).
    private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?

        init(_ report: @escaping @Sendable (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
                report(progress.fractionCompleted)
            }
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

#if DEBUG
/// A tiny generated pack for UI tests and simulators without a download:
/// soft tones and filtered noise, made on the device, nothing third-party.
enum ImmersiveTestPack {
    static func make(in folder: URL) -> ImmersiveCatalog {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let specs: [(id: String, layer: CatalogTrack.Layer, moods: [String]?, base: String?, base_hz: Double)] = [
            ("test.music.calm", .music, ["calm", "contemplative", "focus"], nil, 220),
            ("test.music.mysterious", .music, ["mysterious", "eerie"], nil, 196),
            ("test.music.adventure", .music, ["adventure", "joyful"], nil, 262),
            ("test.ambience.rain", .ambience, nil, "rain", 0),
            ("test.ambience.library", .ambience, nil, "library", 0),
            ("test.ambience.forest", .ambience, nil, "forestDay", 0),
        ]
        var tracks: [CatalogTrack] = []
        for spec in specs {
            let url = folder.appendingPathComponent("\(spec.id).caf")
            if !FileManager.default.fileExists(atPath: url.path) {
                write(url, frequency: spec.base_hz, seconds: spec.layer == .music ? 20 : 8)
            }
            let bytes = FileStore.fileSize(at: url)
            let frames = (try? AVAudioFile(forReading: url).length) ?? 0
            tracks.append(CatalogTrack(
                id: spec.id, layer: spec.layer, title: spec.id, author: "Nodus Reader (generated)", authorURL: nil,
                source: .init(provider: "Generated", pageURL: "", fileURL: "", retrievedOn: "", originalSHA256: "",
                              originalBytes: bytes, originalFormat: .init(codec: "pcm", sampleRate: 44_100, channels: 2, bitRate: nil)),
                license: .init(spdx: "CC0-1.0", url: "https://creativecommons.org/publicdomain/zero/1.0/legalcode",
                               evidence: .init(url: "", snapshot: "", snapshotSHA256: "", quote: "Generated for tests"),
                               verifiedOn: "", verifiedBy: "generated"),
                processing: .init(transformations: ["generated"], tools: [:]),
                file: .init(path: url.lastPathComponent, githubAssetName: nil, bytes: bytes, sha256: "", sampleRate: 44_100,
                            channels: 2, bitRateKbps: 0, frames: frames),
                audio: .init(integratedLUFS: -20, truePeakDBTP: -6, lra: nil, isLoop: spec.layer == .ambience,
                             tailStartSeconds: spec.layer == .music ? 14 : nil),
                semantics: .init(moods: spec.moods, base: spec.base, energy: 1, studySafe: true, subPool: nil)))
        }
        return ImmersiveCatalog(schemaVersion: 1, catalogVersion: "test", hosts: [],
                                packs: [.init(id: "essentials", trackIDs: tracks.map(\.id), bytes: tracks.reduce(0) { $0 + $1.file.bytes })],
                                tracks: tracks)
    }

    /// A quiet pad (frequency > 0) or soft noise with a seamless loop.
    private static func write(_ url: URL, frequency: Double, seconds: Double) {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        var noise: UInt64 = 0x2545F4914F6CDD1D
        var low: Float = 0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var sample: Float
            if frequency > 0 {
                let envelope = 0.5 - 0.5 * cos(2 * .pi * t / seconds)
                sample = Float(0.12 * envelope * (sin(2 * .pi * frequency * t) + 0.5 * sin(2 * .pi * frequency * 1.5 * t)))
            } else {
                noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
                let white = Float(Int64(bitPattern: noise) >> 40) / Float(1 << 23)
                low += 0.05 * (white - low)
                sample = 0.15 * low
            }
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = sample
        }
        // Loop seam: fade the last 50 ms into the first.
        let seam = Int(rate * 0.05)
        for i in 0..<seam {
            let x = Float(i) / Float(seam)
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                let end = Int(frames) - seam + i
                data[end] = data[end] * (1 - x) + data[i] * x
            }
        }
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
            try? file.write(from: buffer)
        }
    }
}
#endif
