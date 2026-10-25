// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Plain-language help for the optional Hugging Face token: what the site is,
/// how to create a read token, and how to accept a gated model's licence,
/// with links to the gated models listed in Voices.
struct HuggingFaceGuideView: View {
    /// Models whose publisher asks for an accepted licence before download.
    let gatedModels: [ModelManager.Model]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("What is Hugging Face?", systemImage: "building.columns") {
                        paragraph("Hugging Face (huggingface.co) is a website where companies and researchers publish AI models. Nodus Reader downloads its narration voices from there.")
                        paragraph("The download goes straight to this device. Your books, notes and audio are never sent to Hugging Face.")
                    }

                    section("Do I need an account?", systemImage: "person.crop.circle.badge.questionmark") {
                        paragraph("No, not for the voices you can download in this version. Kokoro 82M and Phonon 31M are public: anyone can download them without an account or a token.")
                        paragraph("Some models are \"gated\": the publisher asks you to sign in and accept their licence before you can download them. A token is how an app proves to Hugging Face that it is acting for your account.")
                    }

                    section("How to get a token", systemImage: "key") {
                        step(1, "Create a free account, or sign in if you already have one.")
                        link("Create an account", url: "https://huggingface.co/join")
                        step(2, "Open the Access Tokens page in your account settings.")
                        link("Open Access Tokens", url: "https://huggingface.co/settings/tokens")
                        step(3, "Select \"Create new token\". Choose the \"Read\" token type, type a name such as \"Nodus Reader\", and create the token.")
                        step(4, "Copy the token. It starts with \"hf_\".")
                        step(5, "Come back to this screen, paste the token in the field, select \"Save token\" and then \"Verify\".")
                        paragraph("The token is stored in this device's Keychain only. It is not synced with iCloud and Nodus Reader does not send it anywhere except Hugging Face. You can remove it here, or delete it on the Access Tokens page, at any time.")
                    }

                    section("How to accept a gated model", systemImage: "checkmark.seal") {
                        step(1, "Sign in to Hugging Face in your web browser, with the same account as your token.")
                        step(2, "Open the model's page. The links are below.")
                        step(3, "Read the licence. If you agree with it, fill in the short form on the page and select the button to agree and request access.")
                        step(4, "Some publishers approve requests at once; others review them by hand. The model page tells you when your account has access.")
                    }

                    if !gatedModels.isEmpty {
                        section("Models that need an accepted licence", systemImage: "lock.doc") {
                            ForEach(gatedModels) { model in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.text)
                                    Text("Licence: \(model.license)")
                                        .font(.caption)
                                        .foregroundStyle(palette.muted)
                                    if !model.isAvailable {
                                        Text("Not available in this version of Nodus Reader: there is no Core ML version of this model that runs on Apple devices yet. Accepting the licence now only gives your account access for later.")
                                            .font(.caption)
                                            .foregroundStyle(palette.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Link(destination: model.source) {
                                        Label(model.source.absoluteString, systemImage: "arrow.up.right.square")
                                            .font(.footnote)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .foregroundStyle(palette.accent)
                                    .frame(minHeight: 44, alignment: .leading)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .panelCard(radius: 14)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(palette.background)
            .navigationTitle("Hugging Face token")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func section<Content: View>(_ title: LocalizedStringKey, systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(palette.text)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(palette.accent)
            Text(text)
                .font(.callout)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func link(_ title: LocalizedStringKey, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Label(title, systemImage: "arrow.up.right.square")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(palette.accent)
        .frame(minHeight: 44, alignment: .leading)
        .padding(.leading, 26)
    }
}
