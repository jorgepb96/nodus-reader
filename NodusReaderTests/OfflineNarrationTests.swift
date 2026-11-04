// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Testing
@testable import Nodus_Reader

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor
private func testPlan(cache: NarrationAudioCache, bookID: UUID = UUID(), voice: String = "test") -> OfflineNarrationPlan {
    let sentences = (0..<6).map { i in
        let text = "Sentence \(i)."
        return OfflineNarrationPlan.Sentence(text: text, key: cache.key(text: text, engine: "test", voice: voice), chapterIndex: i / 2, offset: (i % 2) * 20)
    }
    return OfflineNarrationPlan(id: UUID(), bookID: bookID, bookHash: "hash", title: "Test book", voiceID: voice, voiceName: voice,
        engine: "test", pronunciationRevision: "", createdAt: Date(), sentences: sentences,
        units: (0..<3).map { .init(id: $0, title: "Chapter \($0 + 1)", start: $0 * 2, end: $0 * 2 + 2) })
}

private func saveTestAudio(cache: NarrationAudioCache, plan: OfflineNarrationPlan, sentence: OfflineNarrationPlan.Sentence) async throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
    buffer.frameLength = 4_800
    for i in 0..<4_800 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.1 }
    let bytes = await cache.save(bookID: plan.bookID, key: sentence.key, buffer: buffer, words: [])
    #expect(bytes > 0)
}

@Test @MainActor
func progressiveAudioStopsAtWindowAndExtendsWithoutRepeatingSavedSentences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = NarrationAudioCache(root: root.appendingPathComponent("Audio"))
    let queue = OfflineNarrationQueue(root: root.appendingPathComponent("Jobs"), cache: cache)
    let plan = testPlan(cache: cache)
    var rendered: [String] = []
    queue.configure(available: { _ in true }, idle: { true }, render: { plan, sentence in
        rendered.append(sentence.text); try await saveTestAudio(cache: cache, plan: plan, sentence: sentence)
    })
    try queue.enqueue(plan, lookAhead: 2)
    try await waitFor { queue.jobs.first?.state.status == .caughtUp }
    #expect(rendered == plan.sentences.prefix(4).map(\.text))
    #expect(queue.jobs.first?.progress == 1)
    queue.updateReadingPosition(bookID: plan.bookID, chapterIndex: 1, fraction: 0)
    try await waitFor { queue.jobs.first?.state.completed.count == 6 }
    #expect(rendered == plan.sentences.map(\.text))
    queue.updateReadingPosition(bookID: plan.bookID, chapterIndex: 0, fraction: 0)
    #expect(rendered.count == 6)
    await queue.deleteAudio(plan.id, unit: plan.units[1])
    #expect(queue.jobs.first?.state.status == .paused)
    #expect(await cache.contains(bookID: plan.bookID, key: plan.sentences[0].key))
    #expect(!(await cache.contains(bookID: plan.bookID, key: plan.sentences[2].key)))
    queue.resume(plan.id)
    try await waitFor { queue.jobs.first?.state.status == .caughtUp }
    #expect(rendered.count == 8)
}

@Test @MainActor
func queuedAudioRestoresUserPauseAndRechecksEvictedCacheOnResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = NarrationAudioCache(root: root.appendingPathComponent("Audio"))
    let path = root.appendingPathComponent("Jobs")
    let first = OfflineNarrationQueue(root: path, cache: cache)
    let plan = testPlan(cache: cache)
    var busy = true
    var count = 0
    first.configure(available: { _ in true }, idle: { !busy }, render: { plan, sentence in
        count += 1; try await saveTestAudio(cache: cache, plan: plan, sentence: sentence)
    })
    try first.enqueue(plan)
    first.pause(plan.id)
    let restored = OfflineNarrationQueue(root: path, cache: cache)
    #expect(restored.jobs.first?.state.status == .paused)
    restored.configure(available: { _ in true }, idle: { !busy }, render: { plan, sentence in
        count += 1; try await saveTestAudio(cache: cache, plan: plan, sentence: sentence)
    })
    busy = false
    restored.resourcesDidChange()
    #expect(count == 0)
    restored.resume(plan.id)
    try await waitFor { restored.jobs.first?.state.status == .completed }
    #expect(count == 6)
    await cache.delete(bookID: plan.bookID, keys: [plan.sentences[2].key])
    restored.resume(plan.id)
    try await waitFor { restored.jobs.first?.state.status == .completed }
    #expect(count == 7)
}

@Test @MainActor
func offlinePlannerKeepsSentencesWholeAcrossParagraphBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = NarrationAudioCache(root: root)
    let book = Book(title: "Text", author: "", format: .txt, fileName: "t.txt", relativePath: "t.txt", fileSize: 0, contentHash: "hash")
    let voice = VoiceCatalog.Voice(id: "test", name: "Test", language: "en", languageName: "English", quality: 3, engineRaw: "phonon", modelID: "test")
    let text = "An unfinished clause\n\ncontinues until this sentence ends. Another sentence.\n\nThe last paragraph."
    let plan = OfflineNarrationPlan.make(book: book, chapters: [.init(id: 0, title: "Text", text: text)], voice: voice, paragraphsPerBlock: 1, cache: cache)
    #expect(plan.isValid)
    #expect(plan.units.count >= 2)
    let firstUnit = try #require(plan.units.first)
    let firstPart = firstUnit.indices.map { plan.sentences[$0].text }.joined(separator: " ")
    #expect(firstPart.contains("An unfinished clause"))
    #expect(firstPart.contains("continues until this sentence ends."))
    #expect(plan.units.flatMap { Array($0.indices) } == Array(plan.sentences.indices))
    #expect(plan.sentences.map(\.text).joined(separator: " ").contains("Another sentence."))
    let japanese = OfflineNarrationPlan.make(book: book,
        chapters: [.init(id: 0, title: "Text", text: "最初の段落です。\n\n「次の段落です。」\n\n最後の段落です。")],
        voice: voice, paragraphsPerBlock: 1, cache: cache)
    #expect(japanese.units.count == 3)
}

@Test @MainActor
func offlineAudioYieldsToInteractiveUseAndResumesItsUnfinishedSentence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = NarrationAudioCache(root: root.appendingPathComponent("Audio"))
    let queue = OfflineNarrationQueue(root: root.appendingPathComponent("Jobs"), cache: cache)
    let plan = testPlan(cache: cache)
    let (events, sender) = AsyncStream<String>.makeStream()
    var event = events.makeAsyncIterator()
    var started = 0
    queue.configure(available: { _ in true }, idle: { true }, render: { plan, sentence in
        started += 1; sender.yield(sentence.text)
        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
        try await saveTestAudio(cache: cache, plan: plan, sentence: sentence)
    })
    try queue.enqueue(plan, lookAhead: 1)
    #expect(await event.next() == plan.sentences[0].text)
    queue.setInteractiveBusy(true)
    try await waitFor { queue.jobs.first?.state.status == .waiting }
    #expect(queue.jobs.first?.state.completed.isEmpty == true)
    queue.setInteractiveBusy(false)
    try await waitFor { queue.jobs.first?.state.status == .caughtUp }
    #expect(started == 3)
    #expect(queue.jobs.first?.state.completed == [0, 1])
}

@Test
func studioTrimsAWindowFromALongFileAndRejectsInvalidRanges() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: url) }
    // The selected second half has a different pitch, so checking its sample
    // content also verifies seeking, rather than only the output duration.
    let count = Int(StudioVoiceStore.sampleRate * 42)
    let samples = (0..<count).map { i in sin(Float(i) * (i < count / 2 ? 0.03 : 0.12)) * 0.2 }
    try StudioVoiceStore.writeWAV(samples, to: url)
    #expect(try StudioVoiceStore.duration(url: url) > 41)
    #expect(throws: StudioVoiceStore.StoreError.self) { try StudioVoiceStore.prepare(url: url) }
    let clip = try StudioVoiceStore.prepare(url: url, start: 25, duration: 6, maximumSeconds: 20)
    #expect(clip.durationS >= 5.9 && clip.durationS <= 6)
    let crossings = zip(clip.samples, clip.samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    #expect(crossings > 4_000)
    #expect(throws: StudioVoiceStore.StoreError.self) { try StudioVoiceStore.prepare(url: url, start: .nan, duration: 6, maximumSeconds: 20) }
    #expect(throws: StudioVoiceStore.StoreError.self) { try StudioVoiceStore.prepare(url: url, start: 0, duration: 21, maximumSeconds: 20) }
    #expect(StudioVoiceStore.maximumSeconds(for: .qwen) == 20)
    #expect(StudioVoiceStore.maximumSeconds(for: .ming) == 30)
}
