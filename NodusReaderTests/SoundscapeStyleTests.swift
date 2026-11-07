// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite("Book style")
struct SoundscapeStyleTests {
    @Test func majorityWins() {
        #expect(BookStyleDetector.vote([.noir, .thriller, .noir]) == .noir)
    }

    @Test func tieIsNeutral() {
        #expect(BookStyleDetector.vote([.noir, .western]) == .neutral)
        #expect(BookStyleDetector.vote([.noir, .western, .fantasy]) == .neutral)
        #expect(BookStyleDetector.vote([]) == .neutral)
    }

    @Test func overrideBeatsDetected() {
        #expect(BookStyleDetector.resolve(override: .western, detected: .noir) == .western)
        #expect(BookStyleDetector.resolve(override: nil, detected: .noir) == .noir)
    }

    @Test func noAppleIntelligenceIsNeutral() {
        #expect(BookStyleDetector.resolve(override: nil, detected: nil) == .neutral)
    }

    @Test func oldProfilesAndPreferencesDecode() throws {
        let profile = #"{"kind":"fiction","source":"model","votes":["fiction"],"signals":{"dialogueRatio":0.1,"citationDensity":0,"headingRatio":0}}"#
        let decoded = try JSONDecoder().decode(DocumentProfile.self, from: Data(profile.utf8))
        #expect(decoded.style == nil)
        let preferences = try JSONDecoder().decode(ImmersiveBookPreferences.self, from: Data(#"{"locked":false}"#.utf8))
        #expect(preferences.styleOverride == nil)
    }
}
