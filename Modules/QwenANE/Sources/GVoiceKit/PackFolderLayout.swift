import Foundation

/// Where a voice and its takes live on disk: one folder per voice, takes in
/// `<voice>/variants/<key>/` — the same shape as a `.gvoice` pack, so a take
/// can never exist loose, be listed as a voice, or survive its voice's delete.
///
/// Takes are still ADDRESSED as `"<voice>-<key>"`: the UI, the HTTP API, MCP,
/// chat history and the radio's sync client all name them that way. This type
/// is the one place such an address becomes a folder, which is what lets the
/// storage change without any of those callers changing.
///
/// `variants/`, not `takes/`: iOS Studio already uses `<slug>/takes/` for the
/// recording clips that get joined into `ref.wav`.
public struct PackFolderLayout: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public enum Location: Equatable, Sendable {
        case voice(String)
        case variant(base: String, key: String)
    }

    public static let variantsFolder = "variants"

    public func voiceDir(_ slug: String) -> URL { directory.appendingPathComponent(slug) }
    public func variantsDir(_ base: String) -> URL {
        voiceDir(base).appendingPathComponent(Self.variantsFolder)
    }
    public func variantDir(base: String, key: String) -> URL {
        variantsDir(base).appendingPathComponent(key)
    }

    private func hasMeta(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path)
    }

    /// An exact top-level voice wins, so a hyphenated voice (`dj-jeff`) stays a
    /// voice even beside a `dj` voice. Otherwise try each split point from the
    /// right: `<base>` must be a voice that has take `<key>`.
    public func locate(_ address: String) -> Location? {
        guard !address.isEmpty, !address.contains("/"), !address.contains("\\"),
              address != ".", address != ".." else { return nil }
        if hasMeta(voiceDir(address)) { return .voice(address) }
        var cut = address.endIndex
        while let dash = address[..<cut].lastIndex(of: "-") {
            let base = String(address[..<dash])
            let key = String(address[address.index(after: dash)...])
            // "." / ".." as a key would name the voice's own folder (or its
            // variants/ folder) — `nova-..` must never mean `nova`.
            if !base.isEmpty, !key.isEmpty, key != ".", key != "..", hasMeta(voiceDir(base)),
               hasMeta(variantDir(base: base, key: key)) {
                return .variant(base: base, key: key)
            }
            cut = dash
        }
        return nil
    }

    public func folder(for address: String) -> URL? {
        switch locate(address) {
        case .voice(let slug)?: return voiceDir(slug)
        case .variant(let base, let key)?: return variantDir(base: base, key: key)
        case nil: return nil
        }
    }

    public func variantKeys(of base: String) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: variantsDir(base), includingPropertiesForKeys: nil)) ?? []
        return children.filter(hasMeta).map(\.lastPathComponent).sorted()
    }

    public func voiceSlugs() -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.filter(hasMeta).map(\.lastPathComponent).sorted()
    }
}
