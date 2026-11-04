// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The complete Base checkpoint, including both encoders for creating a voice
/// on this device. No access token is needed. Every file is pinned and checked.
enum QwenModels {
    static let id = "qwen3-tts-0.6b-base-ane"
    static let repository = "tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE"
    static let revision = "551e82a5618b4804a51559bc508fece40d63b6a7"
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Qwen3-TTS-0.6B-Base", isDirectory: true)
    static let voiceCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Voices/Qwen-Prepared", isDirectory: true)
    static let stagingDirectory = directory.deletingLastPathComponent()
        .appendingPathComponent(".qwen-\(revision)-download")

    struct Manifest: Decodable {
        let repository: String
        let revision: String
        let files: [File]
        struct File: Decodable {
            let path: String
            let bytes: Int64
            let sha256: String
        }
    }

    static let manifest: Manifest? = {
        guard let url = Bundle.main.url(forResource: "QwenModelManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Manifest.self, from: data),
              value.repository == repository, value.revision == revision, !value.files.isEmpty,
              value.files.allSatisfy({ !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") })
        else { return nil }
        return value
    }()

    static func isInstalled(at root: URL = directory) -> Bool {
        guard let manifest,
              (try? String(contentsOf: root.appendingPathComponent("nodus-revision.txt"), encoding: .utf8)) == revision
        else { return false }
        return manifest.files.allSatisfy { FileStore.fileSize(at: root.appendingPathComponent($0.path)) == $0.bytes }
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let manifest else { throw QwenSpeechError.manifestMissing }
        let fm = FileManager.default
        let staging = stagingDirectory
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        ModelManager.excludeQwenFromBackup(staging)
        let total = Double(manifest.files.reduce(Int64(0)) { $0 + $1.bytes })
        var done: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            if FileStore.fileSize(at: destination) != file.bytes || (try? ContentHash.sha256(of: destination)) != file.sha256 {
                let base = done
                let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: Progress { bytes in
                    progress(min(1, (Double(base) + Double(bytes)) / total))
                })
                defer { try? fm.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw QwenSpeechError.downloadFailed(file.path)
                }
                guard FileStore.fileSize(at: temporary) == file.bytes,
                      try ContentHash.sha256(of: temporary) == file.sha256 else {
                    throw QwenSpeechError.downloadFailed(file.path)
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: temporary, to: destination)
            }
            done += file.bytes
            progress(Double(done) / total)
        }
        try Task.checkCancellation()
        try revision.write(to: staging.appendingPathComponent("nodus-revision.txt"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: staging, to: directory)
        ModelManager.excludeQwenFromBackup(directory)
    }

    private final class Progress: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Int64) -> Void
        init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}

enum QwenSpeechError: LocalizedError {
    case manifestMissing
    case downloadFailed(String)
    case incompleteSpeech

    var errorDescription: String? {
        switch self {
        case .manifestMissing: String(localized: "Qwen's download manifest is missing. Reinstall Nodus Reader.")
        case .downloadFailed(let file): String(localized: "Qwen could not download or verify \(file). Try again.")
        case .incompleteSpeech: String(localized: "Qwen could not finish this sentence. Try again or choose another voice.")
        }
    }
}
