// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum ImagePipeline {
    public static func jpegData(fromImageData data: Data, maxPixel: CGFloat = 1400, quality: CGFloat = 0.9) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(image, quality: quality)
    }

    public static func encodeJPEG(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @MainActor
    public static func jpegData(fromPDFAt url: URL, maxPixel: CGFloat = 1400) -> Data? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let target = CGSize(width: maxPixel, height: maxPixel * 1.5)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let thumbnail = page.thumbnail(of: target, for: .cropBox)
        guard let image = cgImage(from: thumbnail) else { return nil }
        return encodeJPEG(image, quality: 0.88)
    }

    @MainActor
    public static func cgImage(from platformImage: PlatformImage) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: platformImage.size)
        return platformImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return platformImage.cgImage
        #endif
    }
}

#if os(macOS)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif
