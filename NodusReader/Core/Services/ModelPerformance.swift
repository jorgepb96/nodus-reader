// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
#if os(iOS)
import AVFoundation
#endif

struct NarrationModelMetadata {
    let languages: [String]
    let parameters: String
    let naturalness: Int
    let estimatedSpeed: Double
    let codeLicense: String
    let clones: Bool
    var precision: String { parameters == "0.5B" ? "INT8" : ["41.4M", "0.6B"].contains(parameters) ? "FP16" : "Core ML" }
}

extension ModelManager.Model {
    @MainActor private var systemLanguageCodes: [String] { VoiceCatalog.systemLanguageCodes }
    @MainActor var metadata: NarrationModelMetadata {
        switch engine {
        case .system: .init(languages: systemLanguageCodes, parameters: "", naturalness: 1, estimatedSpeed: 8, codeLicense: "Apple", clones: false)
        case .qwen: .init(languages: QwenSpeech.languages, parameters: "0.6B", naturalness: 5, estimatedSpeed: 0.9, codeLicense: "MIT", clones: true)
        case .ming: .init(languages: ["es-ES", "en-US", "fr-FR", "de-DE", "zh-CN", "ja-JP", "ko-KR"], parameters: "0.5B", naturalness: 5, estimatedSpeed: 1, codeLicense: "MIT", clones: true)
        case .kokoro: .init(languages: ["en-US", "en-GB", "es-ES"], parameters: "82M", naturalness: 4, estimatedSpeed: 4, codeLicense: "Apache-2.0", clones: false)
        case .phonon: .init(languages: id == "phonon-31m-en" ? ["en-US"] : id == "phonon-40m-es" ? ["es-ES", "es-MX"] : ["en-US", "es-ES", "fr-FR", "de-DE", "pt-PT"], parameters: id == "phonon-31m-en" ? "31M" : "40M", naturalness: id == "phonon-31m-en" ? 3 : 4, estimatedSpeed: 6, codeLicense: "Apache-2.0", clones: false)
        case .linnet: .init(languages: ["en-US"], parameters: "41.4M", naturalness: 3, estimatedSpeed: 10, codeLicense: "Apache-2.0", clones: false)
        }
    }
}

@MainActor @Observable
final class ModelPerformance {
    struct Sample: Codable { var seconds: Double; var audio: Double }
    private var samples: [String: [Sample]]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        samples = (defaults.data(forKey: "nodus.modelPerformance.v1").flatMap { try? JSONDecoder().decode([String: [Sample]].self, from: $0) }) ?? [:]
    }
    private func key(_ model: ModelManager.Model) -> String {
        let revision = model.engine == .qwen ? QwenModels.revision : model.engine == .linnet ? LinnetModels.revision : "catalog1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        return "\(model.id)|\(revision)|\(build)|\(ProcessInfo.processInfo.operatingSystemVersionString)|\(ProcessInfo.processInfo.processorCount)|\(ProcessInfo.processInfo.physicalMemory)"
    }
    func record(model: ModelManager.Model, seconds: Double, audio: Double) {
        guard seconds.isFinite, audio.isFinite, seconds > 0, audio > 0 else { return }
        let key = key(model)
        samples[key] = Array(((samples[key] ?? []) + [Sample(seconds: seconds, audio: audio)]).suffix(30))
        if let data = try? JSONEncoder().encode(samples) { defaults.set(data, forKey: "nodus.modelPerformance.v1") }
    }
    func speed(_ model: ModelManager.Model) -> (value: Double, measured: Bool) {
        let values = samples[key(model)] ?? []
        let duration = values.reduce(0) { $0 + $1.audio }
        guard values.count >= 3, duration >= 30 else {
            let constrained = ProcessInfo.processInfo.physicalMemory < 6_000_000_000
            return (model.metadata.estimatedSpeed * (constrained ? 0.75 : 1), false)
        }
        return (duration / values.reduce(0) { $0 + $1.seconds }, true)
    }
    nonisolated static func bars(_ speed: Double) -> Int {
        speed < 1 ? 1 : speed < 2 ? 2 : speed < 4 ? 3 : speed < 8 ? 4 : 5
    }
}
