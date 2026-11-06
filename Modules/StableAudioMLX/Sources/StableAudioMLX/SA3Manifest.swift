import Foundation

/// The two Stable Audio 3 Small diffusion transformers. Both share the T5Gemma text
/// encoder and the SAME-S decoder.
public enum SA3ModelKind: String, CaseIterable, Sendable, Codable {
    case music
    case sfx

    public var displayName: String {
        switch self {
        case .music: "Small Music"
        case .sfx: "Small SFX"
        }
    }

    var ditFileName: String {
        switch self {
        case .music: "dit_sm-music_f16"
        case .sfx: "dit_sm-sfx_f16"
        }
    }
}

/// One file of the pinned `stabilityai/stable-audio-3-optimized` revision.
public struct SA3RemoteFile: Sendable, Hashable {
    public let path: String
    public let bytes: Int64
    public let sha256: String

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Pinned upstream files. The repository is not gated; the files are covered by the
/// Stability AI Community License (DiT, SAME-S) and the Gemma Terms of Use (T5Gemma).
/// Sizes and SHA-256 were measured on 2026-11-06 from the pinned revision.
public enum SA3Manifest {
    public static let repository = "stabilityai/stable-audio-3-optimized"
    public static let revision = "30cb2644da54bfa63275d1bc7f1fa67fc718680f"

    public static let t5 = SA3RemoteFile(
        path: "MLX/t5gemma_f16.npz", bytes: 567_443_068,
        sha256: "8deb20489f36d9aec539f26c9c67321f99bc5fe300d470435ed6e76be4f16bbd")
    public static let decoder = SA3RemoteFile(
        path: "MLX/same_s_decoder_f32.npz", bytes: 218_090_820,
        sha256: "909928a8e6937c1ebe6ac4b729f0462bd3773704a11ea18278e42671dc69bfe4")
    public static let music = SA3RemoteFile(
        path: "MLX/dit_sm-music_f16.npz", bytes: 919_193_814,
        sha256: "8ed3f38e2597f361ee675051f1265d9aa2ae2fffce1c61acd2e9fe31e1db1cbc")
    public static let sfx = SA3RemoteFile(
        path: "MLX/dit_sm-sfx_f16.npz", bytes: 919_193_814,
        sha256: "7e702d2640699a57fe436ca975fda16832040ba568c1e092c2ae826987558118")
    public static let tokenizer = SA3RemoteFile(
        path: "tokenizer.model", bytes: 4_241_003,
        sha256: "61a7b147390c64585d6c3543dd6fc636906c9af3865a5548f27f31aee1d4c8e2")
    public static let licence = SA3RemoteFile(
        path: "LICENSE.md", bytes: 11_852,
        sha256: "d6f6b1a4dce5c852bd6d7d9482d002baf0ccdb71e662250b73be9eec8764ee8d")
    public static let gemmaLicence = SA3RemoteFile(
        path: "LICENSE_GEMMA.md", bytes: 10_541,
        sha256: "e77acc0d3163bb7534675045c584b4d04b387b529239fc4b3647da0a01ba4745")

    /// Files shared by both models.
    public static let shared: [SA3RemoteFile] = [t5, decoder, tokenizer, licence, gemmaLicence]

    public static func dit(_ kind: SA3ModelKind) -> SA3RemoteFile {
        kind == .music ? music : sfx
    }

    public static func files(for kinds: Set<SA3ModelKind>) -> [SA3RemoteFile] {
        shared + SA3ModelKind.allCases.filter(kinds.contains).map(dit)
    }

    public static func url(_ file: SA3RemoteFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }
}

/// Converted, ready-to-load files on disk.
public struct SA3ModelDirectory: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var tokenizer: URL { root.appendingPathComponent("tokenizer.model") }
    public var t5: URL { root.appendingPathComponent("t5gemma_f16.safetensors") }
    public var decoder: URL { root.appendingPathComponent("same_s_decoder_f32.safetensors") }

    public func dit(_ kind: SA3ModelKind) -> URL {
        root.appendingPathComponent("\(kind.ditFileName).safetensors")
    }

    /// The three conditioner tensors, extracted from the DiT archive so that text
    /// conditioning does not need the whole DiT in memory.
    public func conditioner(_ kind: SA3ModelKind) -> URL {
        root.appendingPathComponent("sa3_conditioner_\(kind.rawValue).safetensors")
    }

    public func isReady(_ kind: SA3ModelKind) -> Bool {
        let fm = FileManager.default
        return [tokenizer, t5, decoder, dit(kind), conditioner(kind)].allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    /// Bytes on disk for the converted files of the given kinds.
    public func bytesOnDisk() -> Int64 {
        let fm = FileManager.default
        let urls = [tokenizer, t5, decoder] + SA3ModelKind.allCases.flatMap { [dit($0), conditioner($0)] }
        return urls.reduce(0) { total, url in
            total + ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
    }
}
