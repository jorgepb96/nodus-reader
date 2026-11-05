// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// First-run reading and narration choices; downloaded models remain optional on iOS.
struct VoiceSetupView: View {
    @Environment(ModelManager.self) private var models
    @Environment(VoiceCatalog.self) private var voices
    @Environment(\.nodusPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    @AppStorage("nodus.voiceSetup.choice") private var choice = ""
    @State private var showModels = false
    @State private var preparingSystemVoice = false

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 8) {
                            mark
                            Eyebrow("NODUS READER")
                        }
                        .padding(.top, 16)

                        DisplayTitle("A voice for every book.", size: 26)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)

                        #if os(macOS)
                        Text("Read and listen on your device. Choose how you want to get started.")
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)

                        HStack(spacing: 8) {
                            feature("iphone.gen3", "On-device")
                            feature("person.crop.circle.badge.xmark", "No account")
                            feature("wifi.slash", "Works offline")
                        }
                        .padding(.top, 14)

                        #endif

                        #if os(iOS)
                        VStack(spacing: 10) {
                            welcomeChoice("Use iOS voices", detail: "No downloads. Very fast, with less natural voices.", icon: "iphone.gen3", identifier: "VoiceSetupSystem") {
                                guard !preparingSystemVoice else { return }
                                preparingSystemVoice = true
                                Task {
                                    await voices.loadIfNeeded()
                                    preparingSystemVoice = false
                                    guard !voices.systemVoices.isEmpty else { return }
                                    models.selectModel("ios-system")
                                    choice = "system"
                                    dismiss()
                                }
                            }
                            .disabled(preparingSystemVoice)
                            .overlay(alignment: .trailing) {
                                if preparingSystemVoice { ProgressView().padding(.trailing, 12) }
                            }
                            welcomeChoice("Download a model", detail: "More natural voices. Speed depends on the model and device.", icon: "arrow.down.circle", identifier: "VoiceSetupChooseModel") {
                                showModels = true
                            }
                            welcomeChoice("Just read", detail: "Read without narration. You can choose a voice later.", icon: "book", identifier: "VoiceSetupReadOnly") {
                                choice = "read"
                                dismiss()
                            }
                        }
                        .frame(maxWidth: 420)
                        .padding(.top, 18)
                        .padding(.bottom, 16)
                        #else
                        Button { showModels = true } label: {
                            Label("Choose a voice model", systemImage: "waveform.badge.plus")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.onAccent)
                        .accessibilityIdentifier("VoiceSetupChooseModel")
                        .padding(.top, 30).padding(.horizontal, 8).padding(.bottom, 16)
                        #endif
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    #if os(iOS)
                    .frame(minHeight: viewport.size.height)
                    #endif
                }
                .scrollBounceBehavior(.basedOnSize)
            }
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
        .onChange(of: models.selectedModelID) { _, _ in
            #if os(iOS)
            if let model = models.selectedModel, model.engine != .system, models.isInstalled(model) {
                choice = "download"; dismiss()
            }
            #else
            if models.hasInstalledModel { dismiss() }
            #endif
        }
    }

    private func welcomeChoice(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String,
                               identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(palette.accent)
                    Text(detail).font(.caption).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var mark: some View {
        NodusMark()
            .frame(width: 36, height: 40)
            .accessibilityHidden(true)
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
        }
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(palette.panel, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }
}
