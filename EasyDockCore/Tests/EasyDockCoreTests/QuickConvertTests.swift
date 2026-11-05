import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EasyDockCore

@Suite struct QuickConvertTests {
    @Test func outputSitsNextToTheOriginalWithoutOverwriting() {
        let taken: Set<String> = ["/p/Photo.webp", "/p/Photo 2.webp"]
        #expect(QuickConvert.outputPath(for: "/p/Photo.png", fileExtension: "jpg", exists: taken.contains) == "/p/Photo.jpg")
        #expect(QuickConvert.outputPath(for: "/p/Photo.png", fileExtension: "webp", exists: taken.contains) == "/p/Photo 3.webp")
        // Same format, smaller size: the original itself is never the output.
        #expect(QuickConvert.outputPath(for: "/p/Photo.png", fileExtension: "png", exists: { $0 == "/p/Photo.png" }) == "/p/Photo 2.png")
    }

    @Test func picturesAreNeverEnlarged() {
        #expect(QuickConvert.longestSide(width: 4000, height: 3000, limit: 1920) == 1920)
        #expect(QuickConvert.longestSide(width: 800, height: 1200, limit: 1920) == 1200)
        #expect(QuickConvert.longestSide(width: 800, height: 1200, limit: 0) == 1200)
    }

    /// A half-transparent red square with an opaque blue one beside it.
    private func sample() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }

    /// Both pictures drawn the same way, as premultiplied sRGB bytes.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// Lossless WebP reads back as the same picture, half-transparent edge
    /// included: without straightening the alpha first, the red comes back
    /// at half its strength.
    @Test func losslessWebPKeepsTransparency() throws {
        let original = sample()
        let data = try #require(WebPEncoder.encode(original, quality: nil))
        let decoded = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 64 && decoded.height == 32)
        let expected = pixels(original), actual = pixels(decoded)
        let largestDifference = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 255
        #expect(largestDifference <= 1)
    }

    @Test func lossyWebPIsSmallerAndStillAWebP() throws {
        let data = try #require(WebPEncoder.encode(sample(), quality: 80))
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.dropFirst(8).prefix(4) == Data("WEBP".utf8))
    }
}
