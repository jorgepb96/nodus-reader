// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct NodusReaderApp: App {
    private let container: ModelContainer
    private let appDefaults: UserDefaults
    @State private var theme: ThemeManager
    @State private var preferences: ReaderPreferences
    @State private var navigation: NavigationModel
    @State private var voices: VoiceCatalog
    @State private var library: LibraryService
    @State private var imports: ImportCoordinator
    @State private var playback: PlaybackController
    @State private var sync: CloudSyncService
    @State private var models: ModelManager
    @State private var janitor: StorageJanitor

    init() {
        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
        } catch {
            fatalError("Nodus Reader could not open its local library: \(error)")
        }
        self.container = container
        let defaults = LibraryStorageScope.defaults
        self.appDefaults = defaults

        let library = LibraryService(context: container.mainContext)
        let journal = SyncJournal(context: container.mainContext)
        library.syncJournal = journal
        #if os(macOS)
        if !LibraryStorageScope.isIsolated {
            do { try LegacySampleLibraryCleanup.run(library: library) }
            catch { NSLog("Legacy sample cleanup deferred: %@", error.localizedDescription) }
        }
        #endif
        let voices = VoiceCatalog(defaults: defaults)
        let models = ModelManager(voices: voices, defaults: defaults)
        library.narrationCache = models.narrationCache
        _library = State(initialValue: library)
        _voices = State(initialValue: voices)
        _imports = State(initialValue: ImportCoordinator(library: library))
        _playback = State(initialValue: PlaybackController(library: library, voices: voices,
                                                           models: models, defaults: defaults))
        _models = State(initialValue: models)
        _janitor = State(initialValue: StorageJanitor(library: library, cache: models.narrationCache, defaults: defaults))
        let sync = CloudSyncService(context: container.mainContext, library: library, journal: journal, defaults: defaults)
        let theme = ThemeManager(defaults: defaults)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-NodusResetReadingState") {
            // UI tests share one simulator; start every reader test paged.
            defaults.removeObject(forKey: "nodus.reader.flow")
            defaults.removeObject(forKey: "nodus.reader.pageTurn")
            defaults.removeObject(forKey: "nodus.reader.fontScale")
        }
        #endif
        let preferences = ReaderPreferences(defaults: defaults)
        sync.attachPreferences(theme: theme, reading: preferences)
        _sync = State(initialValue: sync)
        _theme = State(initialValue: theme)
        _preferences = State(initialValue: preferences)
        _navigation = State(initialValue: NavigationModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .defaultAppStorage(appDefaults)
                .environment(theme)
                .environment(preferences)
                .environment(navigation)
                .environment(voices)
                .environment(library)
                .environment(imports)
                .environment(playback)
                .environment(sync)
                .environment(models)
                .environment(janitor)
                .modelContainer(container)
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            NodusCommands(navigation: navigation, imports: imports, playback: playback)
        }
        #endif
        #if os(macOS)
        Settings {
            MacSettingsRoot()
            .defaultAppStorage(appDefaults)
            .environment(theme)
            .environment(preferences)
            .environment(navigation)
            .environment(voices)
            .environment(library)
            .environment(imports)
            .environment(playback)
            .environment(sync)
            .environment(models)
            .environment(janitor)
            .modelContainer(container)
            .frame(minWidth: 560, minHeight: 640)
        }
        #endif
    }
}

#if os(macOS)
private struct MacSettingsRoot: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(colorScheme: colorScheme)
        NavigationStack {
            SettingsView(showsBrand: false)
        }
        .toggleStyle(.switch)
        .nodusPalette(palette)
        .tint(palette.accent)
        .preferredColorScheme(theme.appTheme.preferredColorScheme)
        .background(palette.background)
    }
}

struct NodusCommands: Commands {
    let navigation: NavigationModel
    let imports: ImportCoordinator
    let playback: PlaybackController
    /// The library window in front; each window has its own navigation.
    @FocusedValue(\.nodusNavigation) private var focusedNavigation: NavigationModel?

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .importExport) {
            Button("Import…") {
                imports.beginImport()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Library") {
            Group {
                Button("Home") { focusedNavigation?.sidebarSelection = .home }
                    .keyboardShortcut("1", modifiers: .command)
                Button("All Books") { focusedNavigation?.sidebarSelection = .allBooks }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Favorites") { focusedNavigation?.sidebarSelection = .favorites }
                    .keyboardShortcut("3", modifiers: .command)
                Button("To Read") { focusedNavigation?.sidebarSelection = .toRead }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Finished") { focusedNavigation?.sidebarSelection = .finished }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Inbox") { focusedNavigation?.sidebarSelection = .inbox }
                    .keyboardShortcut("6", modifiers: .command)
            }
            .disabled(focusedNavigation == nil)
        }
        CommandMenu("Player") {
            Button(playback.isPlaying ? "Pause" : "Play") {
                // A bare Space is a menu key equivalent, so it would otherwise
                // steal spaces from search fields and text editors.
                if !Self.insertSpaceIntoFocusedTextEditor() {
                    playback.toggle()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!playback.hasActiveBook)
            Divider()
            Button("Previous Sentence") { playback.previousSentence() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!playback.hasActiveBook)
            Button("Next Sentence") { playback.nextSentence() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!playback.hasActiveBook)
            Button("Previous Chapter") { playback.previousChapter() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(!playback.hasActiveBook)
            Button("Next Chapter") { playback.nextChapter() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!playback.hasActiveBook)
        }
    }

    /// Returns true when the focused responder is an editable text view; the
    /// caller must then leave the space key to normal text input.
    private static func insertSpaceIntoFocusedTextEditor() -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return false }
        textView.insertText(" ", replacementRange: textView.selectedRange())
        return true
    }
}
#else
struct NodusCommands: Commands {
    let navigation: NavigationModel
    let imports: ImportCoordinator
    let playback: PlaybackController

    var body: some Commands {
        EmptyCommands()
    }
}
#endif

extension NodusAppTheme {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .sepia, .highContrast: .light
        case .dark, .oled: .dark
        }
    }
}
