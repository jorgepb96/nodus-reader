import Foundation

/// Folds a library written in the old sibling layout (`nova/`, `nova-excited/`)
/// into pack folders (`nova/variants/excited/`).
///
/// A take used to be a sibling folder tied to its voice only by
/// `meta.variantOf`, and takes made before that field existed — or by a path
/// that forgot to set it — carry nothing at all. So membership is decided by
/// what the takes DO carry: `variantOf`, or a name built from the voice's name.
/// Deliberately narrow: "Jo Smith" beside "Jo" must stay a voice, so the bare
/// "<name> <word>" / "<name>-<word>" forms only count for a known take word.
///
/// Never deletes. A take whose destination already exists is left where it
/// is and logged. Idempotent: a folded library plans nothing.
public enum LegacyVariantFold {
    /// Studio's `Emotion` and `VoiceExpression` cases plus the radio's
    /// chill/hyped. `VoiceExpression` lives in the app target, so the words
    /// are listed here and pinned by a test.
    public static let takeWords: Set<String> = [
        "flat", "neutral", "warm", "excited", "hype",
        "delight", "angry", "sad", "surprised", "shocked",
        "whisper", "shouting", "screaming", "laughing", "chuckle", "sigh",
        "panting", "moaning", "singing",
        "chill", "hyped",
    ]

    /// Held in the library folder while a fold runs. Studio and the radio app
    /// share the folder and both fold at launch.
    public static let lockName = ".pack-fold.lock"

    public struct Move: Equatable, Sendable {
        public let folder: String
        public let base: String
        public let key: String
    }

    /// The take key when folder `slug` (with `meta`) is a take of voice `base`
    /// (with `baseMeta`), else nil. `slug` must be `"<base>-<key>"`.
    public static func key(forFolder slug: String, meta: VoiceMeta,
                           baseMeta: VoiceMeta?, base: String) -> String? {
        guard let baseMeta, slug.hasPrefix("\(base)-") else { return nil }
        let key = String(slug.dropFirst(base.count + 1))
        guard !key.isEmpty, (try? GVoice.safeComponent(key)) != nil else { return nil }
        if meta.variantOf == base { return key }
        let name = meta.name.lowercased().trimmingCharacters(in: .whitespaces)
        let baseName = baseMeta.name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !baseName.isEmpty, name.hasPrefix(baseName) else { return nil }
        let rest = name.dropFirst(baseName.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("("), rest.hasSuffix(")"), rest.count > 2 { return key }
        if takeWords.contains(rest) { return key }
        // "<Base>-<word>": how RecordEmotionVariantSheet used to name a take.
        if rest.hasPrefix("-"), takeWords.contains(String(rest.dropFirst())) { return key }
        return nil
    }

    private static func readMeta(_ folder: URL) -> VoiceMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(VoiceMeta.self, from: data)
    }

    /// What `run` would move, without touching disk.
    public static func plan(in layout: PackFolderLayout) -> [Move] {
        let slugs = layout.voiceSlugs()
        let present = Set(slugs)
        var moves: [Move] = []
        for slug in slugs {
            guard let meta = readMeta(layout.voiceDir(slug)) else { continue }
            // variantOf naming an existing voice decides it outright.
            if let base = meta.variantOf, base != slug, present.contains(base),
               let key = key(forFolder: slug, meta: meta,
                             baseMeta: readMeta(layout.voiceDir(base)), base: base) {
                moves.append(Move(folder: slug, base: base, key: key))
                continue
            }
            // Otherwise the longest base that exists and matches, rightmost split first.
            var cut = slug.endIndex
            while let dash = slug[..<cut].lastIndex(of: "-") {
                let base = String(slug[..<dash])
                if present.contains(base),
                   let key = key(forFolder: slug, meta: meta,
                                 baseMeta: readMeta(layout.voiceDir(base)), base: base) {
                    moves.append(Move(folder: slug, base: base, key: key))
                    break
                }
                cut = dash
            }
        }
        // A folder that is itself folding cannot also receive a take this
        // pass: the take would land in a variants/ folder with no voice above
        // it and vanish from view. It stays put and is judged again next time.
        let moving = Set(moves.map(\.folder))
        return moves.filter { !moving.contains($0.base) }
    }

    /// Fold the library. Copies it to `backup` first (once — an existing backup
    /// is kept) when there is anything to move. Returns what actually moved.
    @discardableResult
    public static func run(in layout: PackFolderLayout, backup: URL?,
                           log: (String) -> Void) throws -> [Move] {
        guard !plan(in: layout).isEmpty else { return [] }
        let fm = FileManager.default
        // Studio and the radio app share this folder and both fold at launch.
        guard let lock = Lock(in: layout.directory) else {
            log("another app is folding this voice library; skipped")
            return []
        }
        defer { lock.release() }
        let moves = plan(in: layout)   // again, under the lock
        guard !moves.isEmpty else { return [] }
        if let backup, !fm.fileExists(atPath: backup.path) {
            // Copy beside it, then rename into place: the backup exists whole
            // or not at all, never half-written and then trusted forever.
            let partial = backup.deletingLastPathComponent()
                .appendingPathComponent("\(backup.lastPathComponent).partial-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: layout.directory, to: partial)
            try? fm.removeItem(at: partial.appendingPathComponent(lockName))
            try fm.moveItem(at: partial, to: backup)
            log("voice library backed up to \(backup.path)")
        }
        var done: [Move] = []
        for move in moves {
            let source = layout.voiceDir(move.folder)
            guard fm.fileExists(atPath: source.path) else { continue }   // already moved
            // The voice already has this take: keep both, the newcomer under the
            // next free key. Leaving it top-level would hide the take, since an
            // exact top-level folder wins the address.
            var key = move.key
            var n = 2
            while fm.fileExists(atPath: layout.variantDir(base: move.base, key: key).path) {
                key = "\(move.key)-\(n)"; n += 1
            }
            let dest = layout.variantDir(base: move.base, key: key)
            try fm.createDirectory(at: layout.variantsDir(move.base), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: dest)
            if var meta = readMeta(dest) {
                meta.variantOf = move.base
                meta.slug = "\(move.base)-\(key)"
                try JSONEncoder().encode(meta).write(to: dest.appendingPathComponent("meta.json"))
            }
            log("folded \(move.folder) into \(move.base) as take \(key)")
            done.append(Move(folder: move.folder, base: move.base, key: key))
        }
        return done
    }

    /// An exclusive lock file (O_EXCL). One left behind by a crash is broken
    /// after ten minutes — a fold takes seconds.
    struct Lock {
        let url: URL
        init?(in directory: URL) {
            url = directory.appendingPathComponent(LegacyVariantFold.lockName)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if Self.take(url) { return }
            if let made = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(made) > 600 {
                try? FileManager.default.removeItem(at: url)
                if Self.take(url) { return }
            }
            return nil
        }
        private static func take(_ url: URL) -> Bool {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard fd >= 0 else { return false }
            close(fd)
            return true
        }
        func release() { try? FileManager.default.removeItem(at: url) }
    }
}
