// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SquareCoverThumb: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.nodusPalette) private var palette
    let book: Book
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 9

    private var url: URL? {
        guard let url = library.fileStore.coverURL(for: book.coverFileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        Group {
            if let url {
                StoredCoverImage(url: url)
            } else {
                CoverPalette.pair(for: book.title).background
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(palette.line, lineWidth: 0.5)
        )
    }
}

struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    var onOpen: () -> Void
    @State private var readingBook: Book?

    var body: some View {
        HStack(spacing: 11) {
            Button {
                if let book = playback.activeBook, playback.mode != .listen {
                    if playback.mode == .readAndListen { playback.requestReaderResume() }
                    readingBook = book
                } else {
                    onOpen()
                }
            } label: {
                HStack(spacing: 11) {
                    if let book = playback.activeBook {
                        SquareCoverThumb(book: book)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playback.activeBook?.title ?? "")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Text("Ch. \(playback.chapterNumber) · \(playback.voiceLabel) · \(playback.speedLabel)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("MiniPlayerOpen")
            .accessibilityLabel(playback.mode == .listen
                ? Text("Open player, \(playback.activeBook?.title ?? "")")
                : Text("Read, \(playback.activeBook?.title ?? "")"))
            .accessibilityHint(playback.mode == .listen
                ? Text("Shows the expanded player")
                : Text("Returns to the current reading position"))

            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.playbackActionSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .offset(x: playback.isPlaying || playback.narrationFinished ? 0 : 1)
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 42, height: 42)
                    .background(palette.accent, in: Circle())
                    .overlay {
                        if playback.isLoading {
                            LoadingRing(color: palette.onAccent, lineWidth: 2.5).padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.narrationFinished ? "Replay from beginning" : playback.isPlaying ? "Pause narration" : "Play narration")

            // Ends narration and removes the mini player.
            Button {
                playback.stopAndClose()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 42, height: 42)
                    .background(palette.panel, in: Circle())
                    .overlay(Circle().stroke(palette.line, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop narration")
            .accessibilityHint("Stops playback and closes the player")
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(height: 58)
        .background(palette.panelRaised, in: Capsule())
        .overlay(Capsule().stroke(palette.accent.opacity(0.14), lineWidth: 1))
        .shadow(color: palette.shadow, radius: 16, y: 8)
        .readerCover(item: $readingBook)
    }
}

struct MiniPlayerModifier: ViewModifier {
    @Environment(PlaybackController.self) private var playback
    @Binding var showPlayer: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if playback.hasActiveBook {
                    MiniPlayerBar { showPlayer = true }
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                }
            }
            .playerSheet(isPresented: $showPlayer)
    }
}

/// Finish dismissing the audio panel before presenting the full reader.
/// Both phone and tablet use the same transition from the mode control.
private struct PlayerSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    @State private var pendingReaderBook: Book?
    @State private var readingBook: Book?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .macPlayerPresentation(isPresented: $isPresented, onOpenReader: { pendingReaderBook = $0 })
            .onChange(of: isPresented) { _, presented in
                guard !presented, let book = pendingReaderBook else { return }
                pendingReaderBook = nil
                readingBook = book
            }
            .readerCover(item: $readingBook)
        #else
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                guard let book = pendingReaderBook else { return }
                pendingReaderBook = nil
                readingBook = book
            }) {
                PlayerView(onOpenReader: { pendingReaderBook = $0 })
                    .presentationDragIndicator(.hidden)
            }
            .readerCover(item: $readingBook)
        #endif
    }
}

#if os(macOS)
/// A compact panel sized from its content and the host window, rather than
/// a tall form sheet. Dismissal never stops the narration.
private struct MacPlayerPresentation: ViewModifier {
    @Environment(\.nodusPalette) private var inheritedPalette
    @Binding var isPresented: Bool
    var paletteOverride: NodusPalette?
    var onOpenReader: (Book) -> Void
    @FocusState private var panelFocused: Bool

    func body(content: Content) -> some View {
        let palette = paletteOverride ?? inheritedPalette
        content
            .allowsHitTesting(!isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black.opacity(0.18)
                                .contentShape(Rectangle())
                                .onTapGesture { isPresented = false }
                                .accessibilityHidden(true)
                            PlayerView(onOpenReader: onOpenReader,
                                       onClose: { isPresented = false },
                                       availableHeight: max(0, geometry.size.height - 32))
                                .frame(width: min(820, max(0, geometry.size.width - 32)))
                                .nodusPalette(palette)
                                .tint(palette.accent)
                                .background {
                                    MacPlayerDismissRegion { isPresented = false }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(palette.line, lineWidth: 1))
                                .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
                                .contentShape(Rectangle())
                                .onTapGesture { }
                                .focusable()
                                .focusEffectDisabled()
                                .focused($panelFocused)
                                .onExitCommand { isPresented = false }
                                .onAppear { panelFocused = true }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
    }
}

/// Also dismiss when a click lands in the sidebar or native toolbar, beyond
/// the SwiftUI backdrop. Consume that click so it only closes the panel.
private struct MacPlayerDismissRegion: NSViewRepresentable {
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onDismiss = onDismiss
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak coordinator = context.coordinator] event in
            let outside = MainActor.assumeIsolated {
                guard let coordinator, let view = coordinator.view,
                      let window = view.window, event.window === window,
                      window.attachedSheet == nil else { return false }
                guard !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
                coordinator.onDismiss?()
                return true
            }
            return outside ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        coordinator.view = nil
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var onDismiss: (() -> Void)?
        var monitor: Any?
    }
}

extension View {
    func macPlayerPresentation(isPresented: Binding<Bool>, palette: NodusPalette? = nil,
                               onOpenReader: @escaping (Book) -> Void) -> some View {
        modifier(MacPlayerPresentation(isPresented: isPresented, paletteOverride: palette, onOpenReader: onOpenReader))
    }
}
#endif

extension View {
    func playerSheet(isPresented: Binding<Bool>) -> some View {
        modifier(PlayerSheetModifier(isPresented: isPresented))
    }

    func miniPlayer(showPlayer: Binding<Bool>) -> some View {
        modifier(MiniPlayerModifier(showPlayer: showPlayer))
    }
}
