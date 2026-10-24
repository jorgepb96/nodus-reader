// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

@main
struct NodusReaderApp: App {
    private let container: ModelContainer
    @State private var theme: ThemeManager
    @State private var preferences: ReaderPreferences
    @State private var navigation: NavigationModel
    @State private var voices: VoiceCatalog
    @State private var library: LibraryService
    @State private var imports: ImportCoordinator
    @State private var playback: PlaybackController

    init() {
        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
        } catch {
            fatalError("Nodus Reader could not open its local library: \(error)")
        }
        self.container = container

        let library = LibraryService(context: container.mainContext)
        let voices = VoiceCatalog()
        _library = State(initialValue: library)
        _voices = State(initialValue: voices)
        _imports = State(initialValue: ImportCoordinator(library: library))
        _playback = State(initialValue: PlaybackController(library: library, voices: voices))
        _theme = State(initialValue: ThemeManager())
        _preferences = State(initialValue: ReaderPreferences())
        _navigation = State(initialValue: NavigationModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .environment(preferences)
                .environment(navigation)
                .environment(voices)
                .environment(library)
                .environment(imports)
                .environment(playback)
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
            .environment(theme)
            .environment(preferences)
            .environment(navigation)
            .environment(voices)
            .environment(library)
            .environment(imports)
            .environment(playback)
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

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .importExport) {
            Button("Import…") {
                imports.beginImport()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Library") {
            Button("Home") { navigation.sidebarSelection = .home }
                .keyboardShortcut("1", modifiers: .command)
            Button("All Books") { navigation.sidebarSelection = .allBooks }
                .keyboardShortcut("2", modifiers: .command)
            Button("Favorites") { navigation.sidebarSelection = .favorites }
                .keyboardShortcut("3", modifiers: .command)
            Button("To Read") { navigation.sidebarSelection = .toRead }
                .keyboardShortcut("4", modifiers: .command)
            Button("Finished") { navigation.sidebarSelection = .finished }
                .keyboardShortcut("5", modifiers: .command)
            Button("Inbox") { navigation.sidebarSelection = .inbox }
                .keyboardShortcut("6", modifiers: .command)
        }
        CommandMenu("Player") {
            Button(playback.isPlaying ? "Pause" : "Play") { playback.toggle() }
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
