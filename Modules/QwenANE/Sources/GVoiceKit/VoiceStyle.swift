import Foundation

/// How a take is delivered: a named style from a declared vocabulary, plus optional position on the
/// two dimensions W3C EmotionML uses (arousal: calm 0 … energetic 1; valence: unpleasant 0 …
/// pleasant 1). A reader that doesn't know the name can still find "the most energetic take" from
/// the numbers. Travels as `source.<key>.style` in a pack; absent means the voice's natural delivery.
public struct VoiceStyle: Codable, Equatable, Hashable, Sendable {
    /// The style's name in `vocabulary` ("excited").
    public var name: String
    /// Whose names these are. "gloam" is Gloam Voice Studio's five; nil means "gloam".
    public var vocabulary: String?
    /// 0 (calm) … 1 (energetic). Nil = unstated.
    public var arousal: Double?
    /// 0 (unpleasant) … 1 (pleasant). Nil = unstated.
    public var valence: Double?

    public init(name: String, vocabulary: String? = nil, arousal: Double? = nil, valence: Double? = nil) {
        self.name = name; self.vocabulary = vocabulary; self.arousal = arousal; self.valence = valence
    }

    /// Gloam's five, with the dimensions a writer should attach (docs/gvoice-format.md).
    public static let gloam: [String: VoiceStyle] = [
        "flat": .init(name: "flat", vocabulary: "gloam", arousal: 0.15, valence: 0.45),
        "neutral": .init(name: "neutral", vocabulary: "gloam", arousal: 0.4, valence: 0.55),
        "warm": .init(name: "warm", vocabulary: "gloam", arousal: 0.35, valence: 0.85),
        "excited": .init(name: "excited", vocabulary: "gloam", arousal: 0.8, valence: 0.8),
        "hype": .init(name: "hype", vocabulary: "gloam", arousal: 0.95, valence: 0.75),
    ]

    /// The Gloam style a variant key names, by its last component (`excited`, `es-excited`).
    /// Only for packs written before `style` existed; new packs carry the field.
    public static func fromLegacyKey(_ key: String) -> VoiceStyle? {
        gloam[String(key.split(separator: "-").last ?? "")]
    }
}
