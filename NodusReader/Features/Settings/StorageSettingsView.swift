// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct StorageSettingsView: View {
    @Environment(LibraryService.self) private var library
    @Environment(CloudSyncService.self) private var sync
    @Environment(ModelManager.self) private var models
    @Environment(PlaybackController.self) private var playback
    @Environment(StorageJanitor.self) private var janitor
    @Environment(\.nodusPalette) private var palette
    @Query private var books: [Book]

    @State private var booksBytes: Int64 = 0
    @State private var coversBytes: Int64 = 0
    @State private var ocrBytes: Int64 = 0
    @State private var isFreeingSpace = false
    /// The result of Free Space Now, shown only after the user asked for it.
    @State private var freedReport: StorageJanitor.Report?

    private var totalBytes: Int64 {
        booksBytes + coversBytes + modelBytes + audioBytes + ocrBytes
    }

    private var modelBytes: Int64 {
        models.storage.kokoroBytes + models.storage.phononBytes + models.storage.mingBytes
    }

    private var audioBytes: Int64 {
        models.storage.narrationCacheBytes
    }

    private var cloudOnlyBooks: [Book] {
        books.filter { $0.downloadState == .cloudOnly }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var downloadedCount: Int {
        books.filter { $0.downloadState == .downloaded }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("iCloud")
                    Text("One library across your devices through your personal iCloud account.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                syncCard

                statusCard
                if sync.isEnabled, !cloudOnlyBooks.isEmpty {
                    cloudLibraryCard
                }

                Eyebrow("On this \(DeviceInfo.platformName)")
                    .padding(.top, 2)

                VStack(spacing: 0) {
                    HStack {
                        Text("Downloaded books")
                            .font(.body)
                        Spacer()
                        Text("\(downloadedCount) of \(books.count)")
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
                            legend(color: palette.violet.opacity(0.7),
                                   text: "Models \(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))")
                            legend(color: palette.muted.opacity(0.6),
                                   text: "Audio cache \(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file))")
                        }
                        legend(color: palette.accent.opacity(0.4),
                               text: "OCR cache \(ByteCountFormatter.string(fromByteCount: ocrBytes, countStyle: .file))")
                        if audioBytes > 0 {
                            Button("Delete generated audio") {
                                Task {
                                    await playback.deleteAllNarrationCaches()
                                    await refreshAll()
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.top, 2)
                        }
                    }
                    .padding(14)
                }
                .panelCard(radius: 20)

                cleanupCard

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted)
                    Text("Metadata and annotations sync through your private CloudKit database. Original documents and covers live in your iCloud Drive. Voices, neural models, generated audio, OCR caches and credentials stay on this device and are never uploaded.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        troubleshootingLine(
                            "Sync is optional and off by default. Turning it off leaves every local file untouched."
                        )
                        troubleshootingLine(
                            "If iCloud is unavailable, check that you are signed in to iCloud and that iCloud Drive is enabled for Nodus Reader."
                        )
                        troubleshootingLine(
                            "A document uploaded on another device may take a moment to appear. Pull to refresh or tap Check Again."
                        )
                        troubleshootingLine(
                            "Removing a download keeps the book in your library and in iCloud. Delete from Library removes it everywhere."
                        )
                        if !sync.availabilityMessage.isEmpty {
                            Text(sync.availabilityMessage)
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .padding(.top, 2)
                        }
                        Button("Check Again") {
                            Task {
                                await sync.refreshAvailability()
                                await sync.syncNow()
                            }
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.accent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Troubleshooting")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.text)
                }
                .padding(14)
                .panelCard(radius: 16)
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
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
        .refreshable {
            await sync.refreshAvailability()
            await sync.syncNow()
            await refreshAll()
        }
        .task {
            await refreshAll()
            await sync.refreshAvailability()
        }
    }

    /// The automatic cleanup rules. They only delete what can be generated
    /// again: narration audio and OCR results.
    private var cleanupCard: some View {
        @Bindable var janitor = janitor
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unused books")
                        .font(.body)
                    Text("Delete their audio and OCR cache")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                Picker("Unused books", selection: $janitor.unusedDays) {
                    ForEach(StorageJanitor.unusedDaysOptions, id: \.self) { days in
                        if days == 0 {
                            Text("Never").tag(days)
                        } else {
                            Text("After \(days) days").tag(days)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(palette.accent)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)

            Divider().overlay(palette.line)

            Toggle(isOn: $janitor.deleteFinished) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finished books")
                        .font(.body)
                    Text("Delete their audio and OCR cache a week after you last opened them")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 60)

            Divider().overlay(palette.line)

            VStack(alignment: .leading, spacing: 8) {
                Text("Narration audio is limited to \(ByteCountFormatter.string(fromByteCount: StorageJanitor.Policy().audioCapBytes, countStyle: .file)): beyond that, the books you opened longest ago go first. The book you are reading or listening to is always kept. Documents, notes, highlights and voice models are never deleted automatically; audio is generated again when you listen.")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Task { await freeSpace() }
                    } label: {
                        Text("Free space now")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .disabled(isFreeingSpace)
                    if isFreeingSpace {
                        ProgressView().controlSize(.small)
                    } else if let report = freedReport {
                        Text(report.freedBytes > 0
                             ? "Freed \(ByteCountFormatter.string(fromByteCount: report.freedBytes, countStyle: .file))"
                             : "Nothing to free")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .panelCard(radius: 20)
    }

    private func freeSpace() async {
        isFreeingSpace = true
        freedReport = await janitor.run(protected: Set([playback.activeBook?.id].compactMap { $0 }))
        await refreshAll()
        isFreeingSpace = false
    }

    private func refreshAll() async {
        await refreshStorage()
        await models.refreshStorage()
        ocrBytes = await janitor.ocrBytes()
    }

    private var syncCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { sync.isEnabled },
                set: { value in
                    Task { await sync.setEnabled(value) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync with iCloud")
                        .font(.body)
                    Text(sync.isEnabled
                         ? "Your library is kept in step across your devices."
                         : "Your library stays on this device.")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
            }
            .tint(palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 64)

            Divider().overlay(palette.line)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sync.isEnabled ? "icloud.fill" : "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.accent)
                    .frame(width: 36, height: 36)
                    .background(palette.selection, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(sync.isEnabled ? "Private iCloud library" : "Local library")
                        .font(.subheadline.weight(.medium))
                    Text(sync.isEnabled
                         ? "CloudKit stores titles, collections, bookmarks, notes and reading positions. iCloud Drive stores the documents and covers."
                         : "Your documents, metadata and reading progress are stored in this app's container on this device.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !sync.isEnabled {
                        Text("You can enable sync at any time. Local data is never deleted when you do.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(14)
        }
        .panelCard(radius: 20)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 32, height: 32)
                    .background(statusColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(sync.status.title)
                        .font(.subheadline.weight(.semibold))
                    if let detail = sync.status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if sync.isSyncing {
                    ProgressView().controlSize(.small)
                }
            }

            if sync.isAvailable {
                HStack(spacing: 14) {
                    Text(sync.lastSyncText)
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                    if sync.pendingCount > 0 {
                        Text("· \(sync.pendingCount) waiting")
                            .font(.caption2)
                            .foregroundStyle(palette.muted)
                    }
                }
            } else if sync.isEnabled, !sync.availabilityMessage.isEmpty {
                Text(sync.availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sync.isAvailable {
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Text(sync.isSyncing ? "Syncing…" : "Sync Now")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(sync.isSyncing)
            }

            if let error = sync.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 18)
    }

    private var cloudLibraryCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In iCloud only")
                        .font(.body)
                    Text(cloudOnlyBooks.count == 1 ? "1 book is not downloaded on this \(DeviceInfo.platformName)." : "\(cloudOnlyBooks.count) books are not downloaded on this \(DeviceInfo.platformName).")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
                Spacer()
                Button("Download All") {
                    Task { await sync.downloadAllCloudOnlyBooks() }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
            }
            .padding(14)

            Divider().overlay(palette.line)

            ForEach(cloudOnlyBooks) { book in
                HStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.accent)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(book.title)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text("\(book.format.badge) · \(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))")
                            .font(.caption2)
                            .foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: 8)
                    if sync.downloadingBookIDs.contains(book.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Download") {
                            Task { await sync.download(book) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                Divider().overlay(palette.line).padding(.leading, 50)
            }
        }
        .panelCard(radius: 20)
    }

    private var statusSymbol: String {
        switch sync.status {
        case .disabled: "icloud.slash"
        case .unavailable: "exclamationmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .waiting: "clock.arrow.circlepath"
        case .offline: "icloud.slash"
        case .error: "xmark.icloud"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .disabled, .offline, .waiting: palette.muted
        case .unavailable, .error: palette.accent
        case .syncing, .upToDate: palette.accent
        }
    }

    private func troubleshootingLine(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(palette.muted.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Walking the library and cover folders is filesystem work; keep it off
    /// the main thread so opening this screen never stalls.
    private func refreshStorage() async {
        let store = library.fileStore
        let sizes = await Task.detached(priority: .utility) {
            (store.librarySize(), store.coversSize())
        }.value
        booksBytes = sizes.0
        coversBytes = sizes.1
    }

    private var storageBar: some View {
        GeometryReader { proxy in
            let total = max(totalBytes, 1)
            let width = proxy.size.width
            HStack(spacing: 0) {
                Rectangle().fill(palette.accent)
                    .frame(width: width * CGFloat(booksBytes) / CGFloat(total))
                Rectangle().fill(palette.violet)
                    .frame(width: width * CGFloat(coversBytes) / CGFloat(total))
                Rectangle().fill(palette.violet.opacity(0.45))
                    .frame(width: width * CGFloat(modelBytes) / CGFloat(total))
                Rectangle().fill(palette.muted.opacity(0.55))
                    .frame(width: width * CGFloat(audioBytes) / CGFloat(total))
                Rectangle().fill(palette.accent.opacity(0.4))
                    .frame(width: width * CGFloat(ocrBytes) / CGFloat(total))
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .background(palette.text.opacity(0.08), in: Capsule())
        .accessibilityHidden(true)
    }

    private func legend(color: Color, text: LocalizedStringKey) -> some View {
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
                    body: "Books, PDFs and notes are read and stored on this device."
                )
                section(
                    title: "No telemetry",
                    body: "There are no analytics, advertising SDKs, tracking pixels or usage reports. The app does not collect identifiers."
                )
                section(
                    title: "No remote processing",
                    body: "Narration, OCR, document analysis and recaps run on this device; recaps use Apple Intelligence’s on-device model. Generated audio stays on this device."
                )
                section(
                    title: "Your iCloud",
                    body: "Sync is optional and off by default. When you enable it, Nodus Reader uses your personal iCloud account through CloudKit and iCloud Drive."
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
                     destination: URL(string: "https://github.com/jorgepb96/nodus-reader/blob/main/PRIVACY.md")!)
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
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
    }

    private func section(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
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
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    LinearGradient(colors: [NodusColors.iconBackgroundTop, NodusColors.iconBackgroundBottom],
                                   startPoint: .top, endPoint: .bottom)
                    ReaderMark()
                        .padding(18)
                }
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(NodusColors.iconHairline, lineWidth: 1)
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
                    linkRow("Source code", url: "https://github.com/jorgepb96/nodus-reader")
                    divider
                    linkRow("AGPL-3.0-only licence", url: "https://github.com/jorgepb96/nodus-reader/blob/main/LICENSE")
                    divider
                    linkRow("Third-party notices", url: "https://github.com/jorgepb96/nodus-reader/blob/main/THIRD_PARTY_NOTICES.md")
                    divider
                    linkRow("Model licences", url: "https://github.com/jorgepb96/nodus-reader/blob/main/MODEL_LICENSES.md")
                    divider
                    linkRow("Privacy", url: "https://github.com/jorgepb96/nodus-reader/blob/main/PRIVACY.md")
                    divider
                    NavigationLink {
                        ImmersiveCreditsView()
                    } label: {
                        SettingsRow(title: "Audio credits", value: nil)
                    }
                    .buttonStyle(.plain)
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
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
    }

    private var divider: some View {
        Divider().overlay(palette.line).padding(.leading, 14)
    }

    private func linkRow(_ title: LocalizedStringKey, url: String) -> some View {
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
