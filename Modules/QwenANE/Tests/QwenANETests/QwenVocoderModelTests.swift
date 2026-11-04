import XCTest
@testable import QwenANE

/// upMall ships as a fixed-shape multifunction model ("w12", "w20"); an older enumerated-shape one has no
/// functions. The vocoder tells them apart from the compiled model's metadata.json.
@available(macOS 15.0, *)
final class QwenVocoderModelTests: XCTestCase {
    private func model(_ metadata: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocoder-\(UUID().uuidString)/upMall.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let metadata { try metadata.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        return dir
    }

    func testMultifunctionModelListsItsFunctions() throws {
        let m = try model(#"[{"defaultFunctionName": "w12", "functions": [{"name": "w12"}, {"name": "w20"}]}]"#)
        XCTAssertEqual(ANEVocoder.functions(of: m), ["w12", "w20"])
    }

    func testEnumeratedShapeModelHasNoFunctions() throws {
        XCTAssertEqual(ANEVocoder.functions(of: try model(#"[{"generatedClassName": "upMall_C12_L8_fp16"}]"#)), [])
    }

    func testMissingOrBrokenMetadataHasNoFunctions() throws {
        XCTAssertEqual(ANEVocoder.functions(of: try model(nil)), [])
        XCTAssertEqual(ANEVocoder.functions(of: try model("not json")), [])
    }
}
