// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PhononTTS

/// One of Gradium's Phonon voices (gradium/phonon-voices, Apache-2.0).
struct PhononVoiceFile: Sendable {
    let name: String
    let file: String
    let language: String
    let bytes: Int64
    let sha256: String
}

/// Phonon 40M Spanish on the device. Gradium publishes the checkpoint only as PyTorch weights,
/// behind a gate each person accepts on Hugging Face (CC BY-NC 4.0). Nodus Reader therefore
/// never hosts or ships it: it downloads the checkpoint with the user's own Hugging Face access,
/// checks every file against the pinned revision, adds the public Spanish voices, and exports
/// a Core ML bundle here with Gradium's exporter (built into PhononCore). The downloaded
/// weights are deleted once the bundle exists.
enum PhononOnDeviceConversion {
    struct RemoteFile: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    enum Phase: Sendable {
        case downloading(Double)
        case converting
    }

    static let modelRepository = "gradium/phonon-40m-es"
    static let modelRevision = "f0d2f39c9b58ad4c19a189e3ba989ee4df393cc5"
    static let modelPage = URL(string: "https://huggingface.co/gradium/phonon-40m-es")!
    static let checkpointFiles: [RemoteFile] = [
        RemoteFile(path: "config.json", bytes: 4_634,
                   sha256: "353a6153d9bfacdfe9bd2426e4ae1d1c055c86a17cdb172ca3eacd1dfb454a22"),
        RemoteFile(path: "tokenizer.json", bytes: 278_837,
                   sha256: "e6a00cd1a15986fa1e79ba338fa8174a2dd8c6c4630a66bf9c36237b2ebc4a15"),
        RemoteFile(path: "model.safetensors", bytes: 121_713_400,
                   sha256: "fab5eaeda2a738dfaa8559bfca045cf4bd92fbbb98b30f85315a4d08f04a5d30")
    ]

    static let voicesRepository = "gradium/phonon-voices"
    static let voicesRevision = "0ee17205f254b5abc43b266c8a0f215565c352f7"
    static let voices: [PhononVoiceFile] = [
        PhononVoiceFile(name: "Noa", file: "voices/b6FvJAiokjdqIti4.safetensors", language: "es-ES", bytes: 256136, sha256: "0bc37938a306a35f6c9f8ea53ccca14c5fc8b5575850f0cd15b352f4c3ce826e"),
        PhononVoiceFile(name: "Lucía-Sol", file: "voices/3p0eIGbkmny71GlA.safetensors", language: "es-ES", bytes: 256136, sha256: "275928c11b3c8b02e51c72653d060433e1d73a01458ef21b18e9a7f5cbd5205c"),
        PhononVoiceFile(name: "Candela", file: "voices/c9wqBDmQiBie5q6Y.safetensors", language: "es-ES", bytes: 256136, sha256: "4857d013c7502e4d074778b17122e85919bffa52741a0072e412dd3926853dcb"),
        PhononVoiceFile(name: "Celia", file: "voices/rmLBOdHrfkFym9MM.safetensors", language: "es-ES", bytes: 256136, sha256: "6ed37f47fe59674b0c9f2c099ab983d4a847ca14d09aedf80f1608a11148c757"),
        PhononVoiceFile(name: "Alba", file: "voices/u2UscyAnHilpiwmf.safetensors", language: "es-ES", bytes: 256136, sha256: "edd14cc89944ec7a9b1a87cc6be6f371f1a56791d344d921f850e2106e6dee9e"),
        PhononVoiceFile(name: "Alicia", file: "voices/4701YgRXjkBcg6sL.safetensors", language: "es-ES", bytes: 256136, sha256: "74c6bf732b76478e77072d21feca13b0bf0c664eccd2186902a63ba0d9effe59"),
        PhononVoiceFile(name: "Marcos", file: "voices/jvPx8j8zLGQ3utZz.safetensors", language: "es-ES", bytes: 256136, sha256: "be8c5f329070f40c39007bea13cee9503fe71599704cfe55c67d6eb51f5e6eb2"),
        PhononVoiceFile(name: "Borja", file: "voices/tIjCgP8v3RY8UpgM.safetensors", language: "es-ES", bytes: 256136, sha256: "fc8828dcdad4a09b7066b9008b108b77976ec4880d531da7761ded9a431bd208"),
        PhononVoiceFile(name: "Iker", file: "voices/t-_TS1e-0GzDAX02.safetensors", language: "es-ES", bytes: 256136, sha256: "25c6df91a261bcb96d9e5152c9b0988398859c0e6f4ee5f08dd577fd3bd0300d"),
        PhononVoiceFile(name: "Nuno", file: "voices/fghJGlv90qu8OJ36.safetensors", language: "es-ES", bytes: 256136, sha256: "60656e9cd518454850a7e6ecacb953572a4a23f0a358fe3b4fb946b67f6bf934"),
        PhononVoiceFile(name: "Izan", file: "voices/Ejb29qHnSOK0cIHY.safetensors", language: "es-ES", bytes: 256136, sha256: "471332253b2f76c406e395230453a7a737708cca18461237cfce0239430cb071"),
        PhononVoiceFile(name: "Guillermo", file: "voices/FaLVVqpFQcDOtq45.safetensors", language: "es-ES", bytes: 256136, sha256: "31a3837cc6705f37f95c27282ebeba71609b32204622245a6436258cd3d3497d"),
        PhononVoiceFile(name: "Rebeca", file: "voices/Sx8m6WdXBG06zwZT.safetensors", language: "es-MX", bytes: 256136, sha256: "8756dddf95fa449d0e5a8649c6a242a460329c53e2f870bbe6ed744d0573a251"),
        PhononVoiceFile(name: "Regina", file: "voices/s58clrg2fe0MO7Y-.safetensors", language: "es-MX", bytes: 256136, sha256: "ab923d4fd9ed09954e3a91c61780bcd536f5bb5787e1d0541cb6ff56dd7ff531"),
        PhononVoiceFile(name: "Danae", file: "voices/evfxKSxpDIhmsNoq.safetensors", language: "es-MX", bytes: 256136, sha256: "549f2a8dec851b967edbbd67b29d2da0799eec9ec2fefb5b0ec8aa99436d3eea"),
        PhononVoiceFile(name: "Azucena", file: "voices/KJpIQlbYrZPA4aLq.safetensors", language: "es-MX", bytes: 256136, sha256: "b5bcbbce39a6332b2f79067be19688753c28c1fc4053bf41fd4608d54c24e1ee"),
        PhononVoiceFile(name: "Jimena", file: "voices/qG5BXOJYrKEnXLIX.safetensors", language: "es-MX", bytes: 256136, sha256: "3d5590357dbd87b697a14573bbdc1f29e2abc5b6cd8a5e9ed3c98e325dede435"),
        PhononVoiceFile(name: "Ximena", file: "voices/VDwnGxAo68C8U8vC.safetensors", language: "es-MX", bytes: 256136, sha256: "ccb1b88e3899db1cb7ba71007d08ed56dd743882214f0495b67feab89850ffe0"),
        PhononVoiceFile(name: "Lalo", file: "voices/F05gqkzX7WhKVpSL.safetensors", language: "es-MX", bytes: 256136, sha256: "08159aad0d92cb391361abaf8c4bf6ac0d8358ab1514cce8cf5c89b448395ce5"),
        PhononVoiceFile(name: "Aldo", file: "voices/ax7dW1XB0eiMfHgO.safetensors", language: "es-MX", bytes: 256136, sha256: "128eeba9b5f5c6d336e1246ae20a40765fba8e5ac268aafa691b98bce1e0acfd"),
        PhononVoiceFile(name: "Yael", file: "voices/ALczEazoF4n6PmGl.safetensors", language: "es-MX", bytes: 256136, sha256: "f4ebe6b59ebfa09339cb4c15c9c8f0af72fb6cecd9feb1f550dee0d95c8092c1"),
        PhononVoiceFile(name: "Ulises", file: "voices/G5HLUsQd659UtRe7.safetensors", language: "es-MX", bytes: 256136, sha256: "fba1a4349c3c86aabc58d6570a82fac0ed643e5e7aa97b52a3ede6b792e6d420"),
        PhononVoiceFile(name: "Leonel", file: "voices/BkuASiOJRrJEB5qA.safetensors", language: "es-MX", bytes: 256136, sha256: "d32ad93e71b8c726a8f1aac62f276db82346fc1a74a02cfc18ce2b867cf20a07"),
        PhononVoiceFile(name: "Nico", file: "voices/PwgPEaweQILZdGc4.safetensors", language: "es-MX", bytes: 256136, sha256: "91af1c0e9233b3069fab26eabd191e6be4d7825eff5d5e1ce3034fbd8f7fcf24"),
        PhononVoiceFile(name: "Nerea", file: "voices/EQcQFGkYfMn5YJgx.safetensors", language: "es-ES", bytes: 256136, sha256: "c419a49606182c98e06c369d0cfb9b66cc0f16bfdbc70490fa7daf2289144986"),
    ]

    static var downloadBytes: Int64 {
        checkpointFiles.reduce(0) { $0 + $1.bytes } + voices.reduce(0) { $0 + $1.bytes }
    }

    /// Downloads with `token`, converts into `destination` (replaced), and cleans up
    /// `workDirectory`. Progress covers the download; conversion is reported as a phase.
    static func run(token: String, workDirectory: URL, destination: URL,
                    phase: @escaping @Sendable (Phase) -> Void) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workDirectory)
        let checkpoint = workDirectory.appendingPathComponent("checkpoint", isDirectory: true)
        let voiceFolder = workDirectory.appendingPathComponent("voices", isDirectory: true)
        let bundle = workDirectory.appendingPathComponent("bundle", isDirectory: true)
        try fileManager.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: voiceFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let total = Double(downloadBytes)
        var done: Int64 = 0
        phase(.downloading(0))
        for file in checkpointFiles {
            let url = URL(string: "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/\(file.path)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let base = done
            try await download(request, to: checkpoint.appendingPathComponent(file.path), expected: file) { fraction in
                phase(.downloading((Double(base) + fraction * Double(file.bytes)) / total))
            }
            done += file.bytes
        }
        for voice in voices {
            // Public files: no token is sent.
            let url = URL(string: "https://huggingface.co/\(voicesRepository)/resolve/\(voicesRevision)/\(voice.file)")!
            try await download(URLRequest(url: url), to: voiceFolder.appendingPathComponent("\(voice.name).safetensors"),
                               expected: RemoteFile(path: voice.file, bytes: voice.bytes, sha256: voice.sha256)) { _ in }
            done += voice.bytes
            phase(.downloading(Double(done) / total))
        }

        try Task.checkCancellation()
        phase(.converting)
        try await Phonon.exportCoreML(checkpoint: checkpoint, voices: voiceFolder, to: bundle)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: bundle, to: destination)
    }

    private static func download(_ request: URLRequest, to destination: URL, expected: RemoteFile,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = request
        request.timeoutInterval = 60
        let response: HTTPURLResponse = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse, let temporary else {
                    continuation.resume(throwing: PhononConversionError.invalidResponse)
                    return
                }
                if http.statusCode == 200 {
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }
                continuation.resume(returning: http)
            }
            let observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            objc_setAssociatedObject(task, &observationKey, observation, .OBJC_ASSOCIATION_RETAIN)
            task.resume()
        }
        switch response.statusCode {
        case 200: break
        case 401: throw PhononConversionError.signInExpired
        case 403: throw PhononConversionError.accessNotGranted
        default: throw PhononConversionError.http(response.statusCode)
        }
        let size = FileStore.fileSize(at: destination)
        let hash = try ContentHash.sha256(of: destination)
        guard size == expected.bytes, hash == expected.sha256 else {
            throw PhononConversionError.integrity(expected.path)
        }
    }

    nonisolated(unsafe) private static var observationKey: UInt8 = 0
}

enum PhononConversionError: LocalizedError, Equatable {
    case notSignedIn
    case signInExpired
    case accessNotGranted
    case integrity(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "Sign in to Hugging Face first (Hugging Face section above), with an account that has accepted this model's conditions.")
        case .signInExpired:
            String(localized: "Hugging Face did not accept your sign-in. Sign in again and retry.")
        case .accessNotGranted:
            String(localized: "Your Hugging Face account has not accepted this model's conditions yet. Open the model page, accept them, and retry.")
        case .integrity(let file):
            String(localized: "\(file) did not match the expected file. Nothing was installed; retry the download.")
        case .http(let code):
            String(localized: "Hugging Face returned HTTP \(code). Retry later.")
        case .invalidResponse:
            String(localized: "Hugging Face returned an unexpected response.")
        }
    }
}
