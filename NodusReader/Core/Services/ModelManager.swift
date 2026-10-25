// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import KokoroTTS
import MLX
import Observation
import PhononTTS
import Security
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let nodusVoiceEngineChanged = Notification.Name("nodus.voiceEngineChanged")
}

/// Device-local management of the optional neural narration engines.
///
/// Weight files are downloaded on request into Application Support, are excluded
/// from backup and iCloud sync, and can be deleted at any time. Nothing here is
/// uploaded; the app never contacts a Nodus server.
@MainActor
@Observable
final class ModelManager {
    enum Engine: String, Sendable {
        case kokoro
        case phonon

        var label: String {
            switch self {
            case .kokoro: String(localized: "Kokoro")
            case .phonon: String(localized: "Phonon")
            }
        }
    }

    enum Availability: Sendable {
        case available
        case unavailable(String)
    }

    struct Voice: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let language: String
        let engine: Engine
    }

    struct Model: Identifiable, Sendable {
        let id: String
        let engine: Engine
        let name: String
        let detail: String
        let language: String
        let sizeText: String
        let license: String
        let source: URL
        let voices: [Voice]
        let availability: Availability
        /// The publisher asks for a signed-in account that accepted the
        /// licence on Hugging Face before the files can be downloaded.
        var requiresAcceptedLicense = false

        var isAvailable: Bool {
            if case .available = availability { return true }
            return false
        }

        var availabilityNote: String? {
            if case .unavailable(let note) = availability { return note }
            return nil
        }
    }

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case paused(Double)
        case loading
        case installed
        case failed(String)

        var isInstalled: Bool { self == .installed }
        var isBusy: Bool {
            switch self {
            case .downloading, .loading: true
            default: false
            }
        }
    }

    struct StorageSummary: Equatable {
        var kokoroBytes: Int64 = 0
        var phononBytes: Int64 = 0
        var narrationCacheBytes: Int64 = 0
        var totalBytes: Int64 { kokoroBytes + phononBytes + narrationCacheBytes }
    }

    private(set) var states: [String: State] = [:]
    private(set) var storage = StorageSummary()
    private(set) var selectedModelID: String
    private(set) var errorMessage: String?

    private let voices: VoiceCatalog
    private let audioCache: NarrationAudioCache
    private let defaults: UserDefaults
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var installTokens: [String: UUID] = [:]
    @ObservationIgnored private var engineLoadTask: Task<Void, Never>?
    @ObservationIgnored private var engineLoadToken = UUID()

    @ObservationIgnored private var kokoro: KokoroTTS?
    @ObservationIgnored private var phonon: Phonon?

    // Memory: loaded engines hold hundreds of MB of Core ML models (and Kokoro
    // MLX buffers). They are released when narration has not needed them for
    // a while, when the app goes to the background without narrating, and on
    // a memory warning; the next sentence loads them again.
    static let idleUnloadDelay: Duration = .seconds(180)
    @ObservationIgnored private var narrationInUse = false
    @ObservationIgnored private var synthesesInFlight = 0
    @ObservationIgnored private var idleUnloadTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    nonisolated private static let kokoroCacheDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Kokoro", isDirectory: true)

    nonisolated private static let phononDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Phonon", isDirectory: true)

    /// Pinned Hugging Face revision used for the public Phonon 31M Core ML bundle.
    /// The bundle's own `bundle.json` verifies the size and SHA-256 of every file.
    static let systemModelID = "system"

    static let phononBundleBase = URL(string:
        "https://huggingface.co/mosiah/phonon-31m-en-coreml/resolve/0a2596e9154f0340005b6445514fdd57f7bc9ddb"
    )!

    let models: [Model] = [
        Model(
            id: "kokoro-82m",
            engine: .kokoro,
            name: "Kokoro 82M",
            detail: String(localized: "Expressive American and British English narration with 28 voices."),
            language: String(localized: "English"),
            sizeText: String(localized: "About 210 MB download"),
            license: "Apache-2.0",
            source: URL(string: "https://huggingface.co/mattmireles/kokoro-coreml")!,
            voices: ModelManager.kokoroVoices,
            availability: {
                #if targetEnvironment(simulator)
                .unavailable(String(localized: "Kokoro's English phonemizer uses MLX, which needs a Metal GPU. The Simulator does not provide one. Install Kokoro on an iPhone, iPad or Mac; Phonon and system voices work in the Simulator."))
                #else
                .available
                #endif
            }()
        ),
        Model(
            id: "phonon-31m-en",
            engine: .phonon,
            name: "Phonon 31M",
            detail: String(localized: "Streaming English speech with nine built-in voices."),
            language: String(localized: "English"),
            sizeText: String(localized: "About 300 MB download"),
            license: "Apache-2.0",
            source: URL(string: "https://huggingface.co/mosiah/phonon-31m-en-coreml")!,
            voices: ModelManager.phononVoices,
            availability: .available
        ),
        Model(
            id: "phonon-40m-es",
            engine: .phonon,
            name: String(localized: "Phonon 40M Spanish"),
            detail: String(localized: "Spanish Phonon checkpoint."),
            language: String(localized: "Spanish"),
            sizeText: String(localized: "Not available"),
            license: "CC BY-NC 4.0",
            source: URL(string: "https://huggingface.co/gradium/phonon-40m-es")!,
            voices: [],
            availability: .unavailable(
                String(localized: "Signing in to Hugging Face does not make this model downloadable yet. Gradium publishes it only in formats for computers (PyTorch and GGUF), and Nodus Reader runs voices with Core ML, Apple's on-device format. No Core ML version of this model exists, so it cannot run on iPhone, iPad or Mac in this version.")
            ),
            requiresAcceptedLicense: true
        ),
        Model(
            id: "phonon-40m-multilingual",
            engine: .phonon,
            name: String(localized: "Phonon 40M Multilingual"),
            detail: String(localized: "Multilingual Phonon checkpoint."),
            language: String(localized: "Multilingual"),
            sizeText: String(localized: "Not available"),
            license: "CC BY-NC 4.0",
            source: URL(string: "https://huggingface.co/gradium/phonon-40m-multilingual")!,
            voices: [],
            availability: .unavailable(
                String(localized: "Signing in to Hugging Face does not make this model downloadable yet. Gradium publishes it only in formats for computers (PyTorch and GGUF), and Nodus Reader runs voices with Core ML, Apple's on-device format. No Core ML version of this model exists, so it cannot run on iPhone, iPad or Mac in this version.")
            ),
            requiresAcceptedLicense: true
        )
    ]

    init(voices: VoiceCatalog,
         audioCache: NarrationAudioCache = NarrationAudioCache(),
         defaults: UserDefaults = .standard) {
        self.voices = voices
        self.audioCache = audioCache
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: "nodus.models.selected") ?? Self.systemModelID
        Self.excludeFromBackup(Self.kokoroCacheDirectory)
        Self.excludeFromBackup(Self.phononDirectory)
        refreshStates()
        validateSelection()
        publishVoices()
        observeMemoryPressure()
    }

    var selectedModel: Model? {
        models.first { $0.id == selectedModelID }
    }

    var isSystemSelected: Bool { selectedModelID == Self.systemModelID }

    func isSelected(_ model: Model) -> Bool {
        selectedModelID == model.id
    }

    /// Selects the engine whose voices are exposed to the rest of the app.
    /// Selecting a model also makes its first voice the default; the system
    /// option restores the best installed system voice.
    func selectModel(_ id: String) {
        engineLoadTask?.cancel()
        engineLoadTask = nil
        engineLoadToken = UUID()
        if id == Self.systemModelID {
            // No neural engine is selected: its models leave memory now.
            releaseEngines(keeping: nil)
            selectedModelID = id
            defaults.set(id, forKey: "nodus.models.selected")
            publishVoices()
            if let system = voices.bestSystemVoice {
                voices.setDefault(system)
            }
            NotificationCenter.default.post(name: .nodusVoiceEngineChanged, object: nil)
            return
        }
        guard let model = models.first(where: { $0.id == id }),
              model.isAvailable,
              isInstalled(model) else { return }
        selectedModelID = id
        defaults.set(id, forKey: "nodus.models.selected")
        // Only one neural engine stays in memory: the one just selected.
        releaseEngines(keeping: model.engine)
        publishVoices()
        if let first = voices.voice(withID: model.voices.first?.id) {
            voices.setDefault(first)
        }
        NotificationCenter.default.post(name: .nodusVoiceEngineChanged, object: nil)
    }

    func selectModel(_ model: Model) {
        selectModel(model.id)
    }

    private func validateSelection() {
        if selectedModelID != Self.systemModelID,
           !(selectedModel.map { $0.isAvailable && isInstalled($0) } ?? false) {
            selectedModelID = Self.systemModelID
            defaults.set(selectedModelID, forKey: "nodus.models.selected")
        }
    }

    var kokoroDirectory: URL { Self.kokoroCacheDirectory }
    var phononModelDirectory: URL { Self.phononDirectory }
    var narrationCache: NarrationAudioCache { audioCache }

    // MARK: State

    func state(for model: Model) -> State {
        states[model.id] ?? (isInstalled(model) ? .installed : .notInstalled)
    }

    func isInstalled(_ model: Model) -> Bool {
        guard model.isAvailable else { return false }
        switch model.engine {
        case .kokoro:
            return model.id == "kokoro-82m" && Self.kokoroBundleIsComplete(at: Self.kokoroCacheDirectory)
        case .phonon:
            return model.id == "phonon-31m-en" && PhononModels.isInstalled(at: Self.phononDirectory)
        }
    }

    /// The manifest is only useful when every asset it lists actually exists.
    /// Checking just the manifest lets a cancelled download look installed and
    /// leaves the model selected but unable to load.
    nonisolated private static func kokoroBundleIsComplete(at directory: URL) -> Bool {
        let manifestURL = directory.appendingPathComponent("KokoroRuntimeManifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        var paths: [String] = []
        if let runtime = object["runtime_assets"] as? [String: Any] {
            for value in runtime.values {
                if let item = value as? [String: Any], let path = item["path"] as? String {
                    paths.append(path)
                }
            }
        }
        if let voices = object["voices"] as? [[String: Any]] {
            paths.append(contentsOf: voices.compactMap { $0["path"] as? String })
        }
        if let packages = object["model_packages"] as? [[String: Any]] {
            paths.append(contentsOf: packages.compactMap { $0["path"] as? String })
        }
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { path in
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
        }
    }

    func refreshStates() {
        for model in models {
            if states[model.id] == nil || states[model.id] == .notInstalled || states[model.id]?.isInstalled == true {
                states[model.id] = isInstalled(model) ? .installed : .notInstalled
            }
        }
        Task { await refreshStorage() }
    }

    func refreshStorage() async {
        var summary = StorageSummary()
        let sizes = await Task.detached(priority: .utility) {
            (Self.directorySize(Self.kokoroCacheDirectory), Self.directorySize(Self.phononDirectory))
        }.value
        summary.kokoroBytes = sizes.0
        summary.phononBytes = sizes.1
        summary.narrationCacheBytes = await audioCache.totalBytes()
        storage = summary
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: Install

    func install(_ model: Model) {
        guard model.isAvailable else { return }
        guard installTasks[model.id] == nil else { return }
        states[model.id] = .downloading(0)
        errorMessage = nil
        let token = UUID()
        installTokens[model.id] = token
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performInstall(model, token: token)
        }
        installTasks[model.id] = task
    }

    func pause(_ model: Model) {
        guard case .downloading(let progress) = state(for: model) else { return }
        installTasks[model.id]?.cancel()
        installTasks[model.id] = nil
        installTokens[model.id] = nil
        states[model.id] = .paused(progress)
    }

    func resume(_ model: Model) {
        guard case .paused = state(for: model) else { return }
        install(model)
    }

    func delete(_ model: Model) {
        engineLoadTask?.cancel()
        engineLoadTask = nil
        engineLoadToken = UUID()
        let cancelledInstall = installTasks[model.id]
        cancelledInstall?.cancel()
        installTasks[model.id] = nil
        installTokens[model.id] = nil
        if let cancelledInstall {
            // A cancelled download can still finish moving files into place
            // after this delete; remove them again once it has stopped, unless
            // the user has started a new install meanwhile.
            let directory = model.engine == .kokoro ? Self.kokoroCacheDirectory : Self.phononDirectory
            Task { [weak self] in
                await cancelledInstall.value
                guard let self, self.installTasks[model.id] == nil,
                      self.states[model.id] == .notInstalled else { return }
                try? FileManager.default.removeItem(at: directory)
                await self.refreshStorage()
            }
        }
        switch model.engine {
        case .kokoro:
            kokoro = nil
            try? FileManager.default.removeItem(at: Self.kokoroCacheDirectory)
        case .phonon:
            phonon = nil
            try? FileManager.default.removeItem(at: Self.phononDirectory)
        }
        states[model.id] = .notInstalled
        validateSelection()
        publishVoices()
        if selectedModelID == Self.systemModelID, let system = voices.bestSystemVoice,
           voices.defaultVoice?.isSystem != true {
            voices.setDefault(system)
        }
        NotificationCenter.default.post(name: .nodusVoiceEngineChanged, object: nil)
        Task { await refreshStorage() }
    }

    private func performInstall(_ model: Model, token: UUID) async {
        guard installTokens[model.id] == token else { return }
        states[model.id] = .downloading(0)
        do {
            switch model.engine {
            case .kokoro:
                let resources = try await KokoroResourceProvider.huggingFace(
                    cacheDirectory: Self.kokoroCacheDirectory
                ) { [weak self] progress in
                    guard progress.phase == .downloading else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.installTokens[model.id] == token else { return }
                        self.states[model.id] = .downloading(progress.fraction)
                    }
                }
                try Task.checkCancellation()
                _ = await Self.installMissingKokoroVoices()
                try Task.checkCancellation()
                Self.excludeFromBackup(Self.kokoroCacheDirectory)
                states[model.id] = .loading
                let loaded = try await KokoroTTS.load(resources: resources)
                try Task.checkCancellation()
                try await loaded.prewarm(text: "Nodus Reader is ready to narrate.", voice: .afHeart)
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                kokoro = loaded
            case .phonon:
                let directory = try await PhononModels.download(
                    from: Self.phononBundleBase,
                    to: Self.phononDirectory
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.installTokens[model.id] == token else { return }
                        self.states[model.id] = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                states[model.id] = .loading
                let loaded = try await Phonon.load(models: directory, language: .english)
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                phonon = loaded
            }
            guard installTokens[model.id] == token else { return }
            states[model.id] = .installed
            installTasks[model.id] = nil
            installTokens[model.id] = nil
            publishVoices()
            await refreshStorage()
        } catch is CancellationError {
            guard installTokens[model.id] == token else { return }
            if states[model.id]?.isBusy == true {
                states[model.id] = .paused(progressValue(for: model))
            }
            installTasks[model.id] = nil
            installTokens[model.id] = nil
        } catch {
            guard installTokens[model.id] == token else { return }
            states[model.id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            installTasks[model.id] = nil
            installTokens[model.id] = nil
            await refreshStorage()
        }
    }

    // MARK: Install from file

    /// Installs a model bundle the user already has on disk (for example one
    /// downloaded on another computer). Only complete bundles for engines this
    /// build can run are accepted; nothing is converted or fetched.
    func installFromFolder(_ folder: URL) async {
        errorMessage = nil
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }

        let engine: Engine? = await Task.detached(priority: .userInitiated) {
            if Self.kokoroBundleIsComplete(at: folder) { return .kokoro }
            if PhononModels.isInstalled(at: folder) { return .phonon }
            return nil
        }.value
        guard let engine else {
            errorMessage = String(localized: "This folder is not a complete Kokoro or Phonon Core ML bundle. Choose the folder that contains the model packages and their manifest.")
            return
        }
        guard let model = models.first(where: { $0.engine == engine }) else { return }
        guard model.isAvailable else {
            errorMessage = "\(model.name) cannot run on this device, so its bundle was not installed."
            return
        }
        guard installTasks[model.id] == nil else { return }

        let destination = engine == .kokoro ? Self.kokoroCacheDirectory : Self.phononDirectory
        engineLoadToken = UUID()
        switch engine {
        case .kokoro: kokoro = nil
        case .phonon: phonon = nil
        }
        states[model.id] = .loading
        do {
            try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.copyItem(at: folder, to: destination)
            }.value
            Self.excludeFromBackup(destination)
            switch engine {
            case .kokoro:
                kokoro = try await KokoroTTS.load(resources: KokoroResourceProvider.directory(destination))
            case .phonon:
                phonon = try await Phonon.load(models: destination, language: .english)
            }
            states[model.id] = .installed
            publishVoices()
            NotificationCenter.default.post(name: .nodusVoiceEngineChanged, object: nil)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[model.id] = .failed(message)
            errorMessage = message
        }
        await refreshStorage()
    }

    private func progressValue(for model: Model) -> Double {
        switch states[model.id] {
        case .downloading(let value), .paused(let value): value
        default: 0
        }
    }

    // MARK: Runtime

    func kokoroEngine() -> KokoroTTS? { kokoro }

    /// One sentence of neural speech (mono Float PCM) from an installed
    /// engine, loading it first if this launch has not used it yet.
    func synthesize(_ text: String, voiceID: String, engine: Engine) async throws -> (samples: [Float], sampleRate: Double) {
        switch engine {
        case .kokoro:
            beginSynthesis()
            defer { endSynthesis() }
            if kokoro == nil { await loadInstalledEnginesIfNeeded() }
            guard let kokoro else { throw NeuralNarrationError.engineNotLoaded("Kokoro") }
            let raw = voiceID.hasPrefix("kokoro:") ? String(voiceID.dropFirst("kokoro:".count)) : voiceID
            let audio = try await kokoro.synthesize(text, voice: KokoroVoiceID(raw))
            return (audio.samples, Double(audio.sampleRate))
        case .phonon:
            beginSynthesis()
            defer { endSynthesis() }
            if phonon == nil { await loadInstalledEnginesIfNeeded() }
            guard let phonon else { throw NeuralNarrationError.engineNotLoaded("Phonon") }
            let name = voiceID.hasPrefix("phonon:") ? String(voiceID.dropFirst("phonon:".count)) : voiceID
            if phonon.voice != name, phonon.voices.contains(name) {
                try await phonon.setVoice(name)
            }
            return (try await phonon.synthesize(text), Phonon.sampleRate)
        }
    }

    func phononEngine() -> Phonon? { phonon }

    // MARK: Memory

    /// The engines whose models are in memory now.
    var loadedEngines: [Engine] {
        [kokoro != nil ? Engine.kokoro : nil, phonon != nil ? Engine.phonon : nil].compactMap { $0 }
    }

    /// Narration (or a voice sample) is playing: keep the engine loaded so
    /// the next sentence does not wait for a reload. When it stops, the
    /// engine is released after `idleUnloadDelay`.
    func setNarrationInUse(_ inUse: Bool) {
        guard narrationInUse != inUse else { return }
        narrationInUse = inUse
        if inUse {
            idleUnloadTask?.cancel()
            idleUnloadTask = nil
        } else {
            scheduleIdleUnload()
        }
    }

    /// Releases the loaded engines unless narration is using them, a sentence
    /// is being generated or an engine is loading. Returns whether it did.
    @discardableResult
    func releaseEnginesIfIdle() -> Bool {
        guard !narrationInUse, synthesesInFlight == 0, engineLoadTask == nil else { return false }
        releaseEngines(keeping: nil)
        return true
    }

    private func beginSynthesis() {
        synthesesInFlight += 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func endSynthesis() {
        synthesesInFlight = max(0, synthesesInFlight - 1)
        if synthesesInFlight == 0, !narrationInUse { scheduleIdleUnload() }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.releaseEnginesIfIdle()
        }
    }

    /// Drops the engines (all, or all but `keeping`) and MLX's buffer cache.
    /// A sentence already being generated keeps its own reference until it
    /// finishes; the next one loads the engine again.
    private func releaseEngines(keeping engine: Engine?) {
        if engine != .phonon { phonon = nil }
        guard engine != .kokoro, kokoro != nil else { return }
        kokoro = nil
        // Only Kokoro's phonemizer uses MLX, so only releasing a loaded Kokoro
        // clears its buffers. The call creates MLX's Metal device if it does
        // not exist, which aborts where MLX cannot run (the Simulator).
        #if !targetEnvironment(simulator)
        MLX.Memory.clearCache()
        #endif
    }

    private func observeMemoryPressure() {
        #if os(iOS)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Under pressure keep only what playing narration needs.
                if !self.releaseEnginesIfIdle() {
                    self.releaseEngines(keeping: self.selectedModel?.engine)
                }
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Background narration keeps its engine; otherwise free it
                // now rather than in three minutes.
                _ = self?.releaseEnginesIfIdle()
            }
        })
        #endif
    }

    /// Lazily loads an installed engine when the app starts after a previous
    /// install, so playback can use it without visiting the Models screen.
    func loadInstalledEnginesIfNeeded() async {
        if let existing = engineLoadTask {
            await existing.value
            return
        }
        let token = UUID()
        engineLoadToken = token
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadSelectedEngineIfNeeded(token: token)
        }
        engineLoadTask = task
        await task.value
        if engineLoadToken == token { engineLoadTask = nil }
    }

    private func loadSelectedEngineIfNeeded(token: UUID) async {
        guard let model = selectedModel, isInstalled(model) else {
            validateSelection()
            publishVoices()
            return
        }
        switch model.engine {
        case .kokoro:
            #if !targetEnvironment(simulator)
            guard kokoro == nil else { return }
            // Bundles installed before the full voice catalogue: add the
            // missing voices once (offline, this just finds nothing to add).
            if Self.installedKokoroVoiceIDs().count < Self.kokoroVoiceCatalog.count {
                _ = await Self.installMissingKokoroVoices()
            }
            do {
                // Load the already-verified local bundle. The hosted provider
                // would fetch HostedManifest.json on every launch, breaking
                // offline narration and adding a network request per start.
                let resources = KokoroResourceProvider.directory(Self.kokoroCacheDirectory)
                let loaded = try await KokoroTTS.load(resources: resources)
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                kokoro = loaded
                states[model.id] = .installed
            } catch {
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                states[model.id] = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            #endif
        case .phonon:
            guard phonon == nil else { return }
            do {
                let loaded = try await Phonon.load(models: Self.phononDirectory, language: .english)
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                phonon = loaded
                states[model.id] = .installed
            } catch {
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                states[model.id] = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
        validateSelection()
        publishVoices()
        await refreshStorage()
    }

    func voices(for model: Model) -> [Voice] {
        guard isInstalled(model) else { return [] }
        return model.voices
    }

    private func publishVoices() {
        guard !isSystemSelected,
              let model = selectedModel,
              model.isAvailable,
              isInstalled(model) else {
            voices.setNeuralVoices([])
            return
        }
        let installedKokoro = model.engine == .kokoro ? Self.installedKokoroVoiceIDs() : []
        let available = model.engine == .kokoro
            ? model.voices.filter { installedKokoro.contains(String($0.id.dropFirst("kokoro:".count))) }
            : model.voices
        let neural = available.map { voice in
            VoiceCatalog.Voice(
                id: voice.id,
                name: voice.name,
                language: voice.language,
                languageName: VoiceCatalog.variantName(for: voice.language),
                quality: 3,
                gender: nil,
                engineRaw: voice.engine.rawValue
            )
        }
        voices.setNeuralVoices(neural)
    }

    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Kokoro voices

    /// Every English voice embedding in the pinned Kokoro repository, with the
    /// SHA-256 Hugging Face publishes for it (its LFS object id). The hosted
    /// starter bundle installs only `af_heart`; the others are fetched from the
    /// same pinned revision, verified and added to the local runtime manifest.
    /// `a`/`b` = American/British, `f`/`m` = female/male voice.
    nonisolated static let kokoroVoiceCatalog: [(id: String, sha256: String)] = [
        ("af_alloy", "c4a6b876047fd7fb472edf4ebd63cfac7c3b958a7cae7c106e8f038ca6308c45"),
        ("af_aoede", "4a004c33430762e2461eedb2013fad808ef4ab3121f5300f554476caf58d8361"),
        ("af_bella", "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b"),
        ("af_heart", "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"),
        ("af_jessica", "a240a5e3c15b43563d6e923bdca8ef5613a23471d9b77653694012435df23bd8"),
        ("af_kore", "9be5221b6a941c04b561959b8ff0b06e809444dcc4ab7e75a7b23606f691819e"),
        ("af_nicole", "cd2191ab31b914ed7b318416b0e4440fdf392ddad9106a060819aa600a64f59a"),
        ("af_nova", "18778272caa0d0eebaea251c35fd635f038434f9eee5e691d02a174bd328414f"),
        ("af_river", "00a2bcf82b1d86e8f19902ede58c65ccf6c0e43b44b7d74fad54e5d8933c9c30"),
        ("af_sarah", "4409fbc125afabacc615d94db5398d847006a737b0247d6892b7a9a0007a2f0a"),
        ("af_sky", "4435255c9744f3f31659e0d714ab7689bf65d9e77ec1cce060f083912614f0b9"),
        ("am_adam", "162b035ed91cfc48b6046982184c645f72edcdd1b82843347f605d7bf7b15716"),
        ("am_echo", "3968b92c3c4cd1c4416dbded36c13eaa388a90d5788d02a13e4d781f5f8cf3c3"),
        ("am_eric", "e8b5be17edd1e3636901ce7598baafe2dc8dd8ff707a0c23bf9e461add7e2832"),
        ("am_fenrir", "c27989f741f7ee34d273a39d8a595cc0837d35f5ced9a29b7cc162614616df43"),
        ("am_liam", "52403be32fd047c6a44517cb0bcd6b134f2a18baa73e70ef41651e0eab921ade"),
        ("am_michael", "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"),
        ("am_onyx", "da5d135b424164916d75a68ffb4c2abce3d7d5ccc82dd1ee6cf447ce286145e6"),
        ("am_puck", "fcf73c989033e9233e0b98713eca600c8c74dcc1614b37009d5450ff4a2274a0"),
        ("am_santa", "61150cf726ab6c5ed7a99f90a304f91f5a72c00c592e89ec94e5df11c319227a"),
        ("bf_alice", "08afa6ba24da61ea5e8efa139e5aadc938d83f0a6da5a900adaf763ac1da5573"),
        ("bf_emma", "669fe0647f9dd04fcab92f1439a40eeb4c8b4ab1f82e4996fe3d918ce4a63b73"),
        ("bf_isabella", "3754352c4aaa46d17f27654ab7518d65b62ad6163a0f55a5f4330c2da2c4e94f"),
        ("bf_lily", "5e0ee32ebe64a467124976b14e69590746f1c4ce41a12b587a50c862edfea335"),
        ("bm_daniel", "6b3194bbceffb746733cbc22c8f593dd44e401a71d53895a2dca891bc595a1e8"),
        ("bm_fable", "f889083196807b4adb15e9204252165f503b8d33d3982e681c52443c49d798f1"),
        ("bm_george", "c4b235a4c1f2cd3b939fed08b899ce9385638b763f7b73a59616c4fc9bd6c9bc"),
        ("bm_lewis", "b8f671cef828c30e66fdf0b0756a76bba58f6bb3398cbbf27058642acbcedb97"),

    ]

    nonisolated static let kokoroVoiceBase = URL(string:
        "https://huggingface.co/mattmireles/kokoro-coreml/resolve/034f7741bf938fd6b4b9c75c22bc72cd795f908a/voices/"
    )!

    private static let kokoroVoices: [Voice] = kokoroVoiceCatalog.map { entry in
        let name = entry.id.split(separator: "_").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? entry.id
        return Voice(id: "kokoro:\(entry.id)", name: name,
                     language: entry.id.hasPrefix("b") ? "en-GB" : "en-US", engine: .kokoro)
    }

    /// Voice files listed in the installed Kokoro runtime manifest.
    nonisolated private static func installedKokoroVoiceIDs() -> Set<String> {
        let manifestURL = kokoroCacheDirectory.appendingPathComponent("KokoroRuntimeManifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = object["voices"] as? [[String: Any]] else { return [] }
        return Set(voices.compactMap { entry in
            (entry["path"] as? String).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        }.filter { id in
            FileManager.default.fileExists(atPath: kokoroCacheDirectory
                .appendingPathComponent("voices/\(id).bin").path)
        })
    }

    /// Downloads the catalogue voices the installed bundle lacks, checks each
    /// file's SHA-256 against the pinned value and lists it in the runtime
    /// manifest so the SDK accepts it. Returns true when voices were added (the
    /// engine must then be reloaded). A voice that fails to download or verify
    /// is skipped; the rest still install.
    nonisolated static func installMissingKokoroVoices() async -> Bool {
        let manifestURL = kokoroCacheDirectory.appendingPathComponent("KokoroRuntimeManifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var entries = manifest["voices"] as? [[String: Any]] ?? []
        let listed = Set(entries.compactMap { $0["path"] as? String })
        let voicesDirectory = kokoroCacheDirectory.appendingPathComponent("voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)

        var added = false
        for voice in kokoroVoiceCatalog where !listed.contains("voices/\(voice.id).bin") {
            if Task.isCancelled { break }
            let destination = voicesDirectory.appendingPathComponent("\(voice.id).bin")
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard let (temporary, response) = try? await URLSession.shared.download(
                        from: kokoroVoiceBase.appendingPathComponent("\(voice.id).bin")),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                guard (try? ContentHash.sha256(of: temporary)) == voice.sha256 else {
                    try? FileManager.default.removeItem(at: temporary)
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                guard (try? FileManager.default.moveItem(at: temporary, to: destination)) != nil else { continue }
            } else if (try? ContentHash.sha256(of: destination)) != voice.sha256 {
                try? FileManager.default.removeItem(at: destination)
                continue
            }
            entries.append([
                "path": "voices/\(voice.id).bin",
                "bytes": Int(FileStore.fileSize(at: destination)),
                "sha256": voice.sha256
            ])
            added = true
        }
        guard added else { return false }
        manifest["voices"] = entries
        guard let updated = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
              (try? updated.write(to: manifestURL, options: .atomic)) != nil else { return false }
        return true
    }

    private static let phononVoices: [Voice] = [
        Voice(id: "phonon:default", name: "Default", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Harper", name: "Harper", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Hadley", name: "Hadley", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Miles", name: "Miles", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Preston", name: "Preston", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Maeve", name: "Maeve", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Bryony", name: "Bryony", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Edwin", name: "Edwin", language: "en-US", engine: .phonon),
        Voice(id: "phonon:Hugh", name: "Hugh", language: "en-US", engine: .phonon)
    ]
}

// MARK: - Hugging Face token

/// Optional personal access token, stored only in the device Keychain. It is
/// never written to the library folder, CloudKit, iCloud Drive or logs.
enum HuggingFaceTokenStore {
    private static let service = "ai.nodus.reader.huggingface"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        delete()
        guard !trimmed.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8)
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HuggingFaceTokenError.keychain(status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Checks the token against Hugging Face and returns the account name.
    static func verify(_ token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HuggingFaceTokenError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw HuggingFaceTokenError.rejected(http.statusCode)
        }
        struct WhoAmI: Decodable { let name: String }
        guard let who = try? JSONDecoder().decode(WhoAmI.self, from: data) else {
            throw HuggingFaceTokenError.invalidResponse
        }
        return who.name
    }
}

enum HuggingFaceTokenError: LocalizedError {
    case keychain(OSStatus)
    case rejected(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            String(localized: "The token could not be saved in the Keychain (status \(status)).")
        case .rejected(let code):
            code == 401
                ? String(localized: "Hugging Face rejected this token.")
                : "Hugging Face returned HTTP \(code)."
        case .invalidResponse:
            String(localized: "Hugging Face returned an unexpected response.")
        }
    }
}
