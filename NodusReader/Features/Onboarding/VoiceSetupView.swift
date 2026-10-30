// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// First-run invitation to install a neural voice. Nodus no longer offers the
/// system's AVSpeechSynthesisVoice catalogue; a model is required for narration.
struct VoiceSetupView: View {
    @Environment(ModelManager.self) private var models
    @Environment(\.nodusPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var showModels = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    mark
                        .padding(.top, 44)

                    Eyebrow("NODUS READER")
                        .padding(.top, 24)

                    DisplayTitle("A voice for every book.", size: 38)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 8)

                    Text("Nodus narrates with neural voices that run entirely on this device. Download a voice model to start listening offline.")
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
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Quit Nodus Reader") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                        .accessibilityIdentifier("VoiceSetupQuitApp")
                }
            }
            #endif
        }
        #if os(iOS)
        .interactiveDismissDisabled()
        #endif
        .onChange(of: models.hasInstalledModel) { _, installed in
            if installed { dismiss() }
        }
    }

    private var mark: some View {
        NodusMark()
            .frame(width: 140, height: 156)
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
}
