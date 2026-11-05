import Accelerate
import CoreGraphics
import Foundation
import libwebp

/// The picture formats Quick Convert writes.
public enum ImageFormat: String, Sendable, CaseIterable {
    case webp, avif, heic, jpeg, png

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    /// For ImageIO; WebP goes through libwebp instead.
    public var typeIdentifier: String {
        switch self {
        case .webp: "org.webmproject.webp"
        case .avif: "public.avif"
        case .heic: "public.heic"
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        }
    }

    /// PNG is always lossless; the others take a quality.
    public var usesQuality: Bool { self != .png }
}

/// What a video becomes. Each maps to an `AVAssetExportSession` preset.
public enum VideoPreset: String, Sendable, CaseIterable {
    /// MP4 with the same streams, nothing encoded again: fast and lossless,
    /// but only for codecs MP4 can hold.
    case mp4Copy
    case h264_1080p
    case hevc_1080p
    case h264_720p
    /// The sound alone.
    case audioM4A

    public var fileExtension: String { self == .audioM4A ? "m4a" : "mp4" }
}

public enum QuickConvert {
    /// Longest side in pixels; 0 keeps the picture's size.
    public static let sizeChoices = [0, 3840, 2560, 1920, 1280, 800]

    /// The longest side to ask ImageIO for: the limit, never more than the
    /// picture already has.
    public static func longestSide(width: Int, height: Int, limit: Int) -> Int {
        let longest = max(width, height)
        return limit > 0 ? min(limit, longest) : longest
    }

    /// Next to the original with the new extension, never over an existing
    /// file: "Photo.webp", then "Photo 2.webp", "Photo 3.webp"…
    public static func outputPath(for source: String, fileExtension: String, exists: (String) -> Bool) -> String {
        let base = (source as NSString).deletingPathExtension
        var candidate = base + "." + fileExtension
        var number = 2
        while exists(candidate) {
            candidate = "\(base) \(number).\(fileExtension)"
            number += 1
        }
        return candidate
    }
}

/// WebP through libwebp, since ImageIO only reads it.
public enum WebPEncoder {
    /// `quality` 0…100 gives a lossy file; nil a lossless one. The picture
    /// is drawn into sRGB, the color space of the web.
    public static func encode(_ image: CGImage, quality: Int?) -> Data? {
        let width = image.width, height = image.height, bytesPerRow = width * 4
        guard width > 0, height > 0, let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // CGContext only draws premultiplied alpha; WebP stores it straight,
            // or soft edges come out darker.
            var vImage = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
            return vImageUnpremultiplyData_RGBA8888(&vImage, &vImage, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard drawn else { return nil }
        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer in
            if let quality {
                WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), Float(quality), &output)
            } else {
                WebPEncodeLosslessRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), &output)
            }
        }
        guard size > 0, let output else { return nil }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }
}
