// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct RootView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(ImportCoordinator.self) private var imports
    @Environment(VoiceCatalog.self) private var voices
    @Environment(LibraryService.self) private var library
    @Environment(\.colorScheme) private var colorScheme

    private var palette: NodusPalette {
        theme.palette(colorScheme: colorScheme)
    }

    var body: some View {
        @Bindable var imports = imports

        platformRoot
            .nodusPalette(palette)
            .tint(palette.accent)
            .preferredColorScheme(theme.appTheme.preferredColorScheme)
            .background(palette.background)
            .onOpenURL { url in
                imports.handleOpenURLs([url])
            }
            .dropDestination(for: URL.self) { urls, _ in
                imports.handleOpenURLs(urls)
                return true
            }
            .fileImporter(
                isPresented: $imports.isPickerPresented,
                allowedContentTypes: DocumentTypes.supported,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await imports.importFiles(urls) }
                case .failure(let error):
                    imports.alert = LibraryAlert(title: "Import failed", message: error.localizedDescription)
                }
            }
            .alert(item: $imports.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
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
                #endif
            }
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
