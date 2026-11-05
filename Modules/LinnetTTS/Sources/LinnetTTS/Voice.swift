import CLinnetTTS
import Foundation

/// Voice prompt latents, a `[frames, dim]` Float32 matrix (dim = 48 for linnet-en-35m).
///
/// Immutable and thread-safe once created. A session copies the latents at creation and keeps
/// a reference to the voice, so the voice may be dropped at any time.
public final class Voice: @unchecked Sendable {
    let handle: OpaquePointer
    /// Number of 80 ms frames.
    public let frames: Int
    /// Latent width.
    public let dim: Int

    /// Wrap `[frames, dim]` latents given row-major (`latents.count == frames * dim`).
    public init(latents: [Float], frames: Int, dim: Int = 48) throws {
        guard frames > 0, dim > 0, latents.count == frames * dim else {
            throw LinnetError.invalidArgument(
                "latents has \(latents.count) values, expected frames * dim = \(frames) * \(dim)")
        }
        var h: OpaquePointer?
        try check(latents.withUnsafeBufferPointer { linnet_voice_from_latents($0.baseAddress, frames, dim, &h) })
        guard let h else { throw LinnetError.internalError("voice handle is null") }
        handle = h
        self.frames = frames
        self.dim = dim
    }

    /// Load a NumPy `.npy` file (float32, C order).
    public static func load(path: String) throws -> Voice {
        let shape = try npyShape(path: path)
        var h: OpaquePointer?
        try check(linnet_voice_load(path, &h))
        guard let h else { throw LinnetError.internalError("voice handle is null") }
        return Voice(handle: h, frames: shape.0, dim: shape.1)
    }

    public static func load(url: URL) throws -> Voice { try load(path: url.path) }

    private init(handle: OpaquePointer, frames: Int, dim: Int) {
        self.handle = handle
        self.frames = frames
        self.dim = dim
    }

    deinit {
        linnet_voice_free(handle)
    }

    /// `(frames, dim)` from the `.npy` header; the runtime has already validated the file.
    private static func npyShape(path: String) throws -> (Int, Int) {
        guard let f = FileHandle(forReadingAtPath: path) else { throw LinnetError.io("cannot open \(path)") }
        defer { f.closeFile() }
        let head = f.readData(ofLength: 10)
        guard head.count == 10, head[0] == 0x93, head[1...5] == Data("NUMPY".utf8) else {
            throw LinnetError.format("not a .npy file: \(path)")
        }
        let headerLen: Int
        if head[6] == 1 {
            headerLen = Int(head[8]) | Int(head[9]) << 8
        } else {
            let more = f.readData(ofLength: 2)
            guard more.count == 2 else { throw LinnetError.format("truncated .npy header: \(path)") }
            headerLen = Int(head[8]) | Int(head[9]) << 8 | Int(more[0]) << 16 | Int(more[1]) << 24
        }
        guard let header = String(data: f.readData(ofLength: headerLen), encoding: .ascii),
              let range = header.range(of: "'shape':")
        else { throw LinnetError.format("unreadable .npy header: \(path)") }
        let rest = header[range.upperBound...]
        guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") else {
            throw LinnetError.format("no shape in .npy header: \(path)")
        }
        let dims = rest[rest.index(after: open)..<close].split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard dims.count == 2 else { throw LinnetError.shape("voice latents must be [frames, dim], got \(dims)") }
        return (dims[0], dims[1])
    }
}
