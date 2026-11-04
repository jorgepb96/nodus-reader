import Foundation
import XCTest
@testable import QwenANE

/// Shared setup for the model-backed Qwen tests.
///
/// - `QWEN_ANE_MODELS=/path/to/qwen3-0.6b-ane` turns the model-backed tests on (skipped without it).
/// - `QWEN_SLOW_TESTS=1` also runs the slow ones: full-line renders, Python/ORT parity, timing and
///   measurement runs. The default `swift test` keeps only pure logic, header/table checks and a few
///   frame-capped renders that smoke the model. Before merging an engine change run the lot, optimised:
///     QWEN_SLOW_TESTS=1 QWEN_ANE_MODELS=... swift test -c release --filter QwenANE
enum QwenTestModels {
    static func directory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    /// Skips unless `QWEN_SLOW_TESTS=1`.
    static func requireSlow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QWEN_SLOW_TESTS"] == "1",
                          "slow real-model test: set QWEN_SLOW_TESTS=1 to run it")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: AnyObject?

    /// One engine for the whole test process (building one loads ~1.3 GB of Core ML models). Every call
    /// hands it back reset: default options, no forcing or fault injection, caches dropped.
    @available(iOS 18.0, macOS 15.0, *)
    static func engine() throws -> QwenANEEngine {
        let dir = try directory()
        lock.lock(); defer { lock.unlock() }
        let e: QwenANEEngine
        if let c = cached as? QwenANEEngine { e = c } else { e = try QwenANEEngine(modelsDirectory: dir); cached = e }
        e.options = QwenANEEngine.Options()
        e.talker.forced = nil
        e.talker.injectNaNLogitsAtFrame = nil
        e.talker.injectNaNSubCodesAtFrame = nil
        e.dropCaches()
        return e
    }
}
