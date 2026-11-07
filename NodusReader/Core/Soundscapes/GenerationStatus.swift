// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What AI soundscape generation is doing, for the quick controls and Settings.
enum GenerationStatus: Equatable, Sendable {
    case idle
    /// Generating ahead; the label names the mood or bed.
    case composing(String)
    /// Preparing the book's pack: pieces done of total.
    case preparing(done: Int, total: Int)
    /// Paused after repeated failures or by the system; the reason is shown.
    case paused(String)
}
