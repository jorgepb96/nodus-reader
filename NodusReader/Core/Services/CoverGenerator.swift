// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Produces the persisted cover JPEG for a newly imported document:
/// embedded EPUB artwork, a PDF first-page thumbnail, or the typographic cover
/// language from design/.
@MainActor
public enum CoverGenerator {
    public static func coverData(extraction: DocumentExtraction,
                                 documentURL: URL,
                                 format: BookFormat,
                                 title: String,
                                 author: String) -> Data? {
        if let embedded = extraction.coverData,
           let jpeg = ImagePipeline.jpegData(fromImageData: embedded) {
            return jpeg
        }
        if format == .pdf, let jpeg = ImagePipeline.jpegData(fromPDFAt: documentURL) {
            return jpeg
        }
        return typographicCover(title: title, author: author)
    }

    public static func typographicCover(title: String, author: String,
                                        size: CGSize = CGSize(width: 600, height: 900)) -> Data? {
        let palette = CoverPalette.pair(for: title + author)
        let view = CoverArtwork(
            author: author.isEmpty ? "Nodus Reader" : author,
            title: title,
            background: palette.background,
            foreground: palette.foreground
        )
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        #if os(macOS)
        guard let image = renderer.nsImage, let cgImage = ImagePipeline.cgImage(from: image) else { return nil }
        #else
        guard let image = renderer.uiImage, let cgImage = image.cgImage else { return nil }
        #endif
        return ImagePipeline.encodeJPEG(cgImage, quality: 0.9)
    }
}
