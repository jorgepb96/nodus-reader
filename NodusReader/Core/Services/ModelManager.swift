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
/// from backup and iCloud sync, and can be deleted at any time.
/// Model weights and generated audio stay on this device.
@MainActor
@Observable
final class ModelManager {
    enum Engine: String, Sendable {
        case kokoro
        case phonon
        /// Ming 3.0 0.5B on MLX; offered only on the Mac.
        case ming

        var label: String {
            switch self {
            case .kokoro: String(localized: "Kokoro")
            case .phonon: String(localized: "Phonon")
            case .ming: String(localized: "Ming")
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
        var gender: VoiceGender? = nil
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
        /// Offered as a download inside the app. A model that is not (its
        /// publisher has no Core ML build) is installed from a converted
        /// folder with Install from file.
        var downloadable = true
        /// The language Phonon normalizes text as for this checkpoint.
        var phononLanguage: PhononTTS.Language = .english
        /// How to get the model when it cannot be downloaded in the app.
        var installNote: String?

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
        /// Building the Core ML bundle on this device (Phonon 40M Spanish).
        case converting
        case installed
        case failed(String)

        var isInstalled: Bool { self == .installed }
        var isBusy: Bool {
            switch self {
            case .downloading, .loading, .converting: true
            default: false
            }
        }
    }

    struct StorageSummary: Equatable {
        var kokoroBytes: Int64 = 0
        var phononBytes: Int64 = 0
        var mingBytes: Int64 = 0
        var narrationCacheBytes: Int64 = 0
        var totalBytes: Int64 { kokoroBytes + phononBytes + mingBytes + narrationCacheBytes }
    }

    private(set) var states: [String: State] = [:]
    private(set) var storage = StorageSummary()
    private(set) var selectedModelID: String
    private(set) var errorMessage: String?
    /// The engine being loaded into memory for narration, shown on the play
    /// buttons (the first load of a model can take several seconds).
    private(set) var loadingEngine: Engine?

    private let voices: VoiceCatalog
    private let audioCache: NarrationAudioCache
    private let defaults: UserDefaults
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var installTokens: [String: UUID] = [:]
    @ObservationIgnored private var engineLoadTask: Task<Void, Never>?
    @ObservationIgnored private var engineLoadToken = UUID()

    @ObservationIgnored private var kokoro: KokoroTTS?
    /// The loaded Kokoro runs on the CPU only (see `kokoroComputePolicy`).
    @ObservationIgnored private var kokoroIsCPUOnly = false
    @ObservationIgnored private var phonon: Phonon? {
        didSet { if phonon == nil { phononModelID = nil } }
    }
    /// Which Phonon checkpoint `phonon` holds (English 31M or Spanish 40M).
    @ObservationIgnored private var phononModelID: String?
    #if os(macOS)
    @ObservationIgnored private var ming: MingSpeech?
    #endif
    /// Voices cloned for Ming on this Mac, and the bundled one.
    private(set) var mingClones: [MingVoiceStore.ClonedVoice] = []

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

    nonisolated private static let phonon40SpanishDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Phonon-40m-es", isDirectory: true)

    nonisolated private static let phonon40MultilingualDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Phonon-40m-multilingual", isDirectory: true)

    nonisolated private static let mingDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Ming-3.0-0.5B-8bit", isDirectory: true)

    nonisolated private static let modelsDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models", isDirectory: true)

    /// Removes the work folders (`.<model>-conversion`) of on-device conversions
    /// that did not finish, such as when the app was closed mid-conversion. Only
    /// called when no install is running.
    @discardableResult
    nonisolated static func removeInterruptedConversions(in root: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(".") && name.hasSuffix("-conversion") {
            if (try? FileManager.default.removeItem(at: root.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    static let phonon40SpanishID = "phonon-40m-es"
    static let phonon40MultilingualID = "phonon-40m-multilingual"

    /// Each model keeps its own folder, so the English and Spanish Phonon
    /// checkpoints can both be installed.
    nonisolated static func directory(forModelID id: String, engine: Engine) -> URL {
        switch engine {
        case .kokoro: kokoroCacheDirectory
        case .phonon:
            switch id {
            case phonon40SpanishID: phonon40SpanishDirectory
            case phonon40MultilingualID: phonon40MultilingualDirectory
            default: phononDirectory
            }
        case .ming: mingDirectory
        }
    }

    private func directory(for model: Model) -> URL {
        Self.directory(forModelID: model.id, engine: model.engine)
    }

    /// Pinned Hugging Face revision used for the public Phonon 31M Core ML bundle.
    /// The bundle's own `bundle.json` verifies the size and SHA-256 of every file.
    static let phononBundleBase = URL(string:
        "https://huggingface.co/mosiah/phonon-31m-en-coreml/resolve/0a2596e9154f0340005b6445514fdd57f7bc9ddb"
    )!

    let models: [Model] = [
        Model(
            id: "kokoro-82m",
            engine: .kokoro,
            name: "Kokoro 82M",
            detail: String(localized: "Expressive narration in American and British English (28 voices) and Spanish (3 voices)."),
            language: String(localized: "English, Spanish"),
            sizeText: String(localized: "About 210 MB download"),
            license: "Apache-2.0",
            source: URL(string: "https://huggingface.co/mattmireles/kokoro-coreml")!,
            voices: ModelManager.kokoroVoices,
            availability: {
                #if targetEnvironment(simulator)
                .unavailable(String(localized: "Kokoro's English phonemizer uses MLX, which needs a Metal GPU. The Simulator does not provide one. Install Kokoro on an iPhone, iPad or Mac; Phonon works in the Simulator."))
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
            id: ModelManager.phonon40MultilingualID,
            engine: .phonon,
            name: String(localized: "Phonon 40M Multilingual"),
            detail: String(localized: "English, Spanish, French, German and Portuguese with 102 voices."),
            language: String(localized: "Multilingual"),
            sizeText: String(localized: "About 150 MB download"),
            license: "CC BY-NC 4.0",
            source: PhononOnDeviceConversion.multilingual.page,
            voices: PhononOnDeviceConversion.multilingual.voices
                .map { ModelManager.voice(from: $0, modelID: ModelManager.phonon40MultilingualID) },
            availability: .available,
            requiresAcceptedLicense: true,
            phononLanguage: .english,
            installNote: String(localized: "Needs a Hugging Face account that has accepted Gradium's conditions for this model (sign in below). Nodus Reader downloads it with your sign-in and converts it to Core ML on this device: about 150 MB to download, 230 MB installed. Each voice reads its own language. Gradium licenses this model under CC BY-NC 4.0, non-commercial use only; that licence applies on its own, separate from Nodus Reader's AGPL-3.0.")
        ),
        Model(
            id: ModelManager.phonon40SpanishID,
            engine: .phonon,
            name: String(localized: "Phonon 40M Spanish"),
            detail: String(localized: "Spanish narration with 25 voices from Spain and Mexico."),
            language: String(localized: "Spanish"),
            sizeText: String(localized: "About 130 MB download"),
            license: "CC BY-NC 4.0",
            source: URL(string: "https://huggingface.co/gradium/phonon-40m-es")!,
            voices: ModelManager.phonon40SpanishVoices,
            availability: .available,
            requiresAcceptedLicense: true,
            phononLanguage: .spanish,
            installNote: String(localized: "Needs a Hugging Face account that has accepted Gradium's conditions for this model (sign in below). Nodus Reader downloads it with your sign-in and converts it to Core ML on this device: about 130 MB to download, 200 MB installed. Gradium licenses this model under CC BY-NC 4.0, non-commercial use only; that licence applies on its own, separate from Nodus Reader's AGPL-3.0.")
        )
    ] + ModelManager.macOnlyModels

    init(voices: VoiceCatalog,
         audioCache: NarrationAudioCache = NarrationAudioCache(),
         defaults: UserDefaults = .standard) {
        self.voices = voices
        self.audioCache = audioCache
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: "nodus.models.selected") ?? ""
        #if os(iOS) && !targetEnvironment(simulator)
        // MLX runs only Kokoro's English fallback phonemizer (a small model for
        // words missing from its dictionary). On the GPU it is refused while
        // the app narrates in the background with the phone locked, and MLX
        // stops the app when a Metal command buffer fails. The CPU is enough.
        // Not on the Mac: there MLX's CPU backend compiles fused kernels with
        // the system compiler, which the App Sandbox refuses (a fatal error),
        // and the Mac's GPU is available in the background.
        Device.setDefault(device: .cpu)
        #endif
        Self.excludeFromBackup(Self.kokoroCacheDirectory)
        Self.excludeFromBackup(Self.phononDirectory)
        Self.excludeFromBackup(Self.phonon40SpanishDirectory)
        Self.excludeFromBackup(Self.phonon40MultilingualDirectory)
        Self.excludeFromBackup(Self.mingDirectory)
        mingClones = MingVoiceStore.voices()
        // Nothing is installing yet: any conversion folder was left by an
        // interrupted one.
        Self.removeInterruptedConversions(in: Self.modelsDirectory)
        refreshStates()
        validateSelection()
        publishVoices()
        observeMemoryPressure()
    }

    var selectedModel: Model? {
        models.first { $0.id == selectedModelID }
    }

    var hasInstalledModel: Bool {
        models.contains { state(for: $0).isInstalled || isInstalled($0) }
    }

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
        guard let model = models.first(where: { $0.id == id }),
              model.isAvailable,
              isInstalled(model) else { return }
        selectedModelID = id
        defaults.set(id, forKey: "nodus.models.selected")
        // Only one neural engine stays in memory: the one just selected (and
        // for Phonon, only the selected checkpoint).
        releaseEngines(keeping: model.engine)
        if model.engine == .phonon, phononModelID != model.id { phonon = nil }
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
        guard !(selectedModel.map { $0.isAvailable && isInstalled($0) } ?? false) else { return }
        selectedModelID = models.first { $0.isAvailable && isInstalled($0) }?.id ?? ""
        defaults.set(selectedModelID, forKey: "nodus.models.selected")
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
            return PhononModels.isInstalled(at: directory(for: model))
        case .ming:
            return Self.mingCheckpointIsComplete(at: Self.mingDirectory)
        }
    }

    /// Every pinned file is present at its size (each was hash-checked when
    /// it was downloaded).
    nonisolated private static func mingCheckpointIsComplete(at directory: URL) -> Bool {
        mingFiles.allSatisfy { file in
            FileStore.fileSize(at: directory.appendingPathComponent(file.path)) == file.bytes
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
            (Self.directorySize(Self.kokoroCacheDirectory),
             Self.directorySize(Self.phononDirectory) + Self.directorySize(Self.phonon40SpanishDirectory)
                + Self.directorySize(Self.phonon40MultilingualDirectory),
             Self.directorySize(Self.mingDirectory) + Self.directorySize(MingVoiceStore.directory))
        }.value
        summary.kokoroBytes = sizes.0
        summary.phononBytes = sizes.1
        summary.mingBytes = sizes.2
        summary.narrationCacheBytes = await audioCache.totalBytes()
        storage = summary
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: Install

    func install(_ model: Model) {
        guard model.isAvailable, model.downloadable else { return }
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
            let directory = directory(for: model)
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
            if phononModelID == model.id { phonon = nil }
            try? FileManager.default.removeItem(at: directory(for: model))
        case .ming:
            #if os(macOS)
            ming = nil
            #endif
            // Cloned voices are the user's recordings: they stay for a
            // reinstall, and are deleted one by one.
            try? FileManager.default.removeItem(at: directory(for: model))
        }
        states[model.id] = .notInstalled
        validateSelection()
        publishVoices()
        if let first = voices.neuralVoices.first { voices.setDefault(first) }
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
                let loaded = try await KokoroTTS.load(resources: resources, computePolicy: kokoroComputePolicy)
                kokoroIsCPUOnly = isInBackground
                try Task.checkCancellation()
                try await loaded.prewarm(text: "Nodus Reader is ready to narrate.", voice: .afHeart)
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                kokoro = loaded
            case .phonon where PhononOnDeviceConversion.spec(forModelID: model.id) != nil:
                // Gated checkpoint: the user's own access, converted here.
                let accessToken: String
                if let pasted = HuggingFaceTokenStore.load(), !pasted.isEmpty {
                    accessToken = pasted
                } else if let signedIn = try await HuggingFaceSessionStore.validAccessToken() {
                    accessToken = signedIn
                } else {
                    throw PhononConversionError.notSignedIn
                }
                let destination = directory(for: model)
                let spec = PhononOnDeviceConversion.spec(forModelID: model.id)!
                let work = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(model.id)-conversion", isDirectory: true)
                try await PhononOnDeviceConversion.run(spec, token: accessToken, workDirectory: work,
                                                       destination: destination) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.installTokens[model.id] == token else { return }
                        switch phase {
                        case .downloading(let fraction): self.states[model.id] = .downloading(fraction)
                        case .converting: self.states[model.id] = .converting
                        }
                    }
                }
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                Self.excludeFromBackup(destination)
                states[model.id] = .loading
                let loaded = try await Phonon.load(models: destination, language: model.phononLanguage)
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                phonon = loaded
                phononModelID = model.id
            case .ming:
                #if os(macOS)
                let destination = directory(for: model)
                try await Self.downloadMing(to: destination) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.installTokens[model.id] == token else { return }
                        self.states[model.id] = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                Self.excludeFromBackup(destination)
                states[model.id] = .loading
                releaseEngines(keeping: .ming)
                let loaded = try await MingSpeech.load(directory: destination)
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                ming = loaded
                #endif
            case .phonon:
                let directory = try await PhononModels.download(
                    from: Self.phononBundleBase,
                    to: directory(for: model)
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.installTokens[model.id] == token else { return }
                        self.states[model.id] = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                states[model.id] = .loading
                let loaded = try await Phonon.load(models: directory, language: model.phononLanguage)
                try Task.checkCancellation()
                guard installTokens[model.id] == token else { return }
                phonon = loaded
                phononModelID = model.id
            }
            guard installTokens[model.id] == token else { return }
            states[model.id] = .installed
            installTasks[model.id] = nil
            installTokens[model.id] = nil
            if selectedModelID.isEmpty {
                selectModel(model.id)
            } else {
                publishVoices()
            }
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

        let detected: (engine: Engine, languages: [String])? = await Task.detached(priority: .userInitiated) {
            if Self.kokoroBundleIsComplete(at: folder) { return (Engine.kokoro, []) }
            if PhononModels.isInstalled(at: folder) { return (Engine.phonon, Self.phononBundleLanguages(at: folder)) }
            return nil
        }.value
        guard let detected else {
            errorMessage = String(localized: "This folder is not a complete Kokoro or Phonon Core ML bundle. Choose the folder that contains the model packages and their manifest.")
            return
        }
        let engine = detected.engine
        // A Phonon bundle says which languages its checkpoint speaks: Spanish
        // goes to Phonon 40M Spanish, anything else to Phonon 31M English.
        let modelID: String
        switch engine {
        case .kokoro: modelID = "kokoro-82m"
        case .phonon:
            modelID = detected.languages == ["es"] ? Self.phonon40SpanishID
                : detected.languages.count > 1 ? Self.phonon40MultilingualID : "phonon-31m-en"
        case .ming: return
        }
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        guard model.isAvailable else {
            errorMessage = String(localized: "\(model.name) cannot run on this device, so its bundle was not installed.")
            return
        }
        guard installTasks[model.id] == nil else { return }

        let destination = directory(for: model)
        engineLoadToken = UUID()
        switch engine {
        case .kokoro: kokoro = nil
        case .phonon: phonon = nil
        case .ming: return
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
                kokoro = try await KokoroTTS.load(resources: KokoroResourceProvider.directory(destination),
                                                  computePolicy: kokoroComputePolicy)
                kokoroIsCPUOnly = isInBackground
            case .phonon:
                phonon = try await Phonon.load(models: destination, language: model.phononLanguage)
                phononModelID = model.id
            case .ming:
                break
            }
            states[model.id] = .installed
            if selectedModelID.isEmpty {
                selectModel(model.id)
            } else {
                publishVoices()
            }
            NotificationCenter.default.post(name: .nodusVoiceEngineChanged, object: nil)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[model.id] = .failed(message)
            errorMessage = message
        }
        await refreshStorage()
    }

    /// The languages a Phonon bundle's checkpoint was trained for, from the
    /// `config.json` the exporter copies next to the models (empty if absent).
    nonisolated static func phononBundleLanguages(at folder: URL) -> [String] {
        for name in ["config.json", "bundle.json"] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let languages = object["languages"] as? [String] { return languages }
            if let config = object["config"] as? [String: Any], let languages = config["languages"] as? [String] {
                return languages
            }
        }
        return []
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
    /// engine. The voice decides the model, selected or not (the Voices screen
    /// previews any installed model); its engine is loaded if needed.
    func synthesize(_ text: String, voiceID: String, engine: Engine) async throws -> (samples: [Float], sampleRate: Double) {
        beginSynthesis()
        defer { endSynthesis() }
        let target = model(forVoiceID: voiceID)
            ?? selectedModel.flatMap { model in
                // An ID this build does not know: try the selected model with
                // the name after the prefix.
                let name = voiceID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? voiceID
                return model.engine == engine ? (model, name) : nil
            }
        guard let (model, name) = target, model.engine == engine, isInstalled(model) else {
            throw NeuralNarrationError.engineNotLoaded(engine.label)
        }
        try await ensureLoaded(model)
        switch engine {
        case .kokoro:
            guard let kokoro else { throw NeuralNarrationError.engineNotLoaded("Kokoro") }
            if KokoroSpanish.isSpanishVoice(name) {
                let samples = try await KokoroSpanish.synthesize(text, voice: name, engine: kokoro,
                                                                 bundle: Self.kokoroCacheDirectory)
                return (samples, 24_000)
            }
            let inputs = try await kokoro.prepare(text, voice: KokoroVoiceID(name))
            var samples: [Float] = []
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let audio = try await kokoro.synthesizePrepared([input])
                let chunk = NarrationPCM.kokoroChunk(audio.samples, sampleRate: Double(audio.sampleRate),
                    continuesPrevious: index > 0 && !NarrationPCM.endsClause(inputs[index - 1].text ?? ""),
                    continuesNext: index + 1 < inputs.count && !NarrationPCM.endsClause(input.text ?? ""))
                NarrationPCM.append(chunk, to: &samples, sampleRate: Double(audio.sampleRate))
            }
            return (samples, 24_000)
        case .ming:
            #if os(macOS)
            guard let ming else { throw NeuralNarrationError.engineNotLoaded("Ming") }
            let reference: MingReference?
            let language: String
            if name.hasPrefix(Self.mingClonePrefix) {
                let id = String(name.dropFirst(Self.mingClonePrefix.count))
                reference = try await Task.detached(priority: .userInitiated) {
                    try MingVoiceStore.reference(id: id)
                }.value
                language = mingClones.first { $0.id == id }?.language ?? "en-US"
            } else {
                reference = nil
                language = model.voices.first { $0.id == "ming:\(name)" }?.language ?? "en-US"
            }
            var samples = try await ming.synthesize(text, voice: reference == nil ? name : nil, reference: reference,
                                                    language: String(language.prefix(2)))
            try Task.checkCancellation()
            NarrationPCM.fadeEdges(&samples, sampleRate: MingSpeech.sampleRate)
            return (samples, MingSpeech.sampleRate)
            #else
            throw NeuralNarrationError.engineNotLoaded("Ming")
            #endif
        case .phonon:
            guard let phonon else { throw NeuralNarrationError.engineNotLoaded("Phonon") }
            // Voice names come from the bundle's file names, which the file system
            // may store decomposed ("e" + accent): match by Unicode equivalence
            // and pass Phonon the exact name it knows.
            if let stored = phonon.voices.first(where: { $0 == name }), phonon.voice != stored {
                try await phonon.setVoice(stored)
            }
            // A multilingual checkpoint normalizes text in the voice's language
            // (numbers, abbreviations): a French voice reads French.
            if model.id == Self.phonon40MultilingualID,
               let voice = model.voices.first(where: { $0.name == name }),
               let language = PhononTTS.Language(rawValue: String(voice.language.prefix(2))),
               phonon.language != language {
                try await phonon.setLanguage(language)
            }
            var samples = try await phonon.synthesize(text)
            try Task.checkCancellation()
            NarrationPCM.fadeEdges(&samples, sampleRate: Phonon.sampleRate)
            return (samples, Phonon.sampleRate)
        }
    }

    /// Loads `model`'s engine if it is not the one in memory. Only one Phonon
    /// checkpoint is kept; trying another engine drops the idle one.
    private func ensureLoaded(_ model: Model) async throws {
        // The selected engine may already be loading since launch: wait for
        // it rather than load a second copy of the same model.
        if let launching = engineLoadTask {
            loadingEngine = model.engine
            await launching.value
        }
        defer { loadingEngine = nil }
        switch model.engine {
        case .kokoro:
            // In the background the Metal placement is refused: reload on the
            // CPU (prefetched sentences cover the reload).
            if kokoro != nil, isInBackground, !kokoroIsCPUOnly { kokoro = nil }
            guard kokoro == nil else { return }
            if !narrationInUse { releaseEngines(keeping: .kokoro) }
            #if targetEnvironment(simulator)
            throw NeuralNarrationError.engineNotLoaded("Kokoro")
            #else
            loadingEngine = .kokoro
            kokoro = try await KokoroTTS.load(resources: KokoroResourceProvider.directory(Self.kokoroCacheDirectory),
                                              computePolicy: kokoroComputePolicy)
            kokoroIsCPUOnly = isInBackground
            #endif
        case .phonon:
            guard phonon == nil || phononModelID != model.id else { return }
            if !narrationInUse { releaseEngines(keeping: .phonon) }
            phonon = nil
            loadingEngine = .phonon
            let loaded = try await Phonon.load(models: directory(for: model), language: model.phononLanguage)
            phonon = loaded
            phononModelID = model.id
        case .ming:
            #if os(macOS)
            guard ming == nil else { return }
            if !narrationInUse { releaseEngines(keeping: .ming) }
            loadingEngine = .ming
            ming = try await MingSpeech.load(directory: directory(for: model))
            #else
            throw NeuralNarrationError.engineNotLoaded("Ming")
            #endif
        }
    }

    func phononEngine() -> Phonon? { phonon }

    /// iOS refuses GPU (Metal) work from an app in the background, which is
    /// where a locked phone narrates. Kokoro's measured placement uses Metal;
    /// on the CPU alone it still runs about four times faster than real time
    /// (M2: 0.24 s per second of speech), so the background uses that.
    private var isInBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    private var kokoroComputePolicy: KokoroComputePolicy {
        isInBackground ? .cpuOnly : .gistDefault
    }

    // MARK: Memory

    /// The engines whose models are in memory now.
    var loadedEngines: [Engine] {
        var engines = [kokoro != nil ? Engine.kokoro : nil, phonon != nil ? Engine.phonon : nil].compactMap { $0 }
        #if os(macOS)
        if ming != nil { engines.append(.ming) }
        #endif
        return engines
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
        #if os(macOS)
        // Ming holds about 1.6 GB of weights on the GPU.
        if engine != .ming, ming != nil {
            ming = nil
            MLX.Memory.clearCache()
        }
        #endif
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
            if Self.installedKokoroVoiceIDs().count < Self.allKokoroVoiceFiles.count {
                _ = await Self.installMissingKokoroVoices()
            }
            do {
                // Load the already-verified local bundle. The hosted provider
                // would fetch HostedManifest.json on every launch, breaking
                // offline narration and adding a network request per start.
                let resources = KokoroResourceProvider.directory(Self.kokoroCacheDirectory)
                let loaded = try await KokoroTTS.load(resources: resources, computePolicy: kokoroComputePolicy)
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                kokoro = loaded
                kokoroIsCPUOnly = isInBackground
                states[model.id] = .installed
            } catch {
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                states[model.id] = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            #endif
        case .phonon:
            guard phonon == nil || phononModelID != model.id else { return }
            do {
                let loaded = try await Phonon.load(models: directory(for: model), language: model.phononLanguage)
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                phonon = loaded
                phononModelID = model.id
                states[model.id] = .installed
            } catch {
                guard token == engineLoadToken, selectedModelID == model.id else { return }
                states[model.id] = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        case .ming:
            // Loaded on the first sentence: 1.6 GB is not worth holding for a
            // library window that may never narrate.
            break
        }
        validateSelection()
        publishVoices()
        await refreshStorage()
    }

    func voices(for model: Model) -> [Voice] {
        guard isInstalled(model) else { return [] }
        return model.engine == .ming ? model.voices + mingClones.map(Self.voice(fromClone:)) : model.voices
    }

    private func publishVoices() {
        let installedKokoro = Self.installedKokoroVoiceIDs()
        func catalogVoices(for model: Model) -> [VoiceCatalog.Voice] {
            let available = switch model.engine {
            case .kokoro: model.voices.filter { installedKokoro.contains(String($0.id.dropFirst("kokoro:".count))) }
            case .phonon: model.voices
            case .ming: model.voices + mingClones.map(Self.voice(fromClone:))
            }
            return available.map { voice in
                VoiceCatalog.Voice(
                    id: voice.id,
                    name: voice.name,
                    language: voice.language,
                    languageName: VoiceCatalog.variantName(for: voice.language),
                    quality: 3,
                    gender: voice.gender,
                    engineRaw: voice.engine.rawValue,
                    modelID: model.id,
                    modelName: model.name
                )
            }
        }
        let installed = models.filter { $0.isAvailable && isInstalled($0) }.flatMap(catalogVoices(for:))
        guard let model = selectedModel, model.isAvailable, isInstalled(model) else {
            voices.setNeuralVoices([], installed: installed)
            return
        }
        voices.setNeuralVoices(catalogVoices(for: model), installed: installed)
    }

    /// The installed model a voice ID belongs to and the voice's name inside
    /// it. "phonon:" is the 31M English checkpoint; books whose voice was
    /// chosen with an earlier build of 40M Spanish ("phonon:Alba") resolve to it.
    func model(forVoiceID voiceID: String) -> (model: Model, name: String)? {
        if voiceID.hasPrefix("kokoro:"), let kokoro = models.first(where: { $0.engine == .kokoro }) {
            return (kokoro, String(voiceID.dropFirst("kokoro:".count)))
        }
        if let ming = models.first(where: { $0.engine == .ming }) {
            // A cloned voice keeps its prefix as its name: synthesis reads its clip.
            if voiceID.hasPrefix(MingVoiceStore.voiceIDPrefix) { return (ming, voiceID) }
            if voiceID.hasPrefix("ming:") { return (ming, String(voiceID.dropFirst("ming:".count))) }
        }
        for model in models where model.engine == .phonon && model.id != "phonon-31m-en" {
            if voiceID.hasPrefix("\(model.id):") { return (model, String(voiceID.dropFirst(model.id.count + 1))) }
        }
        if voiceID.hasPrefix("phonon:") {
            let name = String(voiceID.dropFirst("phonon:".count))
            if let english = models.first(where: { $0.id == "phonon-31m-en" }),
               english.voices.contains(where: { $0.id == voiceID }) {
                return (english, name)
            }
            if let spanish = models.first(where: { $0.id == Self.phonon40SpanishID }),
               spanish.voices.contains(where: { $0.name == name }) {
                return (spanish, name)
            }
        }
        return nil
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

    /// Kokoro's three Spanish voices (`e` = Spanish). The Core ML repository
    /// hosts only English ones; these are the same raw float32 tables published
    /// in onnx-community/Kokoro-82M-v1.0-ONNX (Apache-2.0, `af_heart.bin` there is
    /// byte-identical to the Core ML repository's), pinned and verified.
    nonisolated static let kokoroSpanishVoiceCatalog: [(id: String, sha256: String)] = [
        ("ef_dora", "f66ec66bd295acb18372e37008533a9a3228483ccd294e7538d5d9294ac9a532"),
        ("em_alex", "27809e9eafdcbcfff90a3016c697568676531de2a2c39cee29c96c7bd6b83e95"),
        ("em_santa", "ad43b774e1ca24d05c6161297d8aeb770ac3d29bb95daf516727af5f7d543683")
    ]

    nonisolated static let kokoroSpanishVoiceBase = URL(string:
        "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/1939ad2a8e416c0acfeecc08a694d14ef25f2231/voices/"
    )!

    /// Every Kokoro voice the app installs, with where it comes from.
    nonisolated static var allKokoroVoiceFiles: [(id: String, sha256: String, base: URL)] {
        kokoroVoiceCatalog.map { ($0.id, $0.sha256, kokoroVoiceBase) }
            + kokoroSpanishVoiceCatalog.map { ($0.id, $0.sha256, kokoroSpanishVoiceBase) }
    }

    nonisolated static let kokoroVoiceBase = URL(string:
        "https://huggingface.co/mattmireles/kokoro-coreml/resolve/034f7741bf938fd6b4b9c75c22bc72cd795f908a/voices/"
    )!

    static let kokoroVoices: [Voice] = allKokoroVoiceFiles.map { entry in
        let name = entry.id.split(separator: "_").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? entry.id
        let language = switch entry.id.prefix(1) {
        case "b": "en-GB"
        case "e": "es-ES"
        default: "en-US"
        }
        // The second letter is the voice's gender: `af_heart`, `bm_george`.
        let gender: VoiceGender? = switch entry.id.dropFirst().prefix(1) {
        case "f": .female
        case "m": .male
        default: nil
        }
        return Voice(id: "kokoro:\(entry.id)", name: name, language: language, engine: .kokoro, gender: gender)
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
        for voice in allKokoroVoiceFiles where !listed.contains("voices/\(voice.id).bin") {
            if Task.isCancelled { break }
            let destination = voicesDirectory.appendingPathComponent("\(voice.id).bin")
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard let (temporary, response) = try? await URLSession.shared.download(
                        from: voice.base.appendingPathComponent("\(voice.id).bin")),
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

    /// Gradium's Spanish voices (gradium/phonon-voices, Apache-2.0), as exported into the
    /// converted Phonon 40M Spanish bundle under these names.
    static let phonon40SpanishVoices: [Voice] = PhononOnDeviceConversion.spanish.voices
        .map { voice(from: $0, modelID: phonon40SpanishID) }

    /// 40M voices are prefixed with their model ("phonon-40m-es:Alba"), so the
    /// same voice in the Spanish and Multilingual checkpoints stays distinct.
    nonisolated static func voice(from file: PhononVoiceFile, modelID: String) -> Voice {
        Voice(id: "\(modelID):\(file.name)", name: file.name, language: file.language, engine: .phonon,
              gender: file.gender)
    }

    /// Genders from gradium/phonon-voices, where these voices come from.
    private static let phononVoices: [Voice] = [
        // The checkpoint's unnamed speaker; "Default" read like a setting.
        Voice(id: "phonon:default", name: String(localized: "Base voice"), language: "en-US", engine: .phonon),
        Voice(id: "phonon:Harper", name: "Harper", language: "en-US", engine: .phonon, gender: .female),
        Voice(id: "phonon:Hadley", name: "Hadley", language: "en-US", engine: .phonon, gender: .female),
        Voice(id: "phonon:Miles", name: "Miles", language: "en-US", engine: .phonon, gender: .male),
        Voice(id: "phonon:Preston", name: "Preston", language: "en-US", engine: .phonon, gender: .male),
        Voice(id: "phonon:Maeve", name: "Maeve", language: "en-US", engine: .phonon, gender: .female),
        Voice(id: "phonon:Bryony", name: "Bryony", language: "en-US", engine: .phonon, gender: .female),
        Voice(id: "phonon:Edwin", name: "Edwin", language: "en-US", engine: .phonon, gender: .male),
        Voice(id: "phonon:Hugh", name: "Hugh", language: "en-US", engine: .phonon, gender: .male)
    ]
}

// MARK: - Ming

extension ModelManager {
    static let mingID = "ming-3.0-0.5b-8bit"
    static let mingClonePrefix = MingVoiceStore.voiceIDPrefix

    /// Pinned revision of mlx-community/Ming-3.0-tts-0.5B-8bit, the checkpoint
    /// Nodus uses on the Mac; sizes and SHA-256 come from its model card files.
    static let mingRepository = "mlx-community/Ming-3.0-tts-0.5B-8bit"
    static let mingRevision = "c807b99d2ea77d896fcffc917f0330d36470bb29"
    static let mingFiles: [PhononOnDeviceConversion.RemoteFile] = [
        .init(path: "LICENSE", bytes: 1_067, sha256: "2872f1918dfc04fdeb7f5d66d8d1b773594c9375e7c8f7bda39780bb97ad4fba"),
        .init(path: "campplus.safetensors", bytes: 27_699_096,
              sha256: "a479586bd8f8f96cdb414eaa2fa07c6cd54d6d1636562e2d75a0211cb3b0a6fd"),
        .init(path: "config.json", bytes: 6_087, sha256: "8ea3e685a870fd1a535d3b4a4c975fc20c4fca56e67acdef06fe40004064c73b"),
        .init(path: "model.safetensors", bytes: 1_573_366_591,
              sha256: "e88a4b53cb5b705703e961389f3d7f0e8b72c240b4dad796bf9961cc018971fc"),
        .init(path: "model.safetensors.index.json", bytes: 201_850,
              sha256: "f59991abebed1a4f798a9488568af496d925e6eea507450aa8051a06f475a2ce"),
        .init(path: "added_tokens.json", bytes: 1_785,
              sha256: "34394b1e16d7da2db16618bd43a0f970902ade0075480bcd812fe62d559ec319"),
        .init(path: "configuration.json", bytes: 51,
              sha256: "6720b8448f6ad5b4631689a60857bdeb238053a37f6cc6a5936eb50c2a3b9296"),
        .init(path: "merges.txt", bytes: 1_671_853,
              sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(path: "special_tokens_map.json", bytes: 2_726,
              sha256: "2c2ec51b9da5db654ac20de8310350d0c9c1a65918ae0181b80dacd2919b4fc3"),
        .init(path: "tokenizer.json", bytes: 11_431_389,
              sha256: "87d54ca3b44ea2f822ba39a0a45cb1b61644bd6606d9d3536dea75367bffb06d"),
        .init(path: "tokenizer_config.json", bytes: 16_260,
              sha256: "12d6162c815edef24f8606e65b60d43fe0d92b0a4e150a0db8fa01c523aaf36a"),
        .init(path: "vocab.json", bytes: 2_776_833,
              sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]

    /// Ming's built-in voices, from inclusionAI's catalogue as Nodus lists it
    /// (`shared/mingBuiltinVoices.ts`): five English and 101 Mandarin, without
    /// those that imitate film, series and cartoon characters. The ID carries
    /// the name Ming is invoked with: a voice recorded with several emotions
    /// only answers to one of them, so the neutral one is used.
    static let mingBuiltinVoices: [Voice] = [
        Voice(id: "ming:US_James", name: "US_James", language: "en-US", engine: .ming, gender: .male),
        Voice(id: "ming:US_Stella", name: "US_Stella", language: "en-US", engine: .ming, gender: .female),
        Voice(id: "ming:US_Emma", name: "US_Emma", language: "en-US", engine: .ming, gender: .female),
        Voice(id: "ming:UK_George", name: "UK_George", language: "en-GB", engine: .ming, gender: .male),
        Voice(id: "ming:UK_Charlotte", name: "UK_Charlotte", language: "en-GB", engine: .ming, gender: .female),
        Voice(id: "ming:灵小安", name: "灵小安", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵语汐", name: "灵语汐", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小萌", name: "灵小萌", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小柔", name: "灵小柔", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小雅", name: "灵小雅", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:花小呗", name: "花小呗", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵韵", name: "灵韵", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:妩媚妲己", name: "妩媚妲己", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵婉", name: "灵婉", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小月", name: "灵小月", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵朵儿", name: "灵朵儿", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵岩", name: "灵岩", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵小锋", name: "灵小锋", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵小川", name: "灵小川", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵小甄", name: "灵小甄", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小知", name: "灵小知", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小惠", name: "灵小惠", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小晴", name: "灵小晴", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小琪", name: "灵小琪", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵梦", name: "灵梦", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵恬", name: "灵恬", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小汐", name: "灵小汐", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小棠", name: "灵小棠", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小梨", name: "灵小梨", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵舒", name: "灵舒", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵娇", name: "灵娇", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵小芸", name: "灵小芸", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵锐", name: "灵锐", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵空", name: "灵空", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵宇", name: "灵宇", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵朗", name: "灵朗", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵楷", name: "灵楷", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵旭", name: "灵旭", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵骁", name: "灵骁", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵江", name: "灵江", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:悲伤女声", name: "悲伤女声", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:皮六", name: "皮六", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:说唱小哥", name: "说唱小哥", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:蜡笔小新", name: "蜡笔小新", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:悟空", name: "悟空", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵信远_中性", name: "灵信远", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵思齐_中性", name: "灵思齐", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵叙柔_中性", name: "灵叙柔", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵绮木_中性", name: "灵绮木", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵书悦_中性", name: "灵书悦", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵渊霆_中性", name: "灵渊霆", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵素心_中性", name: "灵素心", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵晓声_中性", name: "灵晓声", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵风信_中性", name: "灵风信", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵采薇_中性", name: "灵采薇", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵卓然_中性", name: "灵卓然", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵惜梦_中性", name: "灵惜梦", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵昭野_中性", name: "灵昭野", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵心澜_中性", name: "灵心澜", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵犀言_中性", name: "灵犀言", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵语冰_中性", name: "灵语冰", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵逸风_中性", name: "灵逸风", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵悦澜_中性", name: "灵悦澜", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵惊鸿_中性", name: "灵惊鸿", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵御心_中性", name: "灵御心", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵语恬_中性", name: "灵语恬", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵心恬_中性", name: "灵心恬", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵惜蕊_中性", name: "灵惜蕊", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵语萱_中性", name: "灵语萱", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵语烟_中性", name: "灵语烟", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵律雅_中性", name: "灵律雅", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵惊涛_中性", name: "灵惊涛", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵寒陌_中性", name: "灵寒陌", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵决冥_中性", name: "灵决冥", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵亦尘_中性", name: "灵亦尘", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵语尘_中性", name: "灵语尘", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵慈萱_中性", name: "灵慈萱", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵妙音_中性", name: "灵妙音", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵断尘_中性", name: "灵断尘", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵悦兮_中性", name: "灵悦兮", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵若虚_中性", name: "灵若虚", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵熙婉_中性", name: "灵熙婉", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵旭扬_中性", name: "灵旭扬", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵阅川_中性", name: "灵阅川", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵未央_中性", name: "灵未央", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵妩月_中性", name: "灵妩月", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵梦瑶_中性", name: "灵梦瑶", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵妙声_中性", name: "灵妙声", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵烈瑶_中性", name: "灵烈瑶", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵幽月_中性", name: "灵幽月", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵悦心_中性", name: "灵悦心", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵汐月_中性", name: "灵汐月", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵书意_中性", name: "灵书意", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵知远_中性", name: "灵知远", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵温言_中性", name: "灵温言", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵傲尘_中性", name: "灵傲尘", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵佑安_中性", name: "灵佑安", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵惜晨_中性", name: "灵惜晨", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵宛溪_中性", name: "灵宛溪", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵言澈_中性", name: "灵言澈", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵溯光_中性", name: "灵溯光", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵惊弦_中性", name: "灵惊弦", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵嘉肴_中性", name: "灵嘉肴", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵黛嗔_中性", name: "灵黛嗔", language: "zh-CN", engine: .ming, gender: .female),
        Voice(id: "ming:灵孤影_中性", name: "灵孤影", language: "zh-CN", engine: .ming, gender: .male),
        Voice(id: "ming:灵雨汐_中性", name: "灵雨汐", language: "zh-CN", engine: .ming, gender: .female),
    ]

    /// Models only the Mac can run: Ming needs MLX on a Mac GPU.
    static var macOnlyModels: [Model] {
        #if os(macOS)
        [Model(
            id: mingID,
            engine: .ming,
            name: "Ming 3.0 0.5B",
            detail: String(localized: "Natural narration in seven languages, with 106 built-in English and Mandarin voices and voices you clone from a short recording."),
            language: String(localized: "Spanish, English, French, German, Chinese, Japanese, Korean"),
            sizeText: String(localized: "About 1.6 GB download"),
            license: "MIT",
            source: URL(string: "https://huggingface.co/\(mingRepository)")!,
            voices: mingBuiltinVoices,
            availability: .available,
            installNote: String(localized: "Mac only. It runs on this Mac's GPU and generates speech at about real time; voices you clone stay on this Mac.")
        )]
        #else
        []
        #endif
    }

    static func voice(fromClone clone: MingVoiceStore.ClonedVoice) -> Voice {
        Voice(id: clone.voiceID, name: clone.name, language: clone.language, engine: .ming)
    }

    /// Downloads every pinned file into a work folder, verifying size and
    /// SHA-256, then moves the folder into place.
    nonisolated static func downloadMing(to destination: URL,
                                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        let work = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-download", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let total = Double(mingFiles.reduce(0) { $0 + $1.bytes })
        var done: Int64 = 0
        for file in mingFiles {
            try Task.checkCancellation()
            let target = work.appendingPathComponent(file.path)
            // Files from an interrupted download that already check out are kept.
            if FileStore.fileSize(at: target) != file.bytes || (try? ContentHash.sha256(of: target)) != file.sha256 {
                let url = URL(string: "https://huggingface.co/\(mingRepository)/resolve/\(mingRevision)/\(file.path)")!
                let base = done
                try await PhononOnDeviceConversion.download(URLRequest(url: url), to: target, expected: file) { fraction in
                    progress((Double(base) + fraction * Double(file.bytes)) / total)
                }
            }
            done += file.bytes
            progress(Double(done) / total)
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: work, to: destination)
    }

    // MARK: Cloned voices

    /// Saves a voice cloned from `clip` and lists it with Ming's voices.
    @discardableResult
    func addMingVoice(_ clip: MingVoiceStore.PreparedClip, name: String, language: String, transcript: String,
                      origin: MingVoiceStore.ClonedVoice.Origin, consent: Bool) throws -> MingVoiceStore.ClonedVoice {
        let voice = try MingVoiceStore.save(clip, name: name, language: language, transcript: transcript,
                                            origin: origin, consent: consent)
        reloadMingVoices()
        return voice
    }

    func deleteMingVoice(_ voice: MingVoiceStore.ClonedVoice) {
        guard !voice.isBundled else { return }
        MingVoiceStore.delete(id: voice.id)
        reloadMingVoices()
        if voices.defaultVoiceID == voice.voiceID, let first = voices.neuralVoices.first {
            voices.setDefault(first)
        }
    }

    func reloadMingVoices() {
        mingClones = MingVoiceStore.voices()
        publishVoices()
        Task { await refreshStorage() }
    }
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
