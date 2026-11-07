// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite("Model credit")
struct ModelCreditTests {
    let card = URL(string: "https://huggingface.co/example/model")!

    @Test func licencesLinkToTheirOfficialText() {
        #expect(ModelCredit.licenseURL(for: "Apache-2.0", source: card)?.absoluteString
                == "https://www.apache.org/licenses/LICENSE-2.0")
        #expect(ModelCredit.licenseURL(for: "MIT", source: card)?.absoluteString
                == "https://opensource.org/license/mit")
        #expect(ModelCredit.licenseURL(for: "CC BY-NC 4.0", source: card)?.absoluteString
                == "https://creativecommons.org/licenses/by-nc/4.0/")
    }

    @Test func ownLicencesLinkToTheModelPage() {
        #expect(ModelCredit.licenseURL(for: "Linnet Weights License 1.0", source: card) == card)
    }

    @Test func appleVoicesNeedNoLink() {
        #expect(ModelCredit.licenseURL(for: "Apple", source: card) == nil)
    }
}
