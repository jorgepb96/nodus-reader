// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import StableAudioMLX
import Testing
@testable import Nodus_Reader

@MainActor
private func models() -> (SoundscapeModels, SA3ModelDirectory) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID())", isDirectory: true)
    let models = SoundscapeModels(root: base.appendingPathComponent("Models"), downloads: base.appendingPathComponent("Downloads"))
    return (models, models.directory)
}

/// Writes empty stand-ins for converted files.
private func touch(_ urls: [URL]) {
    for url in urls {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 8))
    }
}

private func shared(_ directory: SA3ModelDirectory) -> [URL] {
    [directory.tokenizer, directory.t5, directory.decoder, directory.encoder]
}

private func component(_ directory: SA3ModelDirectory, _ kind: SA3ModelKind) -> [URL] {
    [directory.dit(kind), directory.conditioner(kind)]
}

@MainActor
@Suite("Soundscape models")
struct SoundscapeModelsTests {
    @Test func requiredSpaceIncludesConversion() {
        let (models, _) = models()
        let music = (SA3Manifest.shared + [SA3Manifest.music]).reduce(Int64(0)) { $0 + $1.bytes }
        #expect(models.requiredFreeBytes(for: [.music]) == music + SoundscapeModels.conversionMargin)
        let both = (SA3Manifest.shared + [SA3Manifest.music, SA3Manifest.sfx]).reduce(Int64(0)) { $0 + $1.bytes }
        #expect(models.requiredFreeBytes(for: [.music, .sfx]) == both + SoundscapeModels.conversionMargin)
    }

    @Test func installedComponentsNeedNoSpace() {
        let (models, directory) = models()
        touch(shared(directory) + component(directory, .music))
        models.refresh()
        #expect(models.isInstalled(.music) && !models.isInstalled(.sfx))
        #expect(models.requiredFreeBytes(for: [.music]) == 0)
        #expect(models.requiredFreeBytes(for: [.sfx]) == SA3Manifest.sfx.bytes + SoundscapeModels.conversionMargin)
    }

    @Test func removingMusicKeepsSharedWhileSfxInstalled() {
        let (models, directory) = models()
        touch(shared(directory) + component(directory, .music) + component(directory, .sfx))
        models.refresh()
        models.remove(.music)
        #expect(!models.isInstalled(.music) && models.isInstalled(.sfx))
        #expect(shared(directory).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func removingLastRemovesShared() {
        let (models, directory) = models()
        touch(shared(directory) + component(directory, .music))
        models.refresh()
        models.remove(.music)
        #expect(!models.anyInstalled)
        #expect(shared(directory).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(models.bytesOnDisk == 0)
    }

    @Test func unsupportedInSimulator() {
        #if targetEnvironment(simulator)
        #expect(!SoundscapeModels.isSupported)
        #else
        #expect(SoundscapeModels.isSupported)
        #endif
    }
}
