import Foundation

/// `engines/<engine>/voice.json` -- the metadata beside a section's
/// materialized audio (docs/gvoice-format.md, "The lux-tts reference
/// window"). Moved here from EngineKit's `LuxReferenceWindow.Rendition`
/// (which is now a typealias of it) so a client without the engines --
/// GloamVoiceEditing's window editor -- writes exactly what the engines read.
///
/// The section is stored as REAL AUDIO, not as offsets into the master;
/// `derivedFrom` keeps the provenance, and its `sourceSha256` makes a
/// section cut from a different master stale.
public struct ReferenceWindowRendition: Codable, Equatable, Sendable {
    public struct DerivedFrom: Codable, Equatable, Sendable {
        /// Pack-relative path of the master this was cut from.
        public var audio: String?
        public var startSeconds: Double
        public var endSeconds: Double
        /// Length of the master at derivation time. A master that no
        /// longer matches has been replaced, and this window with it.
        public var sourceSeconds: Double
        /// How the transcript was produced: "on-device-asr", "transcript-slice"
        /// (the master's own transcript cut to the span) or "user".
        public var by: String?
        /// SHA-256 of the master's bytes when the section was cut. A section
        /// whose master no longer hashes to this is stale and is replaced.
        /// Absent on sections written before this field existed (accepted).
        public var sourceSha256: String?
        public init(audio: String? = nil, startSeconds: Double, endSeconds: Double,
                    sourceSeconds: Double, by: String? = nil, sourceSha256: String? = nil) {
            self.audio = audio; self.startSeconds = startSeconds; self.endSeconds = endSeconds
            self.sourceSeconds = sourceSeconds; self.by = by; self.sourceSha256 = sourceSha256
        }
    }
    /// Pack-relative path of the window audio.
    public var audio: String
    /// Transcript of the WINDOW, not of the master.
    public var text: String
    public var derivedFrom: DerivedFrom?
    public init(audio: String, text: String, derivedFrom: DerivedFrom? = nil) {
        self.audio = audio; self.text = text; self.derivedFrom = derivedFrom
    }
}
