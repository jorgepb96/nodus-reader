// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import StableAudioMLX

/// Stable Audio 3 Small for AI soundscapes: downloaded per device from the pinned
/// `stabilityai/stable-audio-3-optimized` revision (Stability AI Community License;
/// T5Gemma under the Gemma Terms of Use), verified by size and SHA-256, converted on the
/// device and never synced or backed up. Music and Ambience install and delete
/// separately; the text encoder, decoder and encoder are shared.
@MainActor
@Observable
final class SoundscapeModels {
    enum Component: String, CaseIterable, Hashable, Sendable {
        case music
        case sfx

        var kind: SA3ModelKind { self == .music ? .music : .sfx }
    }

    enum State: Equatable, Sendable {
        case notInstalled
        case downloading(Double)
        case converting
        case installed
        case failed(String)
    }

    enum ModelsError: LocalizedError {
        case notEnoughSpace(Int64)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let bytes):
                String(localized: "Not enough free space: AI soundscapes need \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free to download and prepare.")
            case .unsupported:
                String(localized: "AI soundscapes are not available on this device.")
            }
        }
    }

    /// A downloaded archive and its converted copy coexist until the archive is deleted.
    static let conversionMargin: Int64 = 950_000_000
    static var isSupported: Bool { SA3Engine.isSupported }

    let directory: SA3ModelDirectory
    let downloads: URL
    private(set) var state: [Component: State] = [:]
    private(set) var bytesOnDisk: Int64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?

    init(root: URL? = nil, downloads: URL? = nil) {
        let base = FileStore.shared.root.appendingPathComponent("Soundscapes", isDirectory: true)
        directory = SA3ModelDirectory(root: root ?? base.appendingPathComponent("Models", isDirectory: true))
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.downloads = downloads ?? caches.appendingPathComponent("Soundscapes/Downloads", isDirectory: true)
        refresh()
    }

    func isInstalled(_ component: Component) -> Bool { directory.isReady(component.kind) }
    var anyInstalled: Bool { Component.allCases.contains(where: isInstalled) }
    var isBusy: Bool { task != nil }

    func refresh() {
        for component in Component.allCases {
            switch state[component] {
            case .downloading, .converting: continue
            default: state[component] = isInstalled(component) ? .installed : (state[component].flatMap { if case .failed = $0 { $0 } else { nil } } ?? .notInstalled)
            }
        }
        bytesOnDisk = directory.bytesOnDisk()
        onChange?()
    }

    private var sharedInstalled: Bool {
        [directory.tokenizer, directory.t5, directory.decoder, directory.encoder]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Free space needed to install `components`: the archives still missing plus room
    /// for converting the largest one.
    func requiredFreeBytes(for components: Set<Component>) -> Int64 {
        let missing = components.filter { !isInstalled($0) }
        guard !missing.isEmpty else { return 0 }
        var files = sharedInstalled ? [] : SA3Manifest.shared
        files += Component.allCases.filter(missing.contains).map { SA3Manifest.dit($0.kind) }
        return files.reduce(0) { $0 + $1.bytes } + Self.conversionMargin
    }

    func install(_ components: Set<Component>) {
        guard task == nil, Self.isSupported else {
            if !Self.isSupported { for c in components { state[c] = .failed(ModelsError.unsupported.localizedDescription) } }
            return
        }
        let wanted = components.filter { !isInstalled($0) }
        guard !wanted.isEmpty else { return }
        let needed = requiredFreeBytes(for: wanted)
        let free = (try? FileStore.shared.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage).flatMap { $0 } ?? Int64.max
        guard free >= needed else {
            for c in wanted { state[c] = .failed(ModelsError.notEnoughSpace(needed).localizedDescription) }
            return
        }
        for c in wanted { state[c] = .downloading(0) }
        let files = (sharedInstalled ? [] : SA3Manifest.shared) + Component.allCases.filter(wanted.contains).map { SA3Manifest.dit($0.kind) }
        let directory = directory
        let downloads = downloads
        task = Task { [weak self] in
            do {
                let total = Double(files.reduce(0) { $0 + $1.bytes })
                var done = 0.0
                for file in files {
                    try Task.checkCancellation()
                    let base = done
                    _ = try await Self.download(file, into: downloads) { written in
                        Task { @MainActor in
                            for c in wanted { self?.state[c] = .downloading(min(1, (base + Double(written)) / total)) }
                        }
                    }
                    done += Double(file.bytes)
                }
                for c in wanted { self?.state[c] = .converting }
                try await Task.detached(priority: .utility) {
                    try SA3Installer.prepare(kinds: Set(wanted.map(\.kind)), downloads: downloads, directory: directory,
                                             deleteArchives: true)
                }.value
                Self.excludeFromBackup(directory.root)
                self?.task = nil
                self?.refresh()
            } catch {
                for c in wanted {
                    self?.state[c] = error is CancellationError ? .notInstalled : .failed(error.localizedDescription)
                }
                self?.task = nil
                self?.refresh()
            }
        }
    }

    func cancelInstall() {
        task?.cancel()
    }

    /// Deletes one component (and the shared files with the last). Generated pieces stay.
    func remove(_ component: Component) {
        SA3Installer.remove(component.kind, from: directory)
        state[component] = .notInstalled
        refresh()
    }

    // MARK: Download

    private static func download(_ file: SA3RemoteFile, into folder: URL,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        excludeFromBackup(folder)
        let destination = folder.appendingPathComponent(file.fileName)
        if (try? SA3Installer.verify(destination, against: file)) != nil { return destination }
        let (temporary, response) = try await URLSession.shared.download(from: SA3Manifest.url(file), delegate: Progress(progress))
        defer { try? fm.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SA3Installer.InstallError.badResponse(file.fileName, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try SA3Installer.verify(temporary, against: file)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private final class Progress: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Int64) -> Void
        init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
