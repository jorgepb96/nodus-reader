// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Offered when play is pressed at the start of a session with AI soundscapes: compose
/// this session's music first, with visible progress, so the voice and the composer
/// never compete. The reader can start at once or turn the question off.
struct SoundscapeSessionSheet: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    /// Starts the narration.
    let onStart: () -> Void
    @State private var composing = false

    var body: some View {
        @Bindable var preferences = immersive.preferences
        VStack(alignment: .leading, spacing: 16) {
            Text("Music for this session")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("Compose the music and ambience for this book before the voice starts. It takes about a minute on this device, and the voice waits so the two do not compete.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if composing, case .preparing(let done, let total) = immersive.generation {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(palette.accent)
                    Text("Composing \(min(done + 1, total)) of \(total)…")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("soundscapes.session.progress")
                Button("Start now") { start() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("soundscapes.session.startNow")
            } else {
                Button {
                    composing = true
                    immersive.prepareSession()
                    if case .preparing = immersive.generation {} else { start() }
                } label: {
                    Text("Compose and start").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .accessibilityIdentifier("soundscapes.session.compose")
                Button {
                    start()
                } label: {
                    Text("Start without waiting").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("soundscapes.session.skip")
            }
            Toggle("Don't ask again", isOn: Binding(get: { !preferences.askBeforeSession },
                                                    set: { preferences.askBeforeSession = !$0 }))
                .font(.subheadline)
                .tint(palette.accent)
                .accessibilityIdentifier("soundscapes.session.dontAsk")
            Text("You can turn this back on in Settings › Soundscapes › More options.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .presentationDetents([.medium])
        .onChange(of: immersive.generation) { _, status in
            // The session's pieces are ready: the voice starts.
            if composing, case .preparing = status {} else if composing { start() }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        dismiss()
        onStart()
    }

    @State private var started = false
}
