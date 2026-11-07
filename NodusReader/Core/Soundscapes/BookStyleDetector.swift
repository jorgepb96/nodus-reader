// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The book's soundscape style: detected once from the same three samples as the
/// document profile, overridable per book.
enum BookStyleDetector {
    /// Majority of the samples' answers; a tie (or nothing) is neutral.
    static func vote(_ samples: [SoundscapeStyle]) -> SoundscapeStyle {
        var counts: [SoundscapeStyle: Int] = [:]
        for style in samples { counts[style, default: 0] += 1 }
        let ranked = counts.sorted { $0.value > $1.value }
        guard let first = ranked.first else { return .neutral }
        if ranked.count > 1, ranked[1].value == first.value { return .neutral }
        return first.key
    }

    static func resolve(override: SoundscapeStyle?, detected: SoundscapeStyle?) -> SoundscapeStyle {
        override ?? detected ?? .neutral
    }
}
