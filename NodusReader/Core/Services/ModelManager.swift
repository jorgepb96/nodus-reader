// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import KokoroTTS
import Observation
import PhononTTS
import Security

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
            case .kokoro: "Kokoro"
            case .phonon: "Phonon"
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
            detail: "Expressive English narration on the Neural Engine, GPU and CPU.",
            language: "English",
            sizeText: "About 210 MB download",
            license: "Apache-2.0",
            source: URL(string: "https://huggingface.co/mattmireles/kokoro-coreml")!,
            voices: [
                Voice(id: "kokoro:af_heart", name: "Heart", language: "en-US", engine: .kokoro)
            ],
            availability: {
                #if targetEnvironment(simulator)
                .unavailable("Kokoro's English phonemizer uses MLX, which needs a Metal GPU. The Simulator does not provide one. Install Kokoro on an iPhone, iPad or Mac; Phonon and system voices work in the Simulator.")
                #else
                .available
                #endif
            }()
        ),
        Model(
            id: "phonon-31m-en",
            engine: .phonon,
            name: "Phonon 31M",
            detail: "Streaming English speech with nine built-in voices.",
            language: "English",
            sizeText: "About 300 MB download",
            license: "Apache-2.0",
            source: URL(string: "https://huggingface.co/mosiah/phonon-31m-en-coreml")!,
            voices: ModelManager.phononVoices,
            availability: .available
        ),
        Model(
            id: "phonon-40m-es",
            engine: .phonon,
            name: "Phonon 40M Spanish",
            detail: "Spanish Phonon checkpoint.",
            language: "Spanish",
            sizeText: "Not available",
            license: "CC BY-NC 4.0",
            source: URL(string: "https://huggingface.co/gradium/phonon-40m-es")!,
            voices: [],
            availability: .unavailable(
                "Gradium publishes this checkpoint as gated CC BY-NC weights but has not published a Core ML bundle. Nodus Reader will not offer a download it cannot run."
            )
        ),
        Model(
            id: "phonon-40m-multilingual",
            engine: .phonon,
            name: "Phonon 40M Multilingual",
            detail: "Multilingual Phonon checkpoint.",
            language: "Multilingual",
            sizeText: "Not available",
            license: "CC BY-NC 4.0",
            source: URL(string: "https://huggingface.co/gradium/phonon-40m-multilingual")!,
            voices: [],
            availability: .unavailable(
                "This checkpoint is gated and non-commercial, and there is no Core ML bundle for it. It is listed for transparency only."
            )
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
            errorMessage = "This folder is not a complete Kokoro or Phonon Core ML bundle. Choose the folder that contains the model packages and their manifest."
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

    func phononEngine() -> Phonon? { phonon }

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
        let neural = model.voices.map { voice in
            VoiceCatalog.Voice(
                id: voice.id,
                name: voice.name,
                language: voice.language,
                languageName: Locale.current.localizedString(forLanguageCode: voice.language) ?? "English",
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
            "The token could not be saved in the Keychain (status \(status))."
        case .rejected(let code):
            code == 401
                ? "Hugging Face rejected this token."
                : "Hugging Face returned HTTP \(code)."
        case .invalidResponse:
            "Hugging Face returned an unexpected response."
        }
    }
}
