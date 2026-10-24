// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

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

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onOpen) {
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
            .accessibilityLabel("Open player, \(playback.activeBook?.title ?? "")")
            .accessibilityHint("Shows the expanded player")

            Button {
                playback.toggle()
            } label: {
                Group {
                    if playback.isLoading {
                        ProgressView().tint(palette.onAccent)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
                .foregroundStyle(palette.onAccent)
                .frame(width: 42, height: 42)
                .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause narration" : "Play narration")
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(height: 58)
        .background(palette.panelRaised, in: Capsule())
        .overlay(Capsule().stroke(palette.accent.opacity(0.14), lineWidth: 1))
        .shadow(color: palette.shadow, radius: 16, y: 8)
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
            .sheet(isPresented: $showPlayer) {
                PlayerView()
                    .presentationDragIndicator(.hidden)
            }
    }
}

extension View {
    func miniPlayer(showPlayer: Binding<Bool>) -> some View {
        modifier(MiniPlayerModifier(showPlayer: showPlayer))
    }
}
