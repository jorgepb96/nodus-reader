// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import AVFoundation
import Testing
@testable import Nodus_Reader

/// Narration must own a non-mixable session, even after Immersive Audio set
/// a mixable one: only then is Nodus the Now Playing app (Lock Screen,
/// Control Center and Dynamic Island cover and controls).
@Test @MainActor func narrationTakesANonMixableSessionAfterAmbience() throws {
    let session = AVAudioSession.sharedInstance()
    try AudioSessionCoordinator.apply(.mixedAmbience, to: session)
    #expect(session.categoryOptions.contains(.mixWithOthers))
    try AudioSessionCoordinator.apply(.spokenAudio, to: session)
    #expect(session.category == .playback)
    #expect(session.mode == .spokenAudio)
    #expect(!session.categoryOptions.contains(.mixWithOthers))
    // The options used before build 46, recorded for the diagnosis.
    do {
        try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
        print("PROBE legacy spoken options: accepted, options \(session.categoryOptions.rawValue)")
    } catch {
        print("PROBE legacy spoken options: THROWS \(error)")
    }
}
#endif
