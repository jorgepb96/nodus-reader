// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import DesignSystem
import SwiftUI

/// Settings › Soundscapes › More options › Favorites: generated pieces marked with a
/// heart. They are never deleted to make space and come back twice as often.
struct SoundscapeFavoritesView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?

    private var favorites: [GeneratedPiece] {
        immersive.generated.pieces.filter(\.favorite).sorted { $0.created > $1.created }
    }

    var body: some View {
        List {
            if favorites.isEmpty {
                Text("Tap the heart while an AI piece plays to keep it here.")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
            }
            ForEach(favorites) { piece in
                HStack(spacing: 12) {
                    Button {
                        toggle(piece)
                    } label: {
                        Image(systemName: playingID == piece.id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(palette.accent)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(playingID == piece.id ? "Stop" : "Play"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(piece.mood?.label ?? piece.bed?.label ?? "")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                        Text("\(piece.style.label) · \(piece.promptText)")
                            .font(.caption2)
                            .foregroundStyle(palette.muted)
                            .lineLimit(2)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        stop()
                        immersive.generated.delete(piece.id)
                    }
                    Button("Remove") { immersive.generated.setFavorite(piece.id, false) }
                }
                .contextMenu {
                    Button("Remove from favorites", systemImage: "heart.slash") { immersive.generated.setFavorite(piece.id, false) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        stop()
                        immersive.generated.delete(piece.id)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Favorites")
        .inlineNavigationTitle()
        .onDisappear { stop() }
    }

    private func toggle(_ piece: GeneratedPiece) {
        if playingID == piece.id {
            stop()
            return
        }
        stop()
        guard let url = immersive.generated.url(for: piece.track),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = piece.layer == .ambience ? -1 : 0
        player.play()
        self.player = player
        playingID = piece.id
    }

    private func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}
