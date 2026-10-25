// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import DesignSystem
import SwiftUI

struct PhoneRootView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette
    @State private var showPlayer = false

    var body: some View {
        @Bindable var navigation = navigation

        tabView(selection: $navigation.phoneTab)
            .safeAreaInset(edge: .bottom) {
                if playback.hasActiveBook {
                    miniPlayer
                        .padding(.horizontal, 16)
                        .padding(.bottom, miniPlayerBottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: playback.hasActiveBook)
            .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDragIndicator(.hidden)
        }
    }

    private func tabView(selection: Binding<AppTab>) -> some View {
        TabView(selection: selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                tabScreen { HomeView() }
            }
            Tab("Library", systemImage: "square.grid.2x2", value: AppTab.library) {
                tabScreen { LibraryView() }
            }
            Tab("Collections", systemImage: "folder", value: AppTab.collections) {
                tabScreen { CollectionsView() }
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                tabScreen { SettingsView() }
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

    /// The iOS 26 floating tab bar samples its glass backdrop from the content
    /// below it. Fading to the app background keeps bright covers from bleeding
    /// through without cutting scrolled content off with a hard edge.
    private func tabScreen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: palette.background.opacity(0), location: 0),
                    .init(color: palette.background.opacity(0.92), location: 0.20),
                    .init(color: palette.background, location: 0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 130)
            .offset(y: 95)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
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
