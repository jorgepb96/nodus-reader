// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

@MainActor
final class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSURL, PlatformImage>()

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

struct StoredCoverImage: View {
    let url: URL?
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let cached = CoverImageCache.shared.image(for: url) {
            image = cached
            return
        }
        // Read and decode off the main thread; decoding dozens of JPEG covers
        // while a grid scrolls would otherwise stall the UI.
        let decoded = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            guard let data = try? Data(contentsOf: url),
                  let platform = PlatformImage(data: data) else { return nil }
            #if os(iOS)
            return platform.preparingForDisplay() ?? platform
            #else
            return platform
            #endif
        }.value
        guard !Task.isCancelled, let decoded else { return }
        CoverImageCache.shared.store(decoded, for: url)
        image = decoded
    }
}

/// A real stored cover when available, otherwise the generated typographic cover.
struct BookCoverView: View {
    /// Optional on purpose: AppKit `Table` cells can be laid out re-entrantly
    /// before the scene's environment objects reach them, and a required
    /// `@Environment` lookup then aborts the app. The shared store is the same
    /// one `LibraryService` uses in the app.
    @Environment(LibraryService.self) private var library: LibraryService?
    @Environment(\.nodusPalette) private var palette

    let book: Book
    var selected: Bool = false
    var showBadges: Bool = true

    private var coverURL: URL? {
        guard let url = (library?.fileStore ?? .shared).coverURL(for: book.coverFileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var fallback: CoverPalette.Pair {
        CoverPalette.pair(for: book.title + book.author)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                // The typographic cover is always present underneath, so a
                // cover that is still loading (or failed to decode) never
                // leaves a blank cell in the library, player or inspector.
                CoverArtwork(
                    author: book.displayAuthor,
                    title: book.title,
                    background: fallback.background,
                    foreground: fallback.foreground
                )
                if let coverURL {
                    StoredCoverImage(url: coverURL)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(CoverShape())
            .overlay(
                CoverShape().stroke(selected ? palette.accent : Color.black.opacity(0.08),
                                    lineWidth: selected ? 3 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if showBadges, book.format == .pdf {
                    Text("PDF")
                        .font(.system(size: max(7, width * 0.045), weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(NodusColors.coverBadgeText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(NodusColors.coverBadgeFill,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .padding(max(5, width * 0.05))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showBadges, book.downloadState == .cloudOnly {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: max(9, width * 0.06), weight: .medium))
                        .foregroundStyle(NodusColors.coverBadgeText)
                        .frame(width: max(20, width * 0.16), height: max(20, width * 0.16))
                        .background(NodusColors.coverBadgeFill, in: Circle())
                        .padding(max(5, width * 0.05))
                } else if showBadges, book.downloadState == .downloading {
                    // iCloud does not report byte progress for this copy, so the
                    // badge is an indeterminate spinner rather than a fake bar.
                    ProgressView()
                        .controlSize(.small)
                        .tint(NodusColors.coverBadgeText)
                        .frame(width: max(20, width * 0.16), height: max(20, width * 0.16))
                        .background(NodusColors.coverBadgeFill, in: Circle())
                        .padding(max(5, width * 0.05))
                }
            }
            .shadow(color: .black.opacity(0.42), radius: max(6, width * 0.08), x: 0, y: max(5, width * 0.06))
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = ["\(book.title), by \(book.displayAuthor)"]
        if showBadges, book.format == .pdf { parts.append("PDF") }
        if showBadges, book.downloadState == .cloudOnly { parts.append(String(localized: "in iCloud, not downloaded")) }
        if showBadges, book.downloadState == .downloading { parts.append(String(localized: "downloading")) }
        return parts.joined(separator: ", ")
    }
}

struct BookProgressLine: View {
    @Environment(\.nodusPalette) private var palette
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.text.opacity(palette.isDark ? 0.08 : 0.12))
                Capsule().fill(palette.accent)
                    .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

struct BookMetaLine: View {
    @Environment(\.nodusPalette) private var palette
    let book: Book

    var body: some View {
        Text(meta)
            .font(.caption)
            .foregroundStyle(palette.muted)
            .lineLimit(1)
    }

    private var meta: String {
        switch book.status {
        case .finished:
            return "\(book.format.badge) · Finished"
        case .toRead:
            return "\(book.format.badge) · To read"
        case .inProgress:
            return "\(book.format.badge) · \(Int((book.progress * 100).rounded()))%"
        }
    }
}

struct ImportToast: View {
    @Environment(\.nodusPalette) private var palette
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.panelRaised, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
        .shadow(color: palette.shadow, radius: 18, y: 8)
        .padding(.top, 8)
    }
}
