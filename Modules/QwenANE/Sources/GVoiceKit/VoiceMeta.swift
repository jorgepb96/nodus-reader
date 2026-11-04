import Foundation

// The pack's identity payload. Lives in GVoiceKit rather than alongside
// VoiceLibrary because it is what a .gvoice CARRIES, not how one app happens
// to store it -- docs/gvoice-format.md is normative for these key names, and
// two apps decoding them independently is exactly the drift this target
// exists to prevent.

/// Chat persona attached to a voice. Kept as its own struct so it can later be
/// lifted into a standalone Character entity (spec: personas now, characters later).
public struct Persona: Codable, Equatable, Sendable {
    /// Who this voice is, written for an LLM ("You are Benson, a warm late-night bartender…").
    public var systemPrompt: String
    public var greeting: String?
    /// One line under the name ("late-night bartender from Mendoza").
    public var tagline: String?
    /// Short lines the character says now and then.
    public var catchphrases: [String]?
    /// Signature color as "#RRGGBB".
    public var color: String?
    /// BCP-47 language this character speaks ("es"); nil = automatic (the listener's language when the
    /// voice speaks it, else the pack's default language).
    public var language: String?
    public init(systemPrompt: String, greeting: String? = nil, tagline: String? = nil,
                catchphrases: [String]? = nil, color: String? = nil, language: String? = nil) {
        self.language = language
        self.systemPrompt = systemPrompt
        self.greeting = greeting
        self.tagline = tagline
        self.catchphrases = catchphrases
        self.color = color
    }
}

/// A voice's own Direction for one engine: the instruction that makes a
/// directed engine (Breeze) sound like this person, and the CFG it was tuned
/// at. Benson's ElevenLabs reference reads faintly British to Breeze; "Speaks
/// English with an Argentine accent." at CFG 2 puts him back. That belongs to
/// the voice, not to whatever happened to be typed in the Direct pane last.
///
/// Stored as the engine's own member, `engines/<id>/voice.json` — the same
/// place qwen3-design keeps its instruct — so it travels per variant and a
/// reader that has never heard of the engine still carries it through
/// re-export (format Rule 1). See docs/gvoice-format.md.
public struct VoiceDirection: Codable, Equatable, Sendable {
    public var instruct: String
    /// Nil = the engine's own default CFG.
    public var cfgScale: Double?
    public init(instruct: String, cfgScale: Double? = nil) {
        self.instruct = instruct
        self.cfgScale = cfgScale
    }
}

/// On-disk shape and key names are identical to the Python engine's
/// voices.py meta.json so .gvoice packs interchange cleanly.
public struct VoiceMeta: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var refText: String
    public var createdAt: String
    public var persona: Persona?
    /// Free-form record of how a `.gvoice` import's renditions were produced.
    /// Opaque to this build — carried so re-export doesn't drop it. Nil for
    /// voices created locally rather than imported.
    public var provenance: JSONValue?
    /// Local slug of the voice this one is an emotion/style variant of, e.g.
    /// "cruz-hype" carries `variantOf: "cruz"`. Nil for a base (non-variant)
    /// voice. Explicit membership, not inferred from the slug prefix — an
    /// independently-named voice like "dj-nova" must never be mistaken for a
    /// variant of "dj" just because its slug starts with "dj-".
    public var variantOf: String?
    /// An acted take of another voice — its clip already performs an emotion
    /// or style. The one test every surface uses when deciding not to direct
    /// that emotion a second time.
    public var isTake: Bool { variantOf != nil }
    /// Delivery pace, 1.0 = the reference's own pace. Nil means unset — which
    /// is NOT the same as 1.0, because writing a default into every pack would
    /// make "unset" indistinguishable from "deliberately 1.0" on re-export.
    public var pace: Double?
    /// Engine id -> pace override. See `GVoice.pace(for:in:)` for resolution.
    public var enginePace: [String: Double]?
    /// Per-voice loudness trim in dB, on top of the reference standard.
    ///
    /// The standard (`RefLoudness`) makes every voice measure the same. This is
    /// for the part measurement cannot settle: two references at an identical
    /// -17.0 LUFS can still sit differently in a mix, because timbre, delivery
    /// and the material behind them all move perceived level. Taste, in other
    /// words — which is why it is a per-voice trim and not another target.
    ///
    /// Deliberately layered ON TOP of the standard rather than replacing it. A
    /// trim over a working baseline is a small correction most voices leave at
    /// zero; a trim over an unlevelled library would be 34 numbers dialled by
    /// hand to paper over a bug, re-dialled on every import.
    ///
    /// Nil means unset, which is NOT the same as 0 — writing a default into
    /// every pack would make "unset" indistinguishable from "deliberately flat"
    /// on re-export, exactly as `pace` documents above.
    public var gain: Double?

    /// Free-form human description of the voice — what it sounds like, where it
    /// came from. Seeded on the built-in preset packs (Kokoro's per-voicepack
    /// blurbs, SuperTonic's M/F style notes) and editable like any other field,
    /// which is the point: the description belongs to the voice, not to whatever
    /// view happened to be showing it. Nil means unset, as for `pace`/`gain`.
    public var notes: String?

    /// BCP-47 language of this voice's reference ("en", "es"). On a take it is the language that take
    /// speaks -- a bilingual voice carries one take per language -- and on a base voice its default
    /// language. Nil means unstated. Travels as the manifest's `language` / `source.<key>.language`.
    public var language: String?

    /// How a take is delivered (`VoiceStyle`); nil on a base voice and on a take in its natural
    /// delivery. Travels as `source.<key>.style`.
    public var style: VoiceStyle?

    /// Stable identity of the voice across shares: a UUID minted when it is created and kept by every
    /// export. Base voices only; nil on a take and on a voice made before ids existed (it is minted on the
    /// first edit or export-time stamp). See docs/gvoice-format.md.
    public var id: String?

    /// Version of the voice, bumped whenever its audio, character or photo changes. With `id`, an importer
    /// tells an update (higher revision) from a copy. Nil means unversioned, which compares as 0.
    public var revision: Int?

    public init(name: String, slug: String, refText: String, createdAt: String,
                persona: Persona? = nil, provenance: JSONValue? = nil, variantOf: String? = nil,
                pace: Double? = nil, enginePace: [String: Double]? = nil,
                gain: Double? = nil, notes: String? = nil,
                language: String? = nil, id: String? = nil, revision: Int? = nil) {
        self.language = language
        self.id = id
        self.revision = revision
        self.name = name
        self.slug = slug
        self.refText = refText
        self.createdAt = createdAt
        self.persona = persona
        self.provenance = provenance
        self.variantOf = variantOf
        self.pace = pace
        self.enginePace = enginePace
        self.gain = gain
        self.notes = notes
    }

    // Foreign archives may omit refText/createdAt; tolerate like Python's dict reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        refText = try c.decodeIfPresent(String.self, forKey: .refText) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        // Optional + tolerant: a malformed persona must never break voice load.
        persona = (try? c.decodeIfPresent(Persona.self, forKey: .persona)) ?? nil
        provenance = (try? c.decodeIfPresent(JSONValue.self, forKey: .provenance)) ?? nil
        variantOf = try c.decodeIfPresent(String.self, forKey: .variantOf)
        // Tolerant like the fields above: a malformed pace must not break load.
        pace = (try? c.decodeIfPresent(Double.self, forKey: .pace)) ?? nil
        enginePace = (try? c.decodeIfPresent([String: Double].self, forKey: .enginePace)) ?? nil
        // Tolerant like every field above: a malformed trim must not break load.
        gain = (try? c.decodeIfPresent(Double.self, forKey: .gain)) ?? nil
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil
        style = (try? c.decodeIfPresent(VoiceStyle.self, forKey: .style)) ?? nil
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? nil
    }
}
