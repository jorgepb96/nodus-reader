import CryptoKit
import Foundation
import ZIPFoundation

/// The `engines/qwen3-0.6b/` (or `engines/qwen3-1.7b/`) folder of a `.gvoice` pack: Qwen3-TTS's PREPARED
/// voice, so a device can skip the on-device voice prep (~5 s on a phone). docs/gvoice-format.md ("The
/// `qwen3-0.6b` prepared voice") is normative; this type is its Swift form. The two sizes share the speech
/// tokenizer (same codes) but not the speaker encoder (1024 vs 2048 floats), so each size keeps its own folder:
/// `Kind` says which.
///
/// Foundation-only on purpose. The two arrays travel as raw `.npy` bytes and are only HEADER-checked
/// and range-checked here; turning them into tensors is the Qwen engine's business (`QwenANE`).
///
/// The per-device KV warm-up state is NOT part of this: it depends on the device and runtime, so it
/// stays a local cache.
public struct QwenEngineFiles: Equatable, Sendable {
    /// Which Qwen3-TTS size a folder was prepared for.
    public struct Kind: Hashable, Sendable {
        public let engineID: String
        public let speakerDimension: Int
        public var directory: String { "engines/\(engineID)" }
        public static let qwen06 = Kind(engineID: "qwen3-0.6b", speakerDimension: 1024)
        public static let qwen17 = Kind(engineID: "qwen3-1.7b", speakerDimension: 2048)
        public static let all: [Kind] = [.qwen06, .qwen17]
        /// The kind whose folder is `engines/<engine>/`, or nil for any other engine.
        public static func forEngine(_ engine: String) -> Kind? { all.first { $0.engineID == engine } }
    }

    /// The 0.6B folder's names, kept for the callers that only know that one.
    public static let engineID = Kind.qwen06.engineID
    public static let directory = Kind.qwen06.directory
    public static let voiceFile = "voice.json"
    public static let refCodesFile = "ref_codes.npy"
    public static let spkEmbedFile = "spk_embed.npy"

    /// 16 codebooks of the 12 Hz speech tokenizer, each code in `0..<codebookSize`.
    public static let codeGroups = 16
    public static let codebookSize = 2048
    /// 0.6B Base's x-vector size. (1.7B's is 2048: `Kind.qwen17`.)
    public static let speakerDimension = Kind.qwen06.speakerDimension
    /// The speech encoder takes at most 20 s = 250 frames at 12.5 Hz; a little headroom.
    public static let maxFrames = 256
    /// Ceilings checked before anything is parsed: the members are attacker-controlled like every other.
    public static let maxVoiceJSONBytes = 64 * 1024
    public static let maxNPYBytes = 256 * 1024

    /// How the codes were derived. `sha256` is of the audio file's BYTES, not of decoded samples.
    public struct DerivedFrom: Codable, Equatable, Sendable {
        /// Pack-relative path of the audio the codes encode: `source/ref.wav`, or a window such as
        /// `engines/lux-tts/ref.wav`.
        public var audio: String
        public var sha256: String
        /// Only when `audio` is a window cut from a longer master.
        public var startSeconds: Double?
        public var endSeconds: Double?
        public var by: String
        public var prepVersion: Int
        public var mel: String
        /// SHA-256 of the master's bytes (`source/ref.wav`) the section was cut from; only with a window.
        /// A section whose master no longer hashes to this is stale. Absent: not checked.
        public var sourceSha256: String?

        public init(audio: String, sha256: String, startSeconds: Double? = nil, endSeconds: Double? = nil,
                    by: String, prepVersion: Int, mel: String, sourceSha256: String? = nil) {
            self.audio = audio; self.sha256 = sha256; self.startSeconds = startSeconds
            self.endSeconds = endSeconds; self.by = by; self.prepVersion = prepVersion; self.mel = mel
            self.sourceSha256 = sourceSha256
        }
    }

    /// The size this folder belongs to.
    public var kind: Kind = .qwen06
    /// Exact transcript of the audio the codes encode.
    public var text: String
    public var derivedFrom: DerivedFrom
    /// `ref_codes.npy`: int32 (`<i4`), C order, shape (1, 16, T).
    public var refCodes: Data
    /// `spk_embed.npy`: float32 (`<f4`), C order, shape (1024,).
    public var spkEmbedding: Data

    public init(text: String, derivedFrom: DerivedFrom, refCodes: Data, spkEmbedding: Data, kind: Kind = .qwen06) {
        self.text = text; self.derivedFrom = derivedFrom; self.refCodes = refCodes; self.spkEmbedding = spkEmbedding
        self.kind = kind
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: staleness

    /// Whether these files describe exactly `audio` as THIS reader would prepare it. A reader that
    /// gets `false` MUST ignore the folder and prepare its own. `text` is compared trimmed: the
    /// encoders never see it, but a different transcript means different material, and the local
    /// prep cache is keyed the same way.
    public func isCurrent(forAudio audio: Data, transcript: String, prepVersion: Int, mel: String) -> Bool {
        derivedFrom.sha256 == Self.sha256Hex(audio)
            && derivedFrom.prepVersion == prepVersion
            && derivedFrom.mel == mel
            && text.trimmingCharacters(in: .whitespacesAndNewlines)
                == transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: validation

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Throws unless every field is well formed. Cheap: header parses plus one pass over ~16 KB.
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid("text is empty") }
        let d = derivedFrom
        guard Self.isSHA256(d.sha256) else { throw Invalid("derivedFrom.sha256 is not 64 lowercase hex digits") }
        guard Self.isSafeAudioPath(d.audio) else { throw Invalid("derivedFrom.audio is not a pack-relative source/ or engines/ path") }
        guard !d.by.isEmpty, d.prepVersion >= 1, !d.mel.isEmpty else { throw Invalid("derivedFrom is missing by/prepVersion/mel") }
        switch (d.startSeconds, d.endSeconds) {
        case (nil, nil): break
        case let (s?, e?):
            guard s.isFinite, e.isFinite, s >= 0, e > s else { throw Invalid("derivedFrom window is not 0 <= start < end") }
        default: throw Invalid("derivedFrom has only one of startSeconds/endSeconds")
        }

        guard refCodes.count <= Self.maxNPYBytes, spkEmbedding.count <= Self.maxNPYBytes else { throw Invalid("npy member too large") }
        let rc = try NPYLayout(refCodes, name: Self.refCodesFile)
        guard rc.descr == "<i4", rc.shape.count == 3, rc.shape[0] == 1, rc.shape[1] == Self.codeGroups,
              (1...Self.maxFrames).contains(rc.shape[2]) else {
            throw Invalid("\(Self.refCodesFile) must be int32 (1,\(Self.codeGroups),T) with 1 <= T <= \(Self.maxFrames)")
        }
        try rc.requireExactSize(elementSize: 4, name: Self.refCodesFile)
        let bad = refCodes.withUnsafeBytes { raw -> Bool in
            (0..<(rc.shape[1] * rc.shape[2])).contains { i in
                let v = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: rc.dataOffset + i * 4, as: Int32.self))
                return v < 0 || v >= Int32(Self.codebookSize)
            }
        }
        guard !bad else { throw Invalid("\(Self.refCodesFile) holds a code outside 0..<\(Self.codebookSize)") }

        let sp = try NPYLayout(spkEmbedding, name: Self.spkEmbedFile)
        let dim = kind.speakerDimension
        guard sp.descr == "<f4", sp.shape == [dim] else {
            throw Invalid("\(Self.spkEmbedFile) must be float32 (\(dim),)")
        }
        try sp.requireExactSize(elementSize: 4, name: Self.spkEmbedFile)
        let nonFinite = spkEmbedding.withUnsafeBytes { raw -> Bool in
            (0..<dim).contains { i in
                !Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: sp.dataOffset + i * 4, as: UInt32.self))).isFinite
            }
        }
        guard !nonFinite else { throw Invalid("\(Self.spkEmbedFile) holds a non-finite value") }
    }

    /// The codes as 16 rows of T frames. Validates first.
    public func decodedRefCodes() throws -> [[Int]] {
        try validate()
        let rc = try NPYLayout(refCodes, name: Self.refCodesFile)
        let T = rc.shape[2]
        return refCodes.withUnsafeBytes { raw in
            (0..<Self.codeGroups).map { g in (0..<T).map { t in
                Int(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: rc.dataOffset + (g * T + t) * 4, as: Int32.self)))
            } }
        }
    }

    /// The speaker embedding (`kind.speakerDimension` floats). Validates first.
    public func decodedSpeakerEmbedding() throws -> [Float] {
        try validate()
        let sp = try NPYLayout(spkEmbedding, name: Self.spkEmbedFile)
        return spkEmbedding.withUnsafeBytes { raw in
            (0..<kind.speakerDimension).map {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: sp.dataOffset + $0 * 4, as: UInt32.self)))
            }
        }
    }

    static func isSHA256(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Pack-relative, no `..`, no absolute or backslash paths, and inside `source/` or `engines/`.
    static func isSafeAudioPath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains("\\") else { return false }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return parts[0] == "source" || parts[0] == "engines"
    }

    // MARK: members

    /// Per-variant file name: `ref_codes.npy` for `base`, `ref_codes-hype.npy` for `hype`
    /// (the pack's usual variant suffix).
    static func name(_ stem: String, ext: String, variant: String) -> String {
        variant == "base" ? "\(stem).\(ext)" : "\(stem)-\(variant).\(ext)"
    }

    /// The pack members for `variant`, pack-relative path -> bytes (voice.json included).
    /// Throws when the files are invalid or the variant key is not a single path component.
    public func members(variant: String = "base") throws -> [String: Data] {
        try validate()
        let key = try GVoice.safeComponent(variant)
        let codes = "\(kind.directory)/\(Self.name("ref_codes", ext: "npy", variant: key))"
        let spk = "\(kind.directory)/\(Self.name("spk_embed", ext: "npy", variant: key))"
        let voice = "\(kind.directory)/\(Self.name("voice", ext: "json", variant: key))"
        let json = VoiceJSON(refCodes: codes, spkEmbedding: spk, text: text, derivedFrom: derivedFrom)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return [codes: refCodes, spk: spkEmbedding, voice: try encoder.encode(json)]
    }

    /// The same files keyed by bare file name, the shape `GVoicePackStore` engine assets take.
    public func files(variant: String = "base") throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try members(variant: variant).map { (($0.key as NSString).lastPathComponent, $0.value) })
    }

    struct VoiceJSON: Codable {
        var refCodes: String
        var spkEmbedding: String
        var text: String
        var derivedFrom: DerivedFrom
    }

    /// Reads the folder from bare-name files (a store's engine assets, or a pack's members by last
    /// component). Returns the files only if they validate; the paths in voice.json must stay inside
    /// `engines/qwen3-0.6b/` and each must name a file present in `files`.
    public static func decode(files: [String: Data], kind: Kind = .qwen06) throws -> QwenEngineFiles {
        guard let raw = files[voiceFile] ?? files.first(where: { $0.key.hasPrefix("voice") && $0.key.hasSuffix(".json") })?.value else {
            throw Invalid("no voice.json")
        }
        guard raw.count <= maxVoiceJSONBytes else { throw Invalid("voice.json too large") }
        let j: VoiceJSON
        do { j = try JSONDecoder().decode(VoiceJSON.self, from: raw) } catch { throw Invalid("voice.json: \(error)") }
        func member(_ path: String) throws -> Data {
            let prefix = kind.directory + "/"
            guard path.hasPrefix(prefix) else { throw Invalid("\(path) is outside \(kind.directory)/") }
            let leaf = String(path.dropFirst(prefix.count))
            guard (try? GVoice.safeComponent(leaf)) != nil else { throw Invalid("unsafe path \(path)") }
            // A take's voice.json names its pack members ("ref_codes-hype.npy"),
            // but import installs a take's files under their plain names
            // (GVoice.unstem), so the plain name is the same file.
            guard let d = files[leaf] ?? plainName(leaf).flatMap({ files[$0] }) else {
                throw Invalid("missing \(path)")
            }
            return d
        }
        let out = QwenEngineFiles(text: j.text, derivedFrom: j.derivedFrom,
                                  refCodes: try member(j.refCodes), spkEmbedding: try member(j.spkEmbedding), kind: kind)
        try out.validate()
        return out
    }

    /// "ref_codes-hype.npy" -> "ref_codes.npy"; nil when there is no take suffix.
    static func plainName(_ leaf: String) -> String? {
        let ns = leaf as NSString
        let ext = ns.pathExtension, stem = ns.deletingPathExtension
        guard let dash = stem.lastIndex(of: "-"), dash != stem.startIndex else { return nil }
        let plain = String(stem[..<dash])
        return ext.isEmpty ? plain : plain + "." + ext
    }

    // MARK: pack-level read / write

    /// The folder for `variant` inside a pack, or nil when it is absent or in any way unusable
    /// (Rule 1: a bad optional member degrades, it never fails the pack).
    public static func read(fromPack pack: Data, variant: String = "base", kind: Kind = .qwen06) -> QwenEngineFiles? {
        let archive: Archive
        do { archive = try Archive(data: pack, accessMode: .read) } catch { return nil }
        guard let manifest = try? manifestObject(in: archive),
              let engines = manifest["engines"] as? [String: Any],
              let perVariant = engines[kind.engineID] as? [String: Any],
              let listed = perVariant[variant] as? [String] else { return nil }
        var files: [String: Data] = [:]
        for member in listed {
            let path = GVoice.normalizedMember(member)
            guard path.hasPrefix(kind.directory + "/") else { continue }
            let leaf = String(path.dropFirst(kind.directory.count + 1))
            guard (try? GVoice.safeComponent(leaf)) != nil, let entry = archive[path],
                  entry.uncompressedSize <= UInt64(maxNPYBytes) else { continue }
            var out = Data()
            guard (try? archive.extract(entry, consumer: { out.append($0) })) != nil else { continue }
            files[leaf] = out
        }
        return try? decode(files: files, kind: kind)
    }

    /// `pack` with `files` as its `engines/<kind>/` rendition for `variant`, replacing any
    /// earlier one. Everything else, including manifest keys this build does not know, is kept.
    public static func write(_ files: QwenEngineFiles, intoPack pack: Data, variant: String = "base") throws -> Data {
        try GVoice.replacingEngine(files.kind.engineID, variant: variant, members: try files.members(variant: variant), inPack: pack)
    }

    private static func manifestObject(in archive: Archive) throws -> [String: Any] {
        guard let entry = archive["manifest.json"], entry.uncompressedSize <= GVoice.maxEntryBytes else {
            throw Invalid("no manifest")
        }
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        guard let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any] else { throw Invalid("bad manifest") }
        return obj
    }
}

/// Just enough of the `.npy` v1/v2 header to validate shape, dtype and length without a tensor library.
struct NPYLayout {
    let descr: String
    let shape: [Int]
    let dataOffset: Int
    let total: Int

    init(_ d: Data, name: String) throws {
        let b = [UInt8](d.prefix(12))
        guard d.count > 12, b[0] == 0x93, Array(b[1...5]) == Array("NUMPY".utf8) else { throw QwenEngineFiles.Invalid("\(name) is not an npy file") }
        let hlen: Int, off: Int
        if b[6] == 1 { hlen = Int(b[8]) | Int(b[9]) << 8; off = 10 }
        else if b[6] == 2 || b[6] == 3 { hlen = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24; off = 12 }
        else { throw QwenEngineFiles.Invalid("\(name): unsupported npy version") }
        guard hlen > 0, off + hlen <= d.count else { throw QwenEngineFiles.Invalid("\(name): npy header out of range") }
        let header = String(decoding: d[(d.startIndex + off)..<(d.startIndex + off + hlen)], as: UTF8.self)
        guard !header.contains("'fortran_order': True") else { throw QwenEngineFiles.Invalid("\(name): fortran order") }
        guard let dr = header.range(of: "'descr': '"), let dEnd = header[dr.upperBound...].firstIndex(of: "'") else {
            throw QwenEngineFiles.Invalid("\(name): npy header has no descr")
        }
        descr = String(header[dr.upperBound..<dEnd])
        guard let sr = header.range(of: "'shape': ("), let sEnd = header[sr.upperBound...].firstIndex(of: ")") else {
            throw QwenEngineFiles.Invalid("\(name): npy header has no shape")
        }
        let parts = header[sr.upperBound..<sEnd].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let dims = parts.compactMap { Int($0) }
        guard dims.count == parts.count, dims.allSatisfy({ $0 >= 0 && $0 < 1 << 20 }) else {
            throw QwenEngineFiles.Invalid("\(name): bad npy shape")
        }
        shape = dims
        dataOffset = off + hlen
        total = d.count
    }

    func requireExactSize(elementSize: Int, name: String) throws {
        guard dataOffset + shape.reduce(1, *) * elementSize == total else {
            throw QwenEngineFiles.Invalid("\(name): npy data length does not match its shape")
        }
    }
}

extension GVoice {
    /// The decoded manifest of a pack, without installing anything.
    public static func manifest(ofPack pack: Data) throws -> Manifest {
        let archive: Archive
        do { archive = try Archive(data: pack, accessMode: .read) }
        catch { throw StudioError.invalidArchive("not a valid .gvoice archive: \(error)") }
        guard let entry = archive["manifest.json"], entry.uncompressedSize <= maxEntryBytes else {
            throw StudioError.invalidArchive("not a .gvoice pack (no manifest.json)")
        }
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return try JSONDecoder().decode(Manifest.self, from: out)
    }

    /// One member's bytes, or nil when it is missing, oversized or unreadable (Rule 1).
    public static func member(_ path: String, ofPack pack: Data) -> Data? {
        guard let archive = try? Archive(data: pack, accessMode: .read),
              let entry = archive[normalizedMember(path)], entry.uncompressedSize <= maxEntryBytes else { return nil }
        var out = Data()
        return (try? archive.extract(entry) { out.append($0) }) == nil ? nil : out
    }

    /// A pack with one engine's members for one variant replaced: the old members the manifest listed
    /// for that engine+variant are dropped, `members` (pack-relative path -> bytes) are written and
    /// listed. The manifest is edited as generic JSON so keys this build does not model survive
    /// (Rule 1). Output is byte-stable for equal inputs.
    public static func replacingEngine(_ engine: String, variant: String, members: [String: Data],
                                       inPack pack: Data) throws -> Data {
        _ = try safeComponent(engine); _ = try safeComponent(variant)
        let archive: Archive
        do { archive = try Archive(data: pack, accessMode: .read) }
        catch { throw StudioError.invalidArchive("not a valid .gvoice archive: \(error)") }
        guard archive.reduce(0, { c, _ in c + 1 }) <= maxEntries else { throw StudioError.invalidArchive("pack has too many entries") }
        guard let mEntry = archive["manifest.json"] else { throw StudioError.invalidArchive("not a .gvoice pack (no manifest.json)") }
        var manifestData = Data()
        _ = try archive.extract(mEntry) { manifestData.append($0) }
        guard var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw StudioError.invalidArchive("manifest.json is not an object")
        }
        var engines = manifest["engines"] as? [String: Any] ?? [:]
        var perVariant = engines[engine] as? [String: Any] ?? [:]
        let old = Set((perVariant[variant] as? [String] ?? []).map(normalizedMember))
        let prefix = "engines/\(engine)/"
        for path in members.keys {
            guard path.hasPrefix(prefix), (try? safeComponent(String(path.dropFirst(prefix.count)))) != nil else {
                throw StudioError.invalidArchive("member \(path) is outside \(prefix)")
            }
        }
        perVariant[variant] = members.keys.sorted()
        engines[engine] = perVariant
        manifest["engines"] = engines
        if let vs = manifest["variants"] as? [String], !vs.contains(variant) { manifest["variants"] = vs + [variant] }

        // Members still listed by another variant of this engine are kept.
        let stillListed = Set(perVariant.filter { $0.key != variant }.values.flatMap { ($0 as? [String]) ?? [] }.map(normalizedMember))
        var entries: [(name: String, data: Data)] = []
        let encoded = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
        entries.append(("manifest.json", encoded))
        for entry in archive where entry.path != "manifest.json" && entry.type == .file {
            if members[entry.path] != nil { continue }
            if old.contains(entry.path) && !stillListed.contains(entry.path) { continue }
            guard entry.uncompressedSize <= maxEntryBytes else { throw StudioError.invalidArchive("\(entry.path) is oversized") }
            var out = Data()
            _ = try archive.extract(entry) { out.append($0) }
            entries.append((entry.path, out))
        }
        for path in members.keys.sorted() { entries.append((path, members[path]!)) }
        return try makeArchive(entries: entries)
    }
}
