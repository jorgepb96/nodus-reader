import Foundation
import XCTest
@testable import QwenANE

/// The optional `language` of a render: nil is language auto, bit-identical to a render made before
/// the parameter existed; a known language swaps the prefix's think rows exactly like
/// qonnx.build_icl_prompt. The prompt tests need the models' `host/` tables (QWEN_ANE_MODELS).
final class QwenLanguageTests: XCTestCase {
    private func modelsDirectory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    // MARK: no models needed

    func testBCP47MapsToCodecNames() {
        XCTAssertEqual(QwenLanguage.codecName(for: "es"), "spanish")
        XCTAssertEqual(QwenLanguage.codecName(for: "es-MX"), "spanish")
        XCTAssertEqual(QwenLanguage.codecName(for: "en_US"), "english")
        XCTAssertEqual(QwenLanguage.codecName(for: " EN-gb "), "english")
        XCTAssertEqual(QwenLanguage.codecName(for: "spanish"), "spanish")
        XCTAssertEqual(QwenLanguage.codecName(for: "zh-Hans"), "chinese")
        for none in [nil, "", "  ", "auto", "AUTO", "xx", "tlh-Latn"] as [String?] {
            XCTAssertNil(QwenLanguage.codecName(for: none), "\(none ?? "nil")")
        }
    }

    // MARK: with the host tables

    private func voice(_ hidden: Int = 1024) -> QwenVoiceFiles {
        let T = 12
        return QwenVoiceFiles(refText: "Come in, come in.",
                              refCodes: (0..<16).map { g in (0..<T).map { ($0 * 7 + g * 13) % 2048 } },
                              spkEmbedding: (0..<hidden).map { Float($0 % 17) / 17 })
    }

    func testHostConfigReadsLanguageIDs() throws {
        let host = try HostTables(dir: try modelsDirectory().appendingPathComponent("host").path)
        XCTAssertEqual(host.cfg.codecLanguageIDs["spanish"], 2054)
        XCTAssertEqual(host.cfg.codecLanguageIDs["english"], 2050)
    }

    func testNilAndAutoPromptsAreBitIdentical() throws {
        let host = try HostTables(dir: try modelsDirectory().appendingPathComponent("host").path)
        let text = "Buenas noches, amigo."
        let none = buildICLPrompt(host: host, voice: voice(host.hidden), text: text)
        for auto in [nil, "auto", "", "xx"] as [String?] {
            let p = buildICLPrompt(host: host, voice: voice(host.hidden), text: text, language: auto)
            XCTAssertEqual(p.T, none.T)
            XCTAssertTrue(p.embeds == none.embeds, "language \(auto ?? "nil") changed the prompt")
        }
    }

    func testSpanishPromptSwapsTheThinkRows() throws {
        let host = try HostTables(dir: try modelsDirectory().appendingPathComponent("host").path)
        let c = host.cfg, H = host.hidden
        let text = "Buenas noches, amigo."
        let auto = buildICLPrompt(host: host, voice: voice(host.hidden), text: text)
        let es = buildICLPrompt(host: host, voice: voice(host.hidden), text: text, language: "es-MX")
        XCTAssertEqual(es.T, auto.T + 1, "the language token is one extra prefix row")
        XCTAssertEqual(es.textIds, auto.textIds)
        // Rows 0-2 are the role tokens: untouched.
        XCTAssertTrue(Array(es.embeds[0..<3 * H]) == Array(auto.embeds[0..<3 * H]))
        // Everything after the prefix (text + codec ICL) is the same, shifted by one row.
        let esTail: Int = 10 * H, autoTail: Int = 9 * H        // after 3 role + 7 (6 + language) prefix rows
        let esRest: [Float] = Array(es.embeds[esTail...]), autoRest: [Float] = Array(auto.embeds[autoTail...])
        XCTAssertTrue(esRest == autoRest)
        // The prefix rows are tts_pad + codec row: [think, think_bos, spanish, think_eos, spk, pad] then bos.
        let tts = host.textProj([c.ttsBos, c.ttsEos, c.ttsPad])
        let pad = Array(tts[2 * H..<3 * H])
        let ids = [c.codecThink, c.codecThinkBos, 2054, c.codecThinkEos]
        for (r, id) in ids.enumerated() {
            let codec = host.codecRow(id)
            let row = Array(es.embeds[(3 + r) * H..<(3 + r + 1) * H])
            XCTAssertEqual(row, (0..<H).map { pad[$0] + codec[$0] }, "prefix row \(r)")
        }
        XCTAssertNotEqual(es.embeds, buildICLPrompt(host: host, voice: voice(host.hidden), text: text, language: "en").embeds)
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testRenderWithoutLanguageIsUnchangedAndLanguageChangesIt() throws {
        try QwenTestModels.requireSlow()
        let engine = try QwenTestModels.engine()
        let v = try engine.loadVoice(named: "jeff")
        let text = "Good evening, you are tuned in."
        let base = try engine.render(text: text, voice: v, seed: 5, maxFrames: 24)
        let auto = try engine.render(text: text, voice: v, seed: 5, maxFrames: 24, language: "auto")
        let nilLang = try engine.render(text: text, voice: v, seed: 5, maxFrames: 24, language: nil)
        XCTAssertTrue(base.samples == auto.samples && base.codes == auto.codes)
        XCTAssertTrue(base.samples == nilLang.samples && base.codes == nilLang.codes)
        let es = try engine.render(text: text, voice: v, seed: 5, maxFrames: 24, language: "es")
        XCTAssertNotEqual(es.codes, base.codes, "a language token must reach the talker")
        XCTAssertEqual(try engine.maxFrames(text: text, voice: v, language: "es") <= (try engine.maxFrames(text: text, voice: v)), true)
    }
}
