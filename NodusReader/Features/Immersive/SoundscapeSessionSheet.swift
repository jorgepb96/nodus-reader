// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Shown when listening starts with AI soundscapes: how many pieces to compose before
/// the voice begins, with visible progress, so the voice and the composer never compete.
/// More are composed later, ahead of the story. Can be turned off for the book or for
/// every book.
struct SoundscapeSessionSheet: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    let book: Book
    /// Starts the narration.
    let onStart: () -> Void
    @State private var composing = false
    @State private var started = false

    var body: some View {
        @Bindable var preferences = immersive.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Music for this session")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("Compose music and ambience for this book before the voice starts, so the two do not compete. More pieces are composed later, while you listen, when the story needs them.")
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if composing {
                    progress
                } else {
                    choices
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Don't ask for this book", isOn: Binding(get: { !immersive.asksSession(for: book) },
                                                                   set: { immersive.setAsksSession(!$0, for: book) }))
                        .accessibilityIdentifier("soundscapes.session.dontAskBook")
                    Toggle("Don't ask again", isOn: Binding(get: { !preferences.askBeforeSession },
                                                            set: { preferences.askBeforeSession = !$0 }))
                        .accessibilityIdentifier("soundscapes.session.dontAsk")
                    Text("Turn it back on in this book's atmosphere panel, or for every book in Settings › Soundscapes › More options.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .tint(palette.accent)
            }
            .padding(20)
        }
        // Its own background: the system's translucent sheet does not follow the
        // reader's theme, and the palette's text was unreadable on it.
        .background(palette.background)
        .presentationBackground(palette.background)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(composing)
        // Asked once per book and run, counted only once the sheet is really on screen
        // (a play pressed while the book was still opening could not present it).
        .onAppear { immersive.markSessionOffered(book) }
        .onChange(of: immersive.generation) { _, status in
            // The session's pieces are ready: the voice starts.
            if composing, case .preparing = status {} else if composing { start() }
        }
    }

    private var choices: some View {
        VStack(spacing: 10) {
            choice(1, title: "1 piece", detail: "Starts soonest")
            choice(3, title: "3 pieces", detail: "Recommended: music and an ambience", recommended: true)
            choice(6, title: "6 pieces", detail: "More variety from the start")
            Button {
                start()
            } label: {
                Text("Start without waiting").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("soundscapes.session.skip")
        }
    }

    private func choice(_ count: Int, title: LocalizedStringKey, detail: LocalizedStringKey,
                        recommended: Bool = false) -> some View {
        Button {
            composing = true
            immersive.prepareSession(for: book, count: count)
            // Nothing could be composed (no model for these layers): start at once.
            if case .preparing = immersive.generation {} else { start() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(palette.text)
            .background(recommended ? palette.selection : palette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(recommended ? palette.accent : palette.line, lineWidth: recommended ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("soundscapes.session.compose\(count)")
    }

    @ViewBuilder
    private var progress: some View {
        if case .preparing(let done, let total) = immersive.generation {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(palette.accent)
                Text("Composing \(min(done + 1, total)) of \(total)…")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("soundscapes.session.progress")
        }
        Button("Start now") { start() }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("soundscapes.session.startNow")
    }

    private func start() {
        guard !started else { return }
        started = true
        immersive.sessionStarted()
        dismiss()
        onStart()
    }
}
