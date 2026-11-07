// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

/// The model, language and gender filters only offer what the other two
/// leave available: Kokoro without German does not list German.
@MainActor
struct VoiceFilterFacetTests {
    func voice(_ name: String, _ model: String, _ language: String, _ gender: VoiceGender?) -> VoiceCatalog.Voice {
        VoiceCatalog.Voice(id: "\(model):\(name)", name: name, language: language, languageName: language,
                           quality: 1, gender: gender, engineRaw: model, modelID: model, modelName: model)
    }

    var catalog: [VoiceCatalog.Voice] {
        [voice("Heart", "kokoro", "en-US", .female),
         voice("Adam", "kokoro", "en-GB", .male),
         voice("Dora", "kokoro", "es-ES", .female),
         voice("Hans", "phonon", "de-DE", .male),
         voice("Clara", "phonon", "de-DE", .female),
         voice("Alex", "phonon", "en-US", nil)]
    }

    @Test func nothingSelectedOffersEverything() {
        let facets = VoiceFilterSelection().facets(in: catalog)
        #expect(facets.models == ["kokoro", "phonon"])
        #expect(facets.languages == ["en", "es", "de"])
        #expect(facets.genders == ["female", "male", VoiceFilterSelection.unspecifiedGender])
    }

    @Test func aModelOffersOnlyItsLanguagesAndGenders() {
        let facets = VoiceFilterSelection(models: ["kokoro"]).facets(in: catalog)
        #expect(facets.languages == ["en", "es"])
        #expect(facets.genders == ["female", "male"])
        // The model filter itself still offers every model to switch to.
        #expect(facets.models == ["kokoro", "phonon"])
    }

    @Test func aLanguageAndGenderNarrowTheModels() {
        let facets = VoiceFilterSelection(languages: ["de"], genders: ["female"]).facets(in: catalog)
        #expect(facets.models == ["phonon"])
        #expect(facets.genders == ["female", "male"])
        #expect(facets.languages == ["de", "en", "es"])
    }

    @Test func changingTheModelDropsChoicesItCannotOffer() {
        let before = VoiceFilterSelection(models: ["phonon"], languages: ["de"], genders: ["male"])
        var after = before
        after.models = ["kokoro"]
        let adapted = after.adapted(after: before, in: catalog)
        #expect(adapted.models == ["kokoro"])
        #expect(adapted.languages.isEmpty)
        #expect(adapted.genders == ["male"])
    }

    @Test func choicesStillAvailableAreKept() {
        let before = VoiceFilterSelection(languages: ["en"], genders: ["female"])
        var after = before
        after.models = ["kokoro"]
        #expect(after.adapted(after: before, in: catalog) == after)
    }
}
