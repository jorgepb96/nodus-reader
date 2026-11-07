// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite("Scene emotion and situation")
struct SceneEmotionTests {
    private let base = "kind=scene; setting=forest; clarity=2; weather=rain; tone=eerie; action=chase; intensity=3; change=none; evidence=the wolves ran through the rain"
    private let passage = "At night the wolves ran through the rain after them."

    @Test func oldReadingsDecodeWithoutNewFields() throws {
        let json = #"{"passageKind":"scene","setting":"forest","settingClarity":2,"weather":"rain","tone":"eerie","action":"chase","intensity":3,"sceneChange":"none","evidence":"x","evidenceVerified":false,"source":"contentTagging"}"#
        let reading = try JSONDecoder().decode(SceneReading.self, from: Data(json.utf8))
        #expect(reading.emotion == nil && reading.situation == nil)
        #expect(reading.effectiveEmotion == .dread && reading.effectiveSituation == .chase)
    }

    @Test func lineParserAcceptsEmotionAndSituation() throws {
        let reading = try #require(SceneLineParser.parse(base + "; emotion=fear; situation=escape", passage: passage))
        #expect(reading.emotion == .fear && reading.situation == .escape)
        #expect(reading.effectiveEmotion == .fear && reading.effectiveSituation == .escape)
    }

    @Test func lineParserTreatsNoneAndMissingAsNil() throws {
        let none = try #require(SceneLineParser.parse(base + "; emotion=none; situation=none", passage: passage))
        #expect(none.emotion == nil && none.situation == nil)
        let missing = try #require(SceneLineParser.parse(base, passage: passage))
        #expect(missing.emotion == nil)
    }

    @Test func lineParserRejectsUnknownEmotion() {
        #expect(SceneLineParser.parse(base + "; emotion=hungry", passage: passage) == nil)
        #expect(SceneLineParser.parse(base + "; situation=shopping", passage: passage) == nil)
    }

    @Test func analyzerVersionChanged() {
        #expect(SceneMap.analyzerVersion == 2)
        #expect(ScenePrompt.lineFormat.contains("emotion=") && ScenePrompt.lineFormat.contains("situation="))
    }
}
