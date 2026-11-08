// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

/// The voice slider in the atmosphere panel: full volume until changed, kept
/// between launches and never outside 0…1.
struct NarrationVolumeTests {
    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "nodus.tests.voiceVolume.\(UUID().uuidString)")!
    }

    @Test func voiceStartsAtFullVolume() {
        #expect(NarrationVolume.load(from: defaults()) == 1)
    }

    @Test func aChosenVolumeIsKept() {
        let store = defaults()
        NarrationVolume.save(0.4, to: store)
        #expect(NarrationVolume.load(from: store) == 0.4)
    }

    @Test func volumeStaysWithinRange() {
        let store = defaults()
        NarrationVolume.save(1.7, to: store)
        #expect(NarrationVolume.load(from: store) == 1)
        NarrationVolume.save(-0.2, to: store)
        #expect(NarrationVolume.load(from: store) == 0)
    }

    @Test @MainActor func silentNarrationIsNotFullVolume() {
        // A muted voice stays muted: 0 is a choice, not "unset".
        let store = defaults()
        NarrationVolume.save(0, to: store)
        #expect(NarrationVolume.load(from: store) == 0)
    }
}
