// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation

/// Owns the iOS audio session for the app's two audio clients: narration and
/// Immersive Audio (music and ambience under reading). Each client claims the
/// session while it plays and releases it when it stops; the session is
/// deactivated only when neither is playing, so closing a book never cuts the
/// other client off. macOS has no audio session: every call is a no-op there.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    enum Client: Hashable, Sendable {
        case narration
        case immersive
    }

    /// The configuration the session should have for a set of claims.
    enum Configuration: Equatable, Sendable {
        /// Narration is (or was) playing: spoken audio that takes the output
        /// from other apps, as narration always has.
        case spokenAudio
        /// Only music and ambience under silent reading: they mix with other
        /// apps instead of stopping the user's own audio.
        case mixedAmbience
    }

    private(set) var claims: Set<Client> = []
    private(set) var configuration: Configuration?

    /// What the session should be set to after a change of claims. Narration
    /// always wins; once set, spoken audio is kept until every client has
    /// released so the category does not flip under playing audio.
    static func configuration(for claims: Set<Client>, current: Configuration?) -> Configuration? {
        if claims.isEmpty { return nil }
        if claims.contains(.narration) { return .spokenAudio }
        if current == .spokenAudio { return .spokenAudio }
        return .mixedAmbience
    }

    /// Configures and activates the session for `client`. Called on every
    /// start or resume, like narration always did: iOS can deactivate it.
    func claim(_ client: Client) {
        claims.insert(client)
        let next = Self.configuration(for: claims, current: configuration)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch next {
        case .spokenAudio:
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
        case .mixedAmbience:
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
        case nil:
            break
        }
        try? session.setActive(true)
        #endif
        configuration = next
    }

    /// The client stopped. The session is given back (other apps resume and
    /// iOS stops showing Nodus as playing) only once no client remains.
    func release(_ client: Client) {
        guard claims.remove(client) != nil else { return }
        let next = Self.configuration(for: claims, current: configuration)
        configuration = next
        #if os(iOS)
        if next == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    /// Another app is playing audio that is not mixable with ours (iOS's
    /// hint that secondary audio, such as background music, should be quiet).
    var secondaryAudioShouldBeSilenced: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        #else
        false
        #endif
    }
}
