// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct StorageSettingsView: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.nodusPalette) private var palette
    @Query private var books: [Book]

    @State private var booksBytes: Int64 = 0
    @State private var coversBytes: Int64 = 0
    @State private var syncEnabled = false

    private var totalBytes: Int64 {
        booksBytes + coversBytes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("iCloud")
                    Text("One library across your devices will be powered by your personal iCloud account. This build is local-only.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    Toggle("Sync with iCloud", isOn: $syncEnabled)
                        .disabled(true)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 56)
                    Divider().overlay(palette.line)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 18))
                            .foregroundStyle(palette.accent)
                            .frame(width: 36, height: 36)
                            .background(palette.selection, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Local library")
                                .font(.subheadline.weight(.medium))
                            Text("Your documents, metadata and reading progress are stored in this app's container on this device.")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("iCloud sync is planned for a later milestone. Nothing is uploaded by this build.")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    .padding(14)
                }
                .panelCard(radius: 20)

                Eyebrow("On this \(DeviceInfo.platformName)")
                    .padding(.top, 2)

                VStack(spacing: 0) {
                    HStack {
                        Text("Downloaded books")
                            .font(.body)
                        Spacer()
                        Text("\(books.count)")
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    Divider().overlay(palette.line)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Storage")
                                .font(.body)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                                .font(.footnote)
                                .foregroundStyle(palette.muted)
                        }
                        storageBar
                        HStack(spacing: 14) {
                            legend(color: palette.accent,
                                   text: "Books \(ByteCountFormatter.string(fromByteCount: booksBytes, countStyle: .file))")
                            legend(color: palette.violet,
                                   text: "Covers \(ByteCountFormatter.string(fromByteCount: coversBytes, countStyle: .file))")
                        }
                        HStack(spacing: 14) {
                            legend(color: palette.muted, text: "Voices 0 MB")
                            legend(color: palette.muted.opacity(0.6), text: "Caches 0 MB")
                        }
                    }
                    .padding(14)
                }
                .panelCard(radius: 20)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted)
                    Text("Voices, neural models, generated audio and OCR caches stay on this device and are never uploaded.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .navigationTitle("iCloud & Storage")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
        }
        .task {
            booksBytes = library.localLibraryBytes
            coversBytes = library.localCoversBytes
        }
    }

    private var storageBar: some View {
        GeometryReader { proxy in
            let total = max(totalBytes, 1)
            let bookWidth = proxy.size.width * CGFloat(booksBytes) / CGFloat(total)
            HStack(spacing: 0) {
                Rectangle().fill(palette.accent).frame(width: bookWidth)
                Rectangle().fill(palette.violet)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .background(palette.text.opacity(0.08), in: Capsule())
        .accessibilityHidden(true)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(palette.muted)
    }
}

struct PrivacyView: View {
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Privacy")
                    Text("Nodus Reader is local-first by design.")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                }

                section(
                    title: "Your documents",
                    body: "Books, PDFs and notes are read and stored on this device. Nodus Reader has no servers and no Nodus account."
                )
                section(
                    title: "No telemetry",
                    body: "There are no analytics, advertising SDKs, tracking pixels or usage reports. The app does not collect identifiers."
                )
                section(
                    title: "No remote processing",
                    body: "Narration, OCR and document analysis run locally. Documents and generated audio are never sent to a remote service."
                )
                section(
                    title: "Your iCloud",
                    body: "When sync arrives it will use your personal iCloud account through Apple frameworks. Nodus Research will not operate a sync server. Sync will remain optional."
                )
                section(
                    title: "Device-local data",
                    body: "Voice models, audio caches, OCR caches and credentials stay on the device that created them. They are excluded from iCloud sync."
                )
                section(
                    title: "Open source",
                    body: "The source is published under AGPL-3.0-only so the privacy claims above can be audited."
                )

                Link("Read the full privacy policy",
                     destination: URL(string: "https://github.com/jorgepb96/nodus-reader-mobile/blob/main/PRIVACY.md")!)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .navigationTitle("Privacy")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
        }
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.headline, design: .serif))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }
}

struct AboutView: View {
    @Environment(\.nodusPalette) private var palette

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x1D1929), Color(hex: 0x110F18)],
                                   startPoint: .top, endPoint: .bottom)
                    ReaderMark()
                        .padding(18)
                }
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color(hex: 0xC4B5FD, opacity: 0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 22, y: 12)

                VStack(spacing: 4) {
                    Text("Nodus Reader")
                        .font(.system(size: 28, design: .serif))
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                Text("Local-first reading and offline narration for iPhone, iPad and Mac. One library through your own iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .lineSpacing(2)

                VStack(spacing: 0) {
                    linkRow("Source code", url: "https://github.com/jorgepb96/nodus-reader-mobile")
                    divider
                    linkRow("AGPL-3.0-only licence", url: "https://github.com/jorgepb96/nodus-reader-mobile/blob/main/LICENSE")
                    divider
                    linkRow("Third-party notices", url: "https://github.com/jorgepb96/nodus-reader-mobile/blob/main/THIRD_PARTY_NOTICES.md")
                    divider
                    linkRow("Model licences", url: "https://github.com/jorgepb96/nodus-reader-mobile/blob/main/MODEL_LICENSES.md")
                    divider
                    linkRow("Privacy", url: "https://github.com/jorgepb96/nodus-reader-mobile/blob/main/PRIVACY.md")
                }
                .panelCard(radius: 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Acknowledgements")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.muted)
                    Text("The Nodus mark is reused under the MIT licence from Nodus Drift. ZIPFoundation is used under the MIT licence. Nodus Reader is not affiliated with Apple.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .lineSpacing(2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(radius: 16)

                Text("© 2026 Nodus Research · AGPL-3.0-only")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .navigationTitle("About")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
        }
    }

    private var divider: some View {
        Divider().overlay(palette.line).padding(.leading, 14)
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                    .font(.body)
                    .foregroundStyle(palette.text)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }
}
