// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Testing
@testable import Nodus_Reader

private func joined(_ text: String) -> [String] {
    let ns = text as NSString
    return NarrationPacing.joiningShortSentences(SentenceTokenizer.ranges(from: text), in: ns)
        .map { ns.substring(with: $0) }
}

@Test func briskJoinsAShortSentenceToTheNextOne() {
    let text = "The door creaked open. Somewhere below, a floorboard groaned under a careful weight."
    #expect(joined(text) == [text])
}

@Test func briskJoinsAShortLastSentenceToThePreviousOne() {
    let text = "Old Teodor simply sat down on a crate and lit his pipe without a word. Nobody argued."
    #expect(joined(text) == [text])
}

@Test func briskKeepsLongSentencesApart() {
    let text = "The merchants argued about whether to cross before dark. Old Teodor sat down on a crate and lit his pipe."
    #expect(joined(text).count == 2)
}

@Test func briskNeverJoinsAcrossParagraphs() {
    let text = "She took one step back.\n\nThe library had been closed for nearly a decade, and dust covered every shelf."
    #expect(joined(text) == ["She took one step back.",
                             "The library had been closed for nearly a decade, and dust covered every shelf."])
}

@Test func briskKeepsJoinedSentencesShort() {
    let long = "The caravan crossed the river at dawn, and the merchants, who had argued all night about the ferry, "
        + "the weather and the price of salt in the northern markets, finally fell silent as the cold water rose "
        + "to the axles of their heavy wagons and the oxen pulled them slowly toward the far bank."
    #expect(long.utf16.count > NarrationPacing.maximumJoinedLength)
    let text = "He waited. " + long
    #expect(SentenceTokenizer.ranges(from: text).count == 2)
    #expect(joined(text).count == 2)
}

@Test func briskSentencesCoverTheOriginalText() {
    let chapters = [ExtractedChapter(id: 0, title: "One", text: "Kai dodged left. The blade missed his throat by an inch.\n\nSomething cracked.")]
    let natural = PlaybackController.buildSentences(from: chapters)
    let brisk = PlaybackController.buildSentences(from: chapters, joiningShortSentences: true)
    #expect(natural.map(\.text) == ["Kai dodged left.", "The blade missed his throat by an inch.", "Something cracked."])
    #expect(brisk.map(\.text) == ["Kai dodged left. The blade missed his throat by an inch.", "Something cracked."])
    #expect(brisk.map(\.id) == [0, 1])
    #expect(brisk[0].chapterOffset == 0)
    #expect(brisk[1].chapterOffset == natural[2].chapterOffset)
}

@Test func briskPausesFollowPunctuation() {
    #expect(NarrationPacing.pause(after: "It was over.", before: "She left.", newParagraph: false) == 0.30)
    #expect(NarrationPacing.pause(after: "Was it over?", before: "She left.", newParagraph: false) == 0.38)
    #expect(NarrationPacing.pause(after: "Again and again\u{2026}", before: "Nothing.", newParagraph: false) == 0.50)
    #expect(NarrationPacing.pause(after: "It was over.", before: "She left.", newParagraph: true) == 0.55)
    // A new speaker answers.
    let turn = NarrationPacing.pause(after: "\u{201C}You\u{2019}re late.\u{201D}", before: "\u{201C}The bridge was out.\u{201D}",
                                     newParagraph: false)
    #expect(abs(turn - 0.40) < 0.0001)
}

@Test func briskFindsWhereTheVoiceStartsAndStops() throws {
    let rate = 24_000.0
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    // 0.3 s of silence, 1 s of tone, 0.5 s of silence.
    let samples = Int(rate * 1.8)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)))
    buffer.frameLength = AVAudioFrameCount(samples)
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<samples {
        let time = Double(index) / rate
        channel[index] = time >= 0.3 && time < 1.3 ? Float(sin(2 * .pi * 220 * time) * 0.5) : 0
    }
    let speech = NarrationPacing.speechBounds(of: buffer)
    #expect(abs(speech.start - 0.26) < 0.015)
    #expect(abs(speech.end - 1.38) < 0.015)

    let excerpt = try #require(PlaybackController.excerpt(buffer, from: speech.start, to: speech.end))
    #expect(abs(Double(excerpt.frameLength) / rate - (speech.end - speech.start)) < 0.001)
}

@Test func silentAudioKeepsItsLength() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    let speech = NarrationPacing.speechBounds(of: buffer)
    #expect(speech.start == 0)
    #expect(abs(speech.end - 0.1) < 0.0001)
}
