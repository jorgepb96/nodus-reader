// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct RootView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(ImportCoordinator.self) private var imports
    @Environment(VoiceCatalog.self) private var voices
    @Environment(LibraryService.self) private var library
    @Environment(CloudSyncService.self) private var sync
    @Environment(ModelManager.self) private var models
    @Environment(StorageJanitor.self) private var janitor
    @Environment(PlaybackController.self) private var playback
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// Per window (Mac) or scene (iPad multitasking): two library windows no
    /// longer mirror each other's sidebar selection and navigation.
    @State private var navigation = NavigationModel()
    @State private var importedBook: Book?
    @State private var showVoiceSetup = false
    @State private var voiceSetupBypassed = false

    private var palette: NodusPalette {
        theme.palette(colorScheme: colorScheme)
    }

    var body: some View {
        @Bindable var imports = imports

        rootContent
            .environment(navigation)
            .focusedSceneValue(\.nodusNavigation, navigation)
            .nodusPalette(palette)
            .tint(palette.accent)
            .preferredColorScheme(theme.appTheme.preferredColorScheme)
            .background(palette.background)
            .readerCover(item: $importedBook)
            #if os(iOS)
            .fullScreenCover(isPresented: $showVoiceSetup) {
                voiceSetup
            }
            #endif
            .onChange(of: imports.bookToOpen?.id) { _, _ in
                openPendingImportedBook()
            }
            .onOpenURL { url in
                imports.handleOpenURLs([url])
            }
            .dropDestination(for: URL.self) { urls, _ in
                imports.handleOpenURLs(urls)
                return true
            }
            .fileImporter(
                isPresented: $imports.isPickerPresented,
                // Folders are imported recursively by `ImportCoordinator`.
                allowedContentTypes: DocumentTypes.supported + [.folder],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await imports.importFiles(urls) }
                case .failure(let error):
                    imports.alert = LibraryAlert(title: String(localized: "Import failed"), message: error.localizedDescription)
                }
            }
            .alert(item: $imports.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
            .alert("Change not saved", isPresented: Binding(
                get: { library.saveError != nil },
                set: { if !$0 { library.saveError = nil } }
            )) {
                Button("OK", role: .cancel) { library.saveError = nil }
            } message: {
                Text(library.saveError ?? "")
            }
            .overlay(alignment: .top) {
                if let toast = imports.toast {
                    ImportToast(message: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: imports.toast)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-NodusSampleLibrary") {
                    await SampleLibrary.seedIfNeeded(library: library)
                }
                if ProcessInfo.processInfo.arguments.contains("-NodusLongContentsSample") {
                    await SampleLibrary.seedLongContentsIfNeeded(library: library)
                }
                if ProcessInfo.processInfo.arguments.contains("-NodusResetReadingState") {
                    SampleLibrary.resetReadingState(library: library)
                }
                #endif
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-NodusSkipVoiceSetup") {
                    voiceSetupBypassed = true
                }
                if ProcessInfo.processInfo.arguments.contains("-NodusResetVoiceSetup") {
                    voiceSetupBypassed = false
                    showVoiceSetup = true
                }
                #endif
                if !LibraryStorageScope.isIsolated { await imports.consumeSharedInbox() }
                openPendingImportedBook()
                updateVoiceSetup()
                await sync.start()
                await models.loadInstalledEnginesIfNeeded()
                await cleanUpStorage()
            }
            .onChange(of: models.hasInstalledModel) { _, installed in
                showVoiceSetup = !installed && !voiceSetupBypassed
            }
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                // A Mac app keeps running behind other apps, and this window's
                // phase is not the app's: reading in the Reading window with
                // the library minimised or in another Space must keep syncing.
                sync.setSceneActive(phase == .active)
                #endif
                if phase != .active { playback.persistPosition() }
                if phase == .active {
                    Task {
                        if !LibraryStorageScope.isIsolated { await imports.consumeSharedInbox() }
                        await sync.refreshAvailability()
                        await sync.syncNow()
                    }
                } else if phase == .background {
                    Task {
                        await sync.syncBeforeSuspending()
                        await cleanUpStorage()
                    }
                }
            }
    }

    private var voiceSetup: some View {
        VoiceSetupView()
    }

    @ViewBuilder
    private var rootContent: some View {
        #if os(macOS)
        // A modal setup sheet prevents AppKit from terminating normally.
        // Keep setup in the window so Quit and the window controls work.
        if showVoiceSetup {
            voiceSetup.frame(minWidth: 1100, minHeight: 700)
        } else {
            platformRoot
        }
        #else
        platformRoot
        #endif
    }

    private func updateVoiceSetup() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-NodusResetVoiceSetup") {
            showVoiceSetup = true
            return
        }
        #endif
        showVoiceSetup = !models.hasInstalledModel && !voiceSetupBypassed
    }

    private func openPendingImportedBook() {
        guard let book = imports.bookToOpen else { return }
        importedBook = book
        imports.bookToOpen = nil
    }

    /// Frees narration audio and OCR results the storage rules no longer keep.
    private func cleanUpStorage() async {
        await janitor.run(protected: Set([playback.activeBook?.id].compactMap { $0 }))
    }

    @ViewBuilder
    private var platformRoot: some View {
        #if os(macOS)
        MacRootView()
            .frame(minWidth: 1100, minHeight: 700)
        #elseif os(iOS)
        if DeviceInfo.isPad {
            PadRootView()
        } else {
            PhoneRootView()
        }
        #endif
    }
}
