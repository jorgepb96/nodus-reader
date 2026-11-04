import Foundation

/// A place packs are read from and written to.
///
/// This is the ONE thing the format cannot decide for you: where the bytes
/// live. macOS keeps a `VoiceLibrary` of exploded pack directories in an app
/// container; the iOS app keeps its own store shaped around its own model.
/// Everything else about a `.gvoice` -- the manifest, the zip layout, the
/// entry limits, the pace and gain rules, the loudness standard -- is the
/// format's business and lives in this target, implemented once.
///
/// The member list is not a design; it is a measurement. These are exactly
/// the six operations `GVoice.export`/`GVoice.import` call, and no others.
/// `VoiceLibrary` already satisfies all six with these signatures, so its
/// conformance is empty -- which is the evidence the seam is in the right
/// place. If a conformance here needs a body, the line has moved wrong.
public protocol GVoicePackStore {
    /// Where an address lives, for stores that keep one folder per voice
    /// (`PackFolderLayout`). Import uses it to fold a standalone take pack into
    /// the voice it belongs to. Stores without that notion get the default nil.
    func locate(_ address: String) -> PackFolderLayout.Location?

    /// Everything on disk for one slug: its metadata, its source audio if any,
    /// and its per-engine assets as `engine id -> [filename: URL]`.
    func entry(_ slug: String) throws
        -> (meta: VoiceMeta, refURL: URL?, engines: [String: [String: URL]])

    /// The variant family for a slug, keyed by variant name with "base" always
    /// present. A store with no notion of variants may return `["base": slug]`.
    func variantSlugs(of slug: String) -> [String: String]

    /// Store a new voice, minting its slug from `name`.
    func save(name: String, refWav: Data?, refText: String,
              provenance: JSONValue?,
              engines: [String: [String: Data]],
              pace: Double?,
              enginePace: [String: Double]?,
              gain: Double?,
              notes: String?) throws -> VoiceMeta

    /// Store a voice at a caller-chosen slug. Import needs this because a pack
    /// names its own variants and those names have to survive the trip.
    func saveAt(slug: String, name: String, refWav: Data?, refText: String,
                provenance: JSONValue?, variantOf: String?,
                engines: [String: [String: Data]],
                notes: String?) throws -> VoiceMeta

    /// The voice's avatar PNG on disk, nil when it has none. Export packs it
    /// as `GVoice.avatarMember`.
    func avatarURL(_ slug: String) -> URL?

    /// Store the avatar for an existing voice, replacing any it had. Import
    /// calls this after the base voice is saved; the bytes are already
    /// checked to be a PNG under `AvatarImage.maxBytes`.
    func saveAvatar(_ slug: String, pngData: Data) throws

    /// Store the pack's persona on an imported voice (default: a store without personas ignores it).
    func setPersona(_ slug: String, _ persona: Persona) throws

    /// Record the language a voice or take speaks (default: a store without languages ignores it).
    func setLanguage(_ slug: String, _ language: String) throws

    /// Record how a take is delivered (default: a store without styles ignores it).
    func setStyle(_ slug: String, _ style: VoiceStyle) throws

    /// Restore the pack's `id` and `revision` on an imported voice, so a re-import keeps the identity it
    /// was exported with (default: a store without identity ignores it). Called last in an import.
    func setIdentity(_ slug: String, id: String, revision: Int?) throws
}

public extension GVoicePackStore {
    func locate(_ address: String) -> PackFolderLayout.Location? { nil }
    /// Store the pack's persona on an imported voice. A store with no persona does nothing.
    func setPersona(_ slug: String, _ persona: Persona) throws {}
    func setLanguage(_ slug: String, _ language: String) throws {}
    func setStyle(_ slug: String, _ style: VoiceStyle) throws {}
    func setIdentity(_ slug: String, id: String, revision: Int?) throws {}
}
