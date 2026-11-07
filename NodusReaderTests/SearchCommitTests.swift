// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import Nodus_Reader

struct SearchCommitTests {
    @Test func typingWaitsForAPauseBeforeTheListFollows() {
        #expect(SearchCommit.delay(draft: "eng", applied: "en") == SearchCommit.pause)
        #expect(SearchCommit.pause >= .milliseconds(150))
    }

    @Test func clearingTheFieldAppliesAtOnce() {
        #expect(SearchCommit.delay(draft: "", applied: "english") == .zero)
        #expect(SearchCommit.delay(draft: "   ", applied: "english") == .zero)
    }

    @Test func nothingToApplyWhenTheListAlreadyFollows() {
        #expect(SearchCommit.delay(draft: "spanish", applied: "spanish") == nil)
    }
}
