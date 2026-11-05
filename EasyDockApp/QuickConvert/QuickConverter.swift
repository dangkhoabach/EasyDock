import AVFoundation
import EasyDockCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The conversions themselves, off the main thread. Every result is a new
/// file next to the original; nothing is ever written over.
enum QuickConverter {
    enum Kind { case image, video }

    struct ImageOptions: Sendable {
        var format: ImageFormat
        var maxDimension: Int
        var quality: Int
        var keepMetadata: Bool
    }

    enum Failure: LocalizedError {
        case unreadable, unwritable, unsupportedInMP4, cancelled

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Couldn't read this file.", bundle: AppLocale.bundle)
            case .unwritable: String(localized: "Couldn't write next to it. Is the folder read-only?", bundle: AppLocale.bundle)
            case .unsupportedInMP4: String(localized: "This video's format doesn't fit in MP4 as it is. Choose H.264 or HEVC.", bundle: AppLocale.bundle)
            case .cancelled: String(localized: "Stopped.", bundle: AppLocale.bundle)
            }
        }
    }

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        return nil
    }

    // MARK: - Pictures

    /// The picture is decoded through ImageIO's thumbnail path, which scales
    /// while decoding (fast, little memory) and turns it upright, so the
    /// written file needs no orientation.
    static func convert(image source: URL, options: ImageOptions) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadable }
        let longest = QuickConvert.longestSide(width: width, height: height, limit: options.maxDimension)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else { throw Failure.unreadable }
        // JPEG has no transparency: what was see-through goes on white, not black.
        if options.format == .jpeg, let flattened = onWhite(image) { image = flattened }

        let output = URL(fileURLWithPath: QuickConvert.outputPath(for: source.path, fileExtension: options.format.fileExtension,
                                                                  exists: FileManager.default.fileExists(atPath:)))
        if options.format == .webp {
            guard let data = WebPEncoder.encode(image, quality: options.quality) else { throw Failure.unreadable }
            do { try data.write(to: output, options: .withoutOverwriting) } catch { throw Failure.unwritable }
            return output
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, options.format.typeIdentifier as CFString, 1, nil) else {
            throw Failure.unwritable
        }
        var written: [CFString: Any] = [:]
        if options.keepMetadata {
            // Everything but what no longer holds: the size changed and the
            // picture is already upright.
            written = properties
            for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] { written[key] = nil }
            if var tiff = written[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = nil
                written[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        if options.format.usesQuality {
            written[kCGImageDestinationLossyCompressionQuality] = Double(options.quality) / 100
        }
        CGImageDestinationAddImage(destination, image, written as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.unwritable
        }
        return output
    }

    private static func onWhite(_ image: CGImage) -> CGImage? {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    // MARK: - Videos

    /// Reports progress from 0 to 1 while it runs; cancelling the task stops
    /// the export and removes the half-written file.
    static func convert(video source: URL, preset: VideoPreset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let presetName: String
        let fileType: AVFileType
        switch preset {
        case .mp4Copy: (presetName, fileType) = (AVAssetExportPresetPassthrough, .mp4)
        case .h264_1080p: (presetName, fileType) = (AVAssetExportPreset1920x1080, .mp4)
        case .hevc_1080p: (presetName, fileType) = (AVAssetExportPresetHEVC1920x1080, .mp4)
        case .h264_720p: (presetName, fileType) = (AVAssetExportPreset1280x720, .mp4)
        case .audioM4A: (presetName, fileType) = (AVAssetExportPresetAppleM4A, .m4a)
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: presetName, with: asset, outputFileType: fileType) else {
            throw preset == .mp4Copy ? Failure.unsupportedInMP4 : Failure.unreadable
        }
        guard let created = AVAssetExportSession(asset: asset, presetName: presetName) else { throw Failure.unreadable }
        // The session isn't Sendable; it is only touched here and by its own callback.
        nonisolated(unsafe) let session = created
        let output = URL(fileURLWithPath: QuickConvert.outputPath(for: source.path, fileExtension: preset.fileExtension,
                                                                  exists: FileManager.default.fileExists(atPath:)))
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let watcher = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed: continuation.resume()
                        case .cancelled: continuation.resume(throwing: Failure.cancelled)
                        default: continuation.resume(throwing: session.error ?? Failure.unwritable)
                        }
                    }
                }
            } onCancel: {
                session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return output
    }
}
