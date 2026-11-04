// ReferenceStandard.swift
// EngineKit — what every reference meets on its way into a voice library.
//
// One entry point for both apps' library write sites, the pack bakers
// (`spike gvoice-build` saves through VoiceLibrary; `voice-level` rewrites
// packs and voices already on disk), so a rule added here reaches every
// voice however it arrived -- recorded, combined, imported or baked.

import Foundation

public enum ReferenceStandard {
    /// `wav` with no cut-off ending (ReferenceTail), then at the loudness
    /// standard (RefLoudness). The order matters: the level is measured on
    /// the audio that is kept. Never throws; bytes neither step understands
    /// come back unchanged.
    public static func applied(to wav: Data) -> Data {
        RefLoudness.normalized(wav: ReferenceTail.trimmed(wav: wav))
    }

    /// Whether a `.gvoice` member holds a reference the standard applies to:
    /// the voice's `ref.wav` (source or engine copy) and every take's
    /// `source/ref-<key>.wav` (gvoice-format.md, "Variants"). In a library
    /// folder a take is `variants/<key>/ref.wav`, which the first case covers.
    public static func isReference(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "ref.wav" || (name.hasPrefix("ref-") && name.hasSuffix(".wav") && name.count > 8)
    }
}
