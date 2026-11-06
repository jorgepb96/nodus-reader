import CryptoKit
import Foundation

/// Downloads the pinned files (verifying size and SHA-256) and converts them to the
/// layout `SA3ModelDirectory` expects. The downloaded archives are deleted once
/// converted, so only one copy of the weights stays on disk.
public enum SA3Installer {
    public enum InstallError: Error, CustomStringConvertible {
        case badResponse(String, Int)
        case sizeMismatch(String, Int64, Int64)
        case hashMismatch(String)

        public var description: String {
            switch self {
            case .badResponse(let name, let code): "\(name): HTTP \(code)"
            case .sizeMismatch(let name, let expected, let actual): "\(name): expected \(expected) bytes, got \(actual)"
            case .hashMismatch(let name): "\(name): SHA-256 does not match the pinned value"
            }
        }
    }

    /// Verifies a file against its pinned size and SHA-256, streaming it in 8 MiB reads.
    public static func verify(_ url: URL, against file: SA3RemoteFile) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        guard size == file.bytes else { throw InstallError.sizeMismatch(file.fileName, file.bytes, size) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw InstallError.hashMismatch(file.fileName) }
    }

    /// Downloads `file` into `folder` unless a verified copy is already there.
    public static func download(_ file: SA3RemoteFile, into folder: URL, session: URLSession = .shared) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.fileName)
        if (try? verify(destination, against: file)) != nil { return destination }
        let (temporary, response) = try await session.download(from: SA3Manifest.url(file))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw InstallError.badResponse(file.fileName, code)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try verify(destination, against: file)
        return destination
    }

    /// Converts verified archives in `downloads` into `directory`. Archives are removed
    /// after conversion when `deleteArchives` is set.
    public static func prepare(
        kinds: Set<SA3ModelKind>, downloads: URL, directory: SA3ModelDirectory, deleteArchives: Bool
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.root, withIntermediateDirectories: true)

        func archive(_ file: SA3RemoteFile) -> URL { downloads.appendingPathComponent(file.fileName) }
        func finish(_ file: SA3RemoteFile) {
            if deleteArchives { try? fm.removeItem(at: archive(file)) }
        }

        if !fm.fileExists(atPath: directory.tokenizer.path) {
            try fm.copyItem(at: archive(SA3Manifest.tokenizer), to: directory.tokenizer)
        }
        for licence in [SA3Manifest.licence, SA3Manifest.gemmaLicence] {
            let target = directory.root.appendingPathComponent(licence.fileName)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: archive(licence), to: target) }
        }
        if !fm.fileExists(atPath: directory.t5.path) {
            try NPZToSafetensors.convert(source: archive(SA3Manifest.t5), destination: directory.t5)
            finish(SA3Manifest.t5)
        }
        if !fm.fileExists(atPath: directory.encoder.path) {
            try NPZToSafetensors.convert(source: archive(SA3Manifest.encoder), destination: directory.encoder)
            finish(SA3Manifest.encoder)
        }
        if !fm.fileExists(atPath: directory.decoder.path) {
            try NPZToSafetensors.convert(source: archive(SA3Manifest.decoder), destination: directory.decoder)
            finish(SA3Manifest.decoder)
        }
        for kind in kinds {
            let source = archive(SA3Manifest.dit(kind))
            if !fm.fileExists(atPath: directory.conditioner(kind).path) {
                try NPZToSafetensors.convert(source: source, destination: directory.conditioner(kind), onlyPrefix: "cond.")
            }
            if !fm.fileExists(atPath: directory.dit(kind).path) {
                try NPZToSafetensors.convert(source: source, destination: directory.dit(kind))
            }
            finish(SA3Manifest.dit(kind))
        }
    }

    /// Removes one model's DiT (the shared encoder and decoder stay while either model is
    /// installed) or everything when no model remains.
    public static func remove(_ kind: SA3ModelKind, from directory: SA3ModelDirectory) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory.dit(kind))
        try? fm.removeItem(at: directory.conditioner(kind))
        let other: SA3ModelKind = kind == .music ? .sfx : .music
        if !fm.fileExists(atPath: directory.dit(other).path) {
            try? fm.removeItem(at: directory.root)
        }
    }
}
