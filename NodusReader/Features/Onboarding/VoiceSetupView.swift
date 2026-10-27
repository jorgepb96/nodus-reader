// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// First-run invitation to install a neural voice. Nodus no longer offers the
/// system's AVSpeechSynthesisVoice catalogue; a model is required for narration.
struct VoiceSetupView: View {
    @Environment(ModelManager.self) private var models
    @Environment(\.nodusPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Called when the user installs a model or chooses to continue later.
    let onFinish: () -> Void

    @State private var showModels = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    mark
                        .padding(.top, 34)

                    Eyebrow("NODUS READER")
                        .padding(.top, 24)

                    DisplayTitle("A voice for every book.", size: 38)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 8)

                    Text("Nodus narrates with neural voices that run entirely on this device. Install one model to start listening — no account, no cloud, no system voice.")
                        .font(.callout)
                        .foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                        .padding(.horizontal, 18)

                    HStack(spacing: 8) {
                        feature("iphone.gen3", "On-device")
                        feature("person.crop.circle.badge.xmark", "No account")
                        feature("wifi.slash", "Works offline")
                    }
                    .padding(.top, 22)

                    VStack(spacing: 12) {
                        Button {
                            showModels = true
                        } label: {
                            Label("Choose a voice model", systemImage: "waveform.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .foregroundStyle(palette.onAccent)
                        .accessibilityIdentifier("VoiceSetupChooseModel")

                        Button("Not now") {
                            finish()
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.muted)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("VoiceSetupNotNow")
                    }
                    .padding(.top, 30)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(palette.background.ignoresSafeArea())
            .navigationDestination(isPresented: $showModels) {
                VoicesView(initialMode: .models)
            }
        }
        .onChange(of: models.hasInstalledModel) { _, installed in
            if installed { finish() }
        }
    }

    private var mark: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [palette.accent.opacity(0.26), palette.accent.opacity(0.03)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 108
                    )
                )
                .frame(width: 196, height: 196)
            Circle()
                .stroke(palette.line, lineWidth: 1)
                .frame(width: 196, height: 196)
            NodusMark()
                .frame(width: 108, height: 120)
        }
        .accessibilityHidden(true)
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(palette.panel, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}
