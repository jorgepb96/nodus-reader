// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import DesignSystem
import SwiftUI

struct PhoneRootView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(PlaybackController.self) private var playback
    @State private var showPlayer = false

    var body: some View {
        @Bindable var navigation = navigation

        tabView(selection: $navigation.phoneTab)
            .safeAreaInset(edge: .bottom) {
                if playback.hasActiveBook {
                    miniPlayer
                        .padding(.horizontal, 16)
                        .padding(.bottom, miniPlayerBottomInset)
                }
            }
            .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDragIndicator(.hidden)
        }
    }

    private func tabView(selection: Binding<AppTab>) -> some View {
        TabView(selection: selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView()
                }
            }
            Tab("Library", systemImage: "square.grid.2x2", value: AppTab.library) {
                NavigationStack {
                    LibraryView()
                }
            }
            Tab("Collections", systemImage: "folder", value: AppTab.collections) {
                NavigationStack {
                    CollectionsView()
                }
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack {
                    SearchView()
                }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
    }

    private var miniPlayerBottomInset: CGFloat {
        if #available(iOS 26.0, *) { 64 } else { 4 }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if playback.hasActiveBook {
            MiniPlayerBar {
                showPlayer = true
            }
        }
    }
}
#endif
