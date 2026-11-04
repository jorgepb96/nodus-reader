import Foundation
import ZIPFoundation

/// The one-file voice pack: one identity, its source audio, and per-engine
/// renditions derived from it.
///
/// `docs/gvoice-format.md` in this repo is the source of truth for the format,
/// and this target is its only Swift implementation -- the macOS app and the
/// iOS app both consume THIS code rather than each keeping a copy.
///
/// NOTE: the Python engine (`voices.py`) does NOT conform. It reads and writes
/// a flat zip of `meta.json` + `ref.wav` with no manifest, no `source/` and no
/// `engines/`. See "Known gaps" in the format doc; an earlier version of this
/// comment claimed conformance and was wrong.
public enum GVoice {
    /// Only version this build reads or writes.
    ///
    /// 2 restructured `engines`: a variant now maps to a LIST of member paths
    /// instead of a single one. Under v1 an engine whose rendition needed more
    /// than one file (audio + its transcript, say) wrote every file into the
    /// zip but could name only the last in the manifest, so import silently
    /// dropped the rest. That is a reinterpretation of an existing field, not
    /// an additive change, so it takes a version bump.
    public static let version = 2

    /// Delivery pace for one engine: its own override, else the voice-level
    /// pace, else 1.0. A non-positive value is treated as absent — it would
    /// divide a predicted duration to infinity or flip it negative.
    public static func pace(for engineId: String, in manifest: Manifest) -> Double {
        if let p = manifest.enginePace?[engineId], p > 0 { return p }
        if let p = manifest.pace, p > 0 { return p }
        return 1.0
    }

    /// Bound on the per-voice loudness trim, in dB either way.
    ///
    /// A trim corrects a voice that already measures right, so anything this
    /// large means the reference is the problem, not the taste. Without a bound
    /// a slider could simply undo the standard — which is how the library got
    /// into the state the standard exists to fix.
    public static let maxGainDb: Double = 12

    /// Where a pack's avatar lives. One square PNG at the root, sized by
    /// `AvatarImage.side`; the manifest's `avatar` key names it so a reader
    /// never has to probe for the member.
    public static let avatarMember = "avatar.png"

    /// Per-voice loudness trim in dB, clamped. Absent — or non-finite, which is
    /// what a hand-edited manifest carrying `null`/`NaN` decodes to — means 0,
    /// i.e. the voice sits exactly where the reference standard put it.
    public static func gain(in manifest: Manifest) -> Double {
        guard let g = manifest.gain, g.isFinite else { return 0 }
        return max(-maxGainDb, min(maxGainDb, g))
    }

    // MARK: manifest

    public struct Manifest: Codable, Equatable, Sendable {
        public struct Source: Codable, Equatable, Sendable {
            public var audio: String?
            public var text: String?
            /// BCP-47 language of this take's audio and text ("es", "en"). Absent means unstated:
            /// a reader picking a take for a line's language falls back to `base`.
            public var language: String?
            /// How this take is delivered (named style + optional arousal/valence). Absent = natural.
            public var style: VoiceStyle?
            public init(audio: String?, text: String?, language: String? = nil, style: VoiceStyle? = nil) {
                self.audio = audio; self.text = text; self.language = language; self.style = style
            }
        }
        public var gvoice: Int
        public var name: String
        public var slug: String?
        public var createdAt: String?
        public var variants: [String]?
        /// BCP-47 default language of the voice (its `base` take). Absent means unstated. Other
        /// languages are variants whose `source` entry carries its own `language`.
        public var language: String?
        /// Delivery pace for this voice, 1.0 = the reference's own pace.
        ///
        /// Belongs to the VOICE, not to the listener or the app: a slow,
        /// deliberate reference needs ~1.7 to sound like radio while a brisk
        /// one is already right at 1.0, so no single global setting serves
        /// both. Absent means 1.0.
        public var pace: Double?
        /// engine id -> delivery pace, overriding `pace` for that engine alone.
        ///
        /// Exists because engines do not implement speed the same way. On
        /// `lux-tts` it is native and graph-level, and on `supertonic` it feeds
        /// the duration predictor — both clean. Every other backend gets a
        /// generic time-domain stretch, which is audibly wrong on a voice, so a
        /// pack must be able to say "1.08 here, 1.0 there".
        ///
        /// A reader that ignores this falls back to `pace`, which the format
        /// already calls a valid reading — hence NO `gvoice` bump.
        public var enginePace: [String: Double]?
        /// Per-voice loudness trim in dB, on top of the reference standard.
        ///
        /// Belongs to the VOICE for the same reason `pace` does: it is a property
        /// of how this particular voice sits, not a setting of the listener's.
        /// The reference standard already makes every voice MEASURE the same;
        /// this carries the part measurement cannot settle, so a recipient hears
        /// the voice at the level its maker chose rather than re-dialling it.
        ///
        /// Absent means 0 — no trim, exactly where the standard put it. A reader
        /// that ignores this key gets the standard's level, which the format
        /// already calls a valid reading, so adding it does NOT bump `gvoice`.
        public var gain: Double?
        /// variant key -> source audio + its transcript
        public var source: [String: Source]?
        /// engine id -> variant key -> pack-relative member paths. A list
        /// because one rendition can be several files; single-file engines
        /// carry a one-element list.
        public var engines: [String: [String: [String]]]?
        /// Free-form, producer-defined record of how the renditions were made.
        /// Opaque to this reader — carried through import/export unchanged.
        public var provenance: JSONValue?
        /// Pack-relative path of the avatar PNG, when the pack carries one.
        /// Cosmetic, not identity: a reader that ignores it renders the voice
        /// exactly as before, so adding it did NOT bump `gvoice`. Shared by
        /// every variant — the picture is of the person, not of a mood.
        public var avatar: String?
        /// The voice's character, generic: each app interprets it (the radio app as a host, the party
        /// app as a DJ, Studio as a chat character). See "The persona" in docs/gvoice-format.md.
        public var persona: Persona?
        /// Free-form description of the voice.
        public var notes: String?
        /// Stable identity of this voice across every share: a UUID minted when the voice is created and
        /// kept by every export. Two packs with the same `id` are versions of one voice.
        public var id: String?
        /// Version of this voice: bumped whenever its audio, character or photo changes. With `id`, an
        /// importer can tell an update (higher revision) from a copy or an older version.
        public var revision: Int?

        /// Spelled out because a public struct's memberwise init is internal.
        /// It went unnoticed while the only caller was in this module; a client
        /// target — the iOS app, or a test — cannot build a manifest without it.
        public init(gvoice: Int, name: String, slug: String? = nil,
                    createdAt: String? = nil, variants: [String]? = nil,
                    pace: Double? = nil, enginePace: [String: Double]? = nil,
                    gain: Double? = nil, source: [String: Source]? = nil,
                    engines: [String: [String: [String]]]? = nil,
                    provenance: JSONValue? = nil, avatar: String? = nil, language: String? = nil,
                    persona: Persona? = nil, notes: String? = nil, id: String? = nil, revision: Int? = nil) {
            self.id = id
            self.revision = revision
            self.language = language
            self.persona = persona
            self.notes = notes
            self.gvoice = gvoice
            self.name = name
            self.slug = slug
            self.createdAt = createdAt
            self.variants = variants
            self.pace = pace
            self.enginePace = enginePace
            self.gain = gain
            self.source = source
            self.engines = engines
            self.provenance = provenance
            self.avatar = avatar
        }
    }

    /// Engine ids that must never leave this machine inside a pack.
    ///
    /// A `.gvoice` is something you hand to another PERSON — AirDropped, mailed,
    /// synced. Two kinds of member fail that trip:
    ///
    /// - `elevenlabs` is an account-scoped `voiceId`. It resolves against the
    ///   exporter's ElevenLabs account and nobody else's, so to a recipient it
    ///   is dead weight that also names a voice in a private library.
    /// - `kokoro` and `qwen3-design` are preset/instruct engines: the first
    ///   speaks only its own fixed speakers, the second mints a voice from a
    ///   text description. Neither can BE the cloned identity the pack is for,
    ///   so a pointer to one claims a likeness that does not exist — a Benson
    ///   pack "including" kokoro means Benson renders as a stranger.
    ///
    /// Stripped at EXPORT rather than refused at import: the local library may
    /// legitimately hold these (the studio uses them to audition), and a voice
    /// carrying one must still be shareable — minus the parts that don't travel.
    static let unshareableEngines: Set<String> = ["elevenlabs", "kokoro", "qwen3-design"]

    /// `elevenlabs` never travels — a voiceId is bound to someone else's
    /// account, so the pointer is useless in another library whatever the pack
    /// is.
    static let neverShareableEngines: Set<String> = ["elevenlabs"]

    /// Whether `engine`'s rendition may be exported from a pack.
    ///
    /// The rule above exists because a pointer to a preset engine inside a
    /// CLONED pack claims a likeness that does not exist — a Benson pack
    /// "including" kokoro means Benson renders as a stranger. That reasoning
    /// inverts for a pack with no source of its own: there the preset pointer
    /// IS the identity, not a false claim about one, and stripping it leaves an
    /// empty pack that cannot be imported at all. The built-in preset voices are
    /// exactly that shape.
    static func shareable(engine: String, packHasSource: Bool) -> Bool {
        if neverShareableEngines.contains(engine) { return false }
        return packHasSource ? !unshareableEngines.contains(engine) : true
    }

    // MARK: export

    /// Pack a voice and its emotion variants.
    ///
    /// `includeSource: false` ships only the derived per-engine renditions.
    /// Source audio is the one asset portable across engines, so withholding it
    /// means the recipient gets a voice on the engines you baked for and cannot
    /// re-clone it anywhere else — the right default for packs leaving your own
    /// machines, and the wrong one for your own library.
    public static func export(_ slug: String, from library: some GVoicePackStore,
                              includeSource: Bool = true) throws -> Data {
        let variants = library.variantSlugs(of: slug)
        let base = try library.entry(variants["base"] ?? slug)  // throws voiceNotFound

        var manifest = Manifest(
            gvoice: version, name: base.meta.name,
            slug: base.meta.slug.isEmpty ? slug : base.meta.slug,
            createdAt: base.meta.createdAt.isEmpty ? nil : base.meta.createdAt,
            variants: orderedKeys(variants.keys),
            pace: base.meta.pace, enginePace: base.meta.enginePace,
            gain: base.meta.gain,
            source: [:], engines: [:], provenance: base.meta.provenance,
            persona: base.meta.persona, notes: base.meta.notes,
            id: base.meta.id, revision: base.meta.revision)
        manifest.language = base.meta.language
        var entries: [(name: String, data: Data)] = []

        for key in manifest.variants ?? [] {
            guard let vslug = variants[key] else { continue }
            let entry = key == "base" ? base : try library.entry(vslug)
            let suffix = key == "base" ? "" : "-\(key)"
            if includeSource, let refURL = entry.refURL {
                let member = "source/ref\(suffix).wav"
                entries.append((member, try Data(contentsOf: refURL)))
                manifest.source?[key] = Manifest.Source(audio: member, text: entry.meta.refText,
                                                         language: entry.meta.language, style: entry.meta.style)
            }
            let packHasSource = includeSource && entry.refURL != nil
            // Sorted: dictionary order varies between runs, and it decides both
            // the zip's entry order and each member list — byte-stable export.
            for (engine, files) in entry.engines.sorted(by: { $0.key < $1.key })
            where Self.shareable(engine: engine, packHasSource: packHasSource)
                && !(QwenEngineFiles.Kind.forEngine(engine) != nil && !packHasSource) {
                // The qwen3-0.6b codes + speaker embedding clone the voice as surely as
                // source/ does, so they stay home whenever source/ does.

                // A take's (or language reference's) qwen3-0.6b voice.json names its files plainly
                // (that is how the library stores it); in the pack it must name the suffixed members,
                // and a section's audio path must name the suffixed ref, so a reader can verify it.
                var rewritten: [String: Data] = [:]
                if let kind = QwenEngineFiles.Kind.forEngine(engine), key != "base",
                   let payload = Self.stemmedQwenFolder(files: files, key: key, suffix: suffix, kind: kind) {
                    rewritten = payload
                }
                for (filename, url) in files.sorted(by: { $0.key < $1.key }) {
                    let name = stem(filename, suffix: suffix)
                    let member = "engines/\(engine)/\(name)"
                    entries.append((member, try rewritten[name] ?? Data(contentsOf: url)))
                    manifest.engines?[engine, default: [:]][key, default: []].append(member)
                }
            }
        }

        guard !entries.isEmpty else {
            throw StudioError.invalidArchive("voice \(slug) has nothing to export")
        }
        // After the emptiness check on purpose: a picture is not an asset in
        // Rule 2's sense, so a pack that is only an avatar still has nothing
        // to export. Travels whether or not `source/` does — it reveals no
        // more than the name already does.
        if let avatarURL = library.avatarURL(variants["base"] ?? slug),
           let png = try? Data(contentsOf: avatarURL) {
            entries.append((avatarMember, png))
            manifest.avatar = avatarMember
        }
        // Sorted keys: JSONEncoder's key order otherwise varies between runs,
        // and the export must be byte-stable (see `entryDate`).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try makeArchive(entries: [("manifest.json", try encoder.encode(manifest))] + entries)
    }

    /// The pack-side bytes of a take's `engines/qwen3-0.6b/` files that differ from the library's: its
    /// `voice.json` (member names suffixed, section audio path suffixed). Keyed by pack file name; nil
    /// when the folder is not a valid prepared voice (then it is exported untouched).
    static func stemmedQwenFolder(files: [String: URL], key: String, suffix: String,
                                  kind: QwenEngineFiles.Kind = .qwen06) -> [String: Data]? {
        var data: [String: Data] = [:]
        for (name, url) in files {
            guard let d = try? Data(contentsOf: url), d.count <= QwenEngineFiles.maxNPYBytes else { continue }
            data[name] = d
        }
        guard var payload = try? QwenEngineFiles.decode(files: data, kind: kind) else { return nil }
        let dirPrefix = kind.directory + "/"
        switch payload.derivedFrom.audio {
        case "source/ref.wav": payload.derivedFrom.audio = "source/ref\(suffix).wav"
        case dirPrefix + "ref.wav": payload.derivedFrom.audio = dirPrefix + "ref\(suffix).wav"
        default: break
        }
        guard let members = try? payload.members(variant: key) else { return nil }
        var out: [String: Data] = [:]
        for (path, bytes) in members { out[(path as NSString).lastPathComponent] = bytes }
        return out
    }

    /// "base" first, then the rest alphabetically. Written out rather than
    /// expressed as a sort predicate: a comparator that is not a strict weak
    /// ordering can trap inside Swift's sort.
    private static func orderedKeys(_ keys: some Collection<String>) -> [String] {
        ["base"] + keys.filter { $0 != "base" }.sorted()
    }

    /// "style.json" + "-hype" -> "style-hype.json"
    private static func stem(_ filename: String, suffix: String) -> String {
        guard !suffix.isEmpty else { return filename }
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return filename + suffix }
        return (filename as NSString).deletingPathExtension + suffix + "." + ext
    }

    /// Undoes `stem` for a take's member: "voice-long.json" in variant "long"
    /// installs as "voice.json". Export suffixes a take's files only so they
    /// cannot collide with the base's inside one `engines/<id>/` directory;
    /// in the library each take has its own folder, and every engine looks its
    /// files up by their plain names. Keeping the suffix left a take's
    /// lux-tts `voice.json` unfindable, so the take quietly rendered from its
    /// base's. A name without the suffix (a foreign packer) is kept as is.
    static func unstem(_ filename: String, key: String) -> String {
        guard key != "base" else { return filename }
        let ns = filename as NSString
        let ext = ns.pathExtension, stemmed = ext.isEmpty ? filename : ns.deletingPathExtension
        let suffix = "-\(key)"
        guard stemmed.hasSuffix(suffix), stemmed.count > suffix.count else { return filename }
        let plain = String(stemmed.dropLast(suffix.count))
        return ext.isEmpty ? plain : plain + "." + ext
    }

    // MARK: import

    /// Hard ceilings on an untrusted pack, checked before any bytes are
    /// extracted. Member paths and sizes in a `.gvoice` are attacker-controlled
    /// (a zip someone sent us); without limits a crafted archive could exhaust
    /// memory extracting a single oversized or zip-bomb-style member.
    static let maxEntries = 1000
    static let maxEntryBytes: UInt64 = 200_000_000  // 200 MB — comfortably above any real voice asset

    /// Install a pack, returning the BASE voice's meta.
    ///
    /// Assets whose engine id this build does not recognise are stored anyway —
    /// ignoring an unknown engine must never fail an import, or one pack cannot
    /// serve clients that shipped at different times. Per Rule 1/2, a manifest
    /// entry pointing at a member that isn't actually in the pack degrades to
    /// "skip that one asset," not a hard failure — a single corrupt or missing
    /// entry must not sink an otherwise-importable pack.
    ///
    /// The base variant is fully resolved and written FIRST, before any other
    /// variant touches disk: if the pack has nothing installable as a base,
    /// the whole import throws before creating any partial/orphaned variant
    /// directories, regardless of what order `manifest.variants` lists keys in
    /// (that ordering is attacker-controlled and must not be trusted to put
    /// "base" first).
    public static func `import`(_ data: Data, into library: some GVoicePackStore) throws -> VoiceMeta {
        let (archive, manifest) = try open(data)

        // Readers reject only versions newer than they understand (Rule:
        // additive changes never bump `gvoice`), with one floor: version 1
        // predates the `engines` restructure, so its manifests do not decode
        // here at all. No v1 pack was ever distributed — say so plainly rather
        // than surfacing a decode error, and carry no compatibility path for a
        // version that never shipped.
        guard manifest.gvoice >= 2 else {
            throw StudioError.invalidArchive(
                "this pack is .gvoice version \(manifest.gvoice); version 1 predates the engines "
                + "restructure and cannot be read — rebuild it")
        }
        guard manifest.gvoice <= version else {
            throw StudioError.invalidArchive(
                "unsupported .gvoice version \(manifest.gvoice) (this build reads up to \(version))")
        }
        guard !manifest.name.isEmpty else {
            throw StudioError.invalidArchive("archive manifest.json has no voice name")
        }

        /// nil (not throw) for a member that is missing, unsafe to normalize,
        /// or oversized — callers treat that as "skip this one asset."
        func readOptional(_ member: String) -> Data? {
            let normalized = normalizedMember(member)
            guard let entry = archive[normalized] else { return nil }
            guard entry.uncompressedSize <= maxEntryBytes else { return nil }
            return try? extract(entry, from: archive)
        }

        let sources = manifest.source ?? [:]
        let engines = manifest.engines ?? [:]
        let keys = manifest.variants
            ?? orderedKeys(Set(["base"] + Array(sources.keys) + engines.values.flatMap { Array($0.keys) }))

        /// Resolve one variant's assets. Engine ids and filenames are validated
        /// hard (an unsafe one aborts the whole import, matching
        /// `testImportRejectsPathTraversal`); a dangling *member reference* for
        /// an otherwise-safe path just drops that one asset.
        func resolveVariant(_ key: String) throws -> (ref: Data?, assets: [String: [String: Data]]) {
            let ref = sources[key]?.audio.flatMap(readOptional)
            var assets: [String: [String: Data]] = [:]
            for (engine, perVariant) in engines {
                guard let members = perVariant[key] else { continue }
                let engineID = try safeComponent(engine)
                for member in members {
                    // Audio-driven engines may point back into source/, which
                    // is already read above as the reference.
                    guard !normalizedMember(member).lowercased().hasPrefix("source/") else { continue }
                    let filename = try safeComponent((member as NSString).lastPathComponent)
                    guard let blob = readOptional(member) else { continue }
                    assets[engineID, default: [:]][unstem(filename, key: key)] = blob
                }
            }
            return (ref, assets)
        }

        let (baseRef, baseAssets) = try resolveVariant("base")
        guard baseRef != nil || !baseAssets.isEmpty else {
            throw StudioError.invalidArchive("archive has no base variant to install")
        }
        // A standalone take pack — older builds exported and synced a take as
        // its own voice, slug "<voice>-<key>". When that voice is here and the
        // pack's name marks it as its take, it goes inside the voice. Already
        // there: leave the bytes alone, so a sync client re-offering the same
        // pack changes nothing (and re-uploads nothing).
        if let slug = manifest.slug, keys.allSatisfy({ $0 == "base" }),
           let (voice, key) = takeOwner(slug: slug, name: manifest.name, in: library) {
            let address = "\(voice)-\(key)"
            if case .variant? = library.locate(address) { return try library.entry(address).meta }
            return try library.saveAt(slug: address, name: manifest.name, refWav: baseRef,
                                      refText: sources["base"]?.text ?? "",
                                      provenance: manifest.provenance, variantOf: voice,
                                      engines: baseAssets, notes: nil)
        }

        // Spelled out in full: a protocol requirement cannot carry default
        // arguments, so import states every field it means rather than
        // inheriting one store's idea of a default.
        let baseMeta = try library.save(name: manifest.name, refWav: baseRef,
                                        refText: sources["base"]?.text ?? "",
                                        provenance: manifest.provenance, engines: baseAssets,
                                        pace: manifest.pace, enginePace: manifest.enginePace,
                                        gain: manifest.gain, notes: manifest.notes)
        if let persona = manifest.persona { try library.setPersona(baseMeta.slug, persona) }
        if let language = manifest.language ?? sources["base"]?.language {
            try library.setLanguage(baseMeta.slug, language)
        }

        // Rule 1 applies to the avatar as to any other member: missing,
        // oversized, or not actually a PNG means no avatar, never a failed
        // import. `readOptional` already enforces the archive-wide ceiling;
        // an image gets the much tighter one on top.
        if let member = manifest.avatar, let png = readOptional(member),
           png.count <= AvatarImage.maxBytes, AvatarImage.isPNG(png) {
            try? library.saveAvatar(baseMeta.slug, pngData: png)
        }

        for key in keys where key != "base" {
            let safeKey = try safeComponent(key)
            let (ref, assets) = try resolveVariant(key)
            guard ref != nil || !assets.isEmpty else { continue }
            try library.saveAt(slug: "\(baseMeta.slug)-\(safeKey)", name: "\(manifest.name) \(key)",
                               refWav: ref, refText: sources[key]?.text ?? "",
                               provenance: manifest.provenance, variantOf: baseMeta.slug,
                               engines: assets, notes: nil)
            if let language = sources[key]?.language {
                try library.setLanguage("\(baseMeta.slug)-\(safeKey)", language)
            }
            if let style = sources[key]?.style {
                try library.setStyle("\(baseMeta.slug)-\(safeKey)", style)
            }
        }
        // Last, because the setters above (persona, avatar, languages) each bump a store's revision:
        // the pack's own identity is what the imported voice must end up with.
        if let id = manifest.id, !id.isEmpty {
            try library.setIdentity(baseMeta.slug, id: id, revision: manifest.revision)
        }
        return (try? library.entry(baseMeta.slug).meta) ?? baseMeta
    }

    /// Reads just the manifest of a pack: what an importer needs to compare its `id` and `revision`
    /// against the library before deciding to install.
    public static func manifest(of data: Data) throws -> Manifest {
        try open(data).manifest
    }

    private static func open(_ data: Data) throws -> (archive: Archive, manifest: Manifest) {
        do {
            let archive = try Archive(data: data, accessMode: .read)
            guard archive.reduce(0, { count, _ in count + 1 }) <= maxEntries else {
                throw StudioError.invalidArchive("pack has too many entries")
            }
            guard let entry = archive["manifest.json"] else {
                throw StudioError.invalidArchive("not a .gvoice pack (no manifest.json)")
            }
            return (archive, try JSONDecoder().decode(Manifest.self, from: try extract(entry, from: archive)))
        } catch let error as StudioError {
            throw error
        } catch {
            throw StudioError.invalidArchive("not a valid .gvoice archive: \(error)")
        }
    }

    /// The voice (and take key) a standalone pack slugged `slug` and named
    /// `name` is a take of, by the same rule `LegacyVariantFold` uses on disk.
    private static func takeOwner(slug: String, name: String,
                                  in library: some GVoicePackStore) -> (String, String)? {
        let asMeta = VoiceMeta(name: name, slug: slug, refText: "", createdAt: "")
        var cut = slug.endIndex
        while let dash = slug[..<cut].lastIndex(of: "-") {
            let voice = String(slug[..<dash])
            if library.locate(voice) == .voice(voice),
               let key = LegacyVariantFold.key(forFolder: slug, meta: asMeta,
                                               baseMeta: try? library.entry(voice).meta, base: voice) {
                return (voice, key)
            }
            cut = dash
        }
        return nil
    }

    /// Strips a leading "./" (some writers emit pack-relative paths this way);
    /// zip member lookup is otherwise exact-match.
    static func normalizedMember(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    // MARK: helpers

    /// Reject a path component that could escape the voice directory. Member
    /// paths inside a pack are attacker-controlled — the manifest is just JSON
    /// in a zip someone sent us.
    ///
    /// Public because every store needs it for the same reason, and a store
    /// that rolled its own would be re-deciding a security rule the format
    /// already owns.
    public static func safeComponent(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\")
        else { throw StudioError.invalidArchive("unsafe path component: \(name)") }
        return name
    }

    /// 1980-01-01, the DOS epoch — the earliest date a zip entry can hold.
    static let entryDate = Date(timeIntervalSince1970: 315_532_800)

    static func makeArchive(entries: [(name: String, data: Data)]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (name, data) in entries {
            let bytes = data
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(bytes.count),
                // Fixed, not "now": sync clients hash the export to tell
                // whether a voice changed, and a timestamp that moves every
                // two seconds made every pack look changed on every cycle.
                modificationDate: Self.entryDate,
                compressionMethod: .deflate
            ) { position, size -> Data in
                let start = Int(position)
                let end = min(start + size, bytes.count)
                return bytes.subdata(in: start..<end)
            }
        }
        guard let out = archive.data else {
            throw StudioError.invalidArchive("zip create failed")
        }
        return out
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }
}
