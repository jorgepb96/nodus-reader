import CoreGraphics
import Foundation
import ImageIO

/// The avatar a pack carries: one square PNG at `GVoice.avatarMember`.
///
/// Lives in the format target, not in either app, so a photo picked on the
/// phone and one dropped on the Mac come out as the same asset -- the
/// format doc fixes the size, and an implementation that rolled its own
/// would be re-deciding it. ImageIO and CoreGraphics only: no UIKit, no
/// AppKit, so this builds for every platform the package does.
public enum AvatarImage {
    /// Edge length in pixels of a conforming avatar. Writers MUST emit this.
    public static let side = 256

    /// Byte ceiling on an avatar member read from an untrusted pack. A
    /// conforming 256×256 PNG is a few tens of KB; this leaves room for a
    /// generous writer without letting a hostile one hand us a bomb.
    public static let maxBytes = 4 * 1024 * 1024

    /// Longest edge ImageIO is asked to decode to. Bounds memory on a huge
    /// photo before the crop; the short edge only has to reach `side`.
    static let maxDecodePixels = 4096

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Any image ImageIO can read (PNG, JPEG, HEIC, …) → the conforming
    /// avatar: EXIF orientation applied, centre-cropped to a square on the
    /// short edge, resampled to `side`×`side`, PNG-encoded. Nil when the
    /// bytes are not an image at all.
    public static func png(from data: Data, side: Int = AvatarImage.side) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        // Decode no larger than needed: the short edge must reach `side`, so
        // the long edge is `side` × aspect. Bounded, because a panorama's
        // aspect would otherwise ask for the whole thing.
        var maxPixel = maxDecodePixels
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           w > 0, h > 0 {
            let wanted = Int((Double(side) * max(w, h) / min(w, h)).rounded(.up))
            maxPixel = min(max(wanted, side), maxDecodePixels)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let short = min(decoded.width, decoded.height)
        guard short > 0 else { return nil }
        let crop = CGRect(x: (decoded.width - short) / 2, y: (decoded.height - short) / 2,
                          width: short, height: short)
        guard let square = decoded.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }

        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return encoded as Data
    }

    /// Whether `data` starts with the PNG signature. The check import makes
    /// before storing an avatar: cheap, and enough to keep a pack from
    /// planting a non-image under `avatar.png`.
    public static func isPNG(_ data: Data) -> Bool {
        data.count >= pngSignature.count && data.prefix(pngSignature.count).elementsEqual(pngSignature)
    }

    /// Whether `data` starts with the JPEG signature (SOI marker).
    public static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    /// Pixel dimensions of an encoded image, without decoding its pixels.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return (w, h)
    }
}
