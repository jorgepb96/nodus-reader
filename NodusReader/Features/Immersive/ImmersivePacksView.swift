// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Settings › Immersive Audio › Sound packs: download, pause and delete.
struct ImmersivePacksView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette
    @State private var pendingDelete: ImmersiveCatalog.Pack?

    private var library: ImmersiveAudioLibrary { immersive.library }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Sound packs")
                    Text("Instrumental music and recorded ambiences under free licences (CC0 and CC-BY), selected for reading. They are downloaded once, verified, stored on this device and never synced.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if library.packs.isEmpty {
                    NodusEmptyState(icon: "speaker.slash", title: "No sound packs in this build",
                                    message: "This build does not include the sound catalog.")
                }
                ForEach(library.packs) { pack in
                    packCard(pack)
                }
                HStack {
                    Text("On this device")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: library.bytesOnDisk, countStyle: .file))
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .panelCard(radius: 16)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Sound packs")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
        .onAppear { library.refresh() }
        .confirmationDialog("Delete Sound Pack?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { library.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You can download it again at any time.")
        }
    }

    private func packCard(_ pack: ImmersiveCatalog.Pack) -> some View {
        let tracks = library.catalog?.tracks(in: pack) ?? []
        let music = tracks.filter { $0.layer == .music }.count
        let beds = tracks.filter { $0.layer == .ambience }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(pack))
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text(detail(pack))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
            Text("\(music) music pieces · \(beds) ambiences")
                .font(.caption)
                .foregroundStyle(palette.muted)
            state(pack)
        }
        .padding(14)
        .panelCard(radius: 20)
    }

    @ViewBuilder
    private func state(_ pack: ImmersiveCatalog.Pack) -> some View {
        switch library.state(pack) {
        case .notInstalled:
            PrimaryPillButton("Download", systemImage: "arrow.down.circle") { library.install(pack) }
                .disabled(library.isDevelopmentPack)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(palette.accent)
                    .accessibilityLabel(Text("Downloading"))
                    .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)))))
                OutlinePillButton("Pause", systemImage: "pause") { library.pause(pack) }
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress).tint(palette.muted)
                HStack {
                    PrimaryPillButton("Resume", systemImage: "arrow.down.circle") { library.install(pack) }
                    OutlinePillButton("Delete partial download", systemImage: "trash") { pendingDelete = pack }
                }
            }
        case .installed:
            HStack {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.accent)
                Spacer()
                if !library.isDevelopmentPack {
                    Button("Delete", role: .destructive) { pendingDelete = pack }
                        .font(.subheadline.weight(.medium))
                        .nodusTextButtonStyle()
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryPillButton("Try again", systemImage: "arrow.clockwise") { library.install(pack) }
            }
        }
    }

    private func title(_ pack: ImmersiveCatalog.Pack) -> String {
        switch pack.id {
        case "essentials": String(localized: "Essentials")
        case "narrative": String(localized: "Narrative music")
        case "ambience": String(localized: "Ambiences")
        default: pack.id.capitalized
        }
    }

    private func detail(_ pack: ImmersiveCatalog.Pack) -> String {
        switch pack.id {
        case "essentials": String(localized: "Calm, contemplative, mysterious and focus music with rain, forest, fireplace and library beds. Enough for every mode.")
        case "narrative": String(localized: "More moods for stories: melancholy, romance, adventure, tension, epic and solemn moments.")
        case "ambience": String(localized: "More places: sea, stream, wind, storm, tavern, city, cave and forest at night.")
        default: ""
        }
    }
}

/// Every piece of audio, where it comes from and its licence.
struct ImmersiveCreditsView: View {
    @Environment(ImmersiveAudioController.self) private var immersive
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        let tracks = (immersive.library.catalog?.tracks ?? []).sorted { ($0.layer.rawValue, $0.title) < ($1.layer.rawValue, $1.title) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Credits and licences")
                    Text("Every sound was chosen for Nodus Reader from public-domain (CC0) and attribution (CC-BY) sources and checked one by one. The authors are credited here, with each licence, source and the changes made. The full provenance record, with each file’s checksums and processing, is published with the source code.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if tracks.isEmpty {
                    NodusEmptyState(icon: "music.note.list", title: "No sounds listed", message: "This build has no sound catalog.")
                }
                ForEach(tracks) { track in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                        Text("\(track.author) · \(track.source.provider)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                        HStack(spacing: 14) {
                            if let url = URL(string: track.license.url), !track.license.url.isEmpty {
                                Link(track.license.spdx, destination: url)
                            } else {
                                Text(track.license.spdx)
                            }
                            if let url = URL(string: track.source.pageURL), !track.source.pageURL.isEmpty {
                                Link("Source", destination: url)
                            }
                        }
                        .font(.caption.weight(.medium))
                        .tint(palette.accent)
                        if !track.processing.transformations.isEmpty {
                            Text(track.processing.transformations.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelCard(radius: 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Credits and licences")
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }.nodusPlainBackground()
        }
    }
}
