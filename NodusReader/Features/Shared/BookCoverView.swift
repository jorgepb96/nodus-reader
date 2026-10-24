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
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let platform = PlatformImage(data: data) else { return }
        CoverImageCache.shared.store(platform, for: url)
        image = platform
    }
}

/// A real stored cover when available, otherwise the generated typographic cover.
struct BookCoverView: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.nodusPalette) private var palette

    let book: Book
    var selected: Bool = false
    var showBadges: Bool = true

    private var coverURL: URL? {
        guard let url = library.fileStore.coverURL(for: book.coverFileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var fallback: CoverPalette.Pair {
        CoverPalette.pair(for: book.title + book.author)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Group {
                if let coverURL {
                    StoredCoverImage(url: coverURL)
                } else {
                    CoverArtwork(
                        author: book.displayAuthor,
                        title: book.title,
                        background: fallback.background,
                        foreground: fallback.foreground
                    )
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
                        .foregroundStyle(Color(hex: 0xF2EFE8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0x0E0D14, opacity: 0.82),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .padding(max(5, width * 0.05))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showBadges, book.downloadState == .cloudOnly {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: max(9, width * 0.06), weight: .medium))
                        .foregroundStyle(Color(hex: 0xF2EFE8))
                        .frame(width: max(20, width * 0.16), height: max(20, width * 0.16))
                        .background(Color(hex: 0x0E0D14, opacity: 0.82), in: Circle())
                        .padding(max(5, width * 0.05))
                }
            }
            .shadow(color: .black.opacity(0.42), radius: max(6, width * 0.08), x: 0, y: max(5, width * 0.06))
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), by \(book.displayAuthor)")
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
            Text(message).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.panelRaised, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
        .shadow(color: palette.shadow, radius: 18, y: 8)
        .padding(.top, 8)
    }
}
