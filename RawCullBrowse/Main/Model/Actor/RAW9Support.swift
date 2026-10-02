import CoreImage
import Foundation
import RawParserKit

/// Checks the installed decoder's capabilities without rendering sensor data.
nonisolated enum RAW9Support {
    static func preferredVersion(in versions: [CIRAWDecoderVersion]) -> CIRAWDecoderVersion? {
        if versions.contains(.version9) {
            return .version9
        }
        if versions.contains(.version9DNG) {
            return .version9DNG
        }
        return nil
    }

    /// Map a displayed top-left point into the RAW filter's unrotated coordinates.
    static func neutralLocation(normalizedPoint: CGPoint, extent: CGRect, orientation: CGImagePropertyOrientation) -> CGPoint {
        let image = CIImage.empty().cropped(to: extent)
        let transform = image.orientationTransform(forExifOrientation: Int32(orientation.rawValue))
        let displayedExtent = extent.applying(transform)
        let displayedPoint = CGPoint(
            x: displayedExtent.minX + normalizedPoint.x * max(0, displayedExtent.width - 1),
            y: displayedExtent.minY + (1 - normalizedPoint.y) * max(0, displayedExtent.height - 1)
        )
        let point = displayedPoint.applying(transform.inverted())
        return CGPoint(x: min(extent.maxX - 1, max(extent.minX, point.x)),
                       y: min(extent.maxY - 1, max(extent.minY, point.y)))
    }

    @concurrent
    static func isSupported(for url: URL) async -> Bool {
        guard !Task.isCancelled, !SupportedFileType.isRenderedImage(url) else { return false }
        return autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url) else { return false }
            return preferredVersion(in: filter.supportedDecoderVersions) != nil
        }
    }
}

/// Preview-only adjustments; zero offsets and nil white balance preserve camera defaults.
nonisolated struct RAW9Adjustments: Equatable, Sendable, Codable {
    var exposure: Double = 0
    var noiseReduction: Double = 0
    var sharpness: Double = 0
    var contrast: Double = 0
    var temperature: Double?
    var tint: Double?
}

/// Keeps the filter and its intermediate render cache off the main actor.
actor RAW9PreviewRenderer {
    private var sourceURL: URL?
    private var filter: CIRAWFilter?
    private lazy var context = CIContext(options: [.cacheIntermediates: true])
    private var defaultTemperature: Float = 6500
    private var defaultTint: Float = 0
    private var defaults: (noise: Float, sharpness: Float, contrast: Float) = (0, 0, 0)

    /// Uses a separate filter so sampling cannot change the preview's cached defaults.
    func whiteBalance(url: URL, normalizedPoint: CGPoint? = nil) throws -> (temperature: Double, tint: Double) {
        try Task.checkCancellation()
        guard let sample = CIRAWFilter(imageURL: url),
              let version = RAW9Support.preferredVersion(in: sample.supportedDecoderVersions)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        sample.decoderVersion = version
        if let point = normalizedPoint {
            let orientation = sample.orientation
            sample.orientation = .up
            guard let extent = sample.outputImage?.extent else { throw CocoaError(.fileReadUnknown) }
            sample.neutralLocation = RAW9Support.neutralLocation(
                normalizedPoint: point, extent: extent, orientation: orientation
            )
        }
        let temperature = Double(sample.neutralTemperature)
        let tint = Double(sample.neutralTint)
        guard temperature.isFinite, tint.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        return (min(50000, max(2000, temperature)), min(150, max(-150, tint)))
    }

    func render(url: URL, adjustments: RAW9Adjustments, bitDepth: RAWPreviewBitDepth = .eightBit) throws -> CGImage {
        try Task.checkCancellation()
        if sourceURL != url {
            filter = nil
            sourceURL = nil
            guard let loaded = CIRAWFilter(imageURL: url),
                  let version = RAW9Support.preferredVersion(in: loaded.supportedDecoderVersions)
            else { throw CocoaError(.fileReadUnsupportedScheme) }
            loaded.decoderVersion = version
            defaults = (loaded.luminanceNoiseReductionAmount, loaded.sharpnessAmount, loaded.contrastAmount)
            defaultTemperature = loaded.neutralTemperature
            defaultTint = loaded.neutralTint
            filter = loaded
            sourceURL = url
        }
        guard let filter else { throw CocoaError(.fileReadUnknown) }
        filter.neutralTemperature = adjustments.temperature.map(Float.init) ?? defaultTemperature
        filter.neutralTint = adjustments.tint.map(Float.init) ?? defaultTint
        filter.exposure = Float(adjustments.exposure)
        filter.luminanceNoiseReductionAmount = min(1, max(0, defaults.noise + Float(adjustments.noiseReduction)))
        filter.sharpnessAmount = min(1, max(0, defaults.sharpness + Float(adjustments.sharpness)))
        filter.contrastAmount = min(1, max(0, defaults.contrast + Float(adjustments.contrast)))
        // Finish the expensive RAW render on this actor. A deferred CGImage can
        // perform that work when SwiftUI draws it, blocking the main thread.
        guard let output = filter.outputImage,
              let image = context.createCGImage(
                  output, from: output.extent, format: bitDepth == .eightBit ? .RGBA8 : .RGBAh,
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                  deferred: false,
              )
        else { throw CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        return image
    }
}

/// An app-specific sidecar, separate from XMP used by other photo editors.
actor RAW9SidecarStore {
    private struct Document: Codable {
        var version: Int = 1
        var adjustments: RAW9Adjustments
    }

    nonisolated static func sidecarURL(for rawURL: URL) -> URL {
        rawURL.appendingPathExtension("rawcull-raw9.json")
    }

    func load(for rawURL: URL) throws -> RAW9Adjustments? {
        let url = Self.sidecarURL(for: rawURL)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, Self.isValid(document.adjustments) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document.adjustments
    }

    func save(_ adjustments: RAW9Adjustments, for rawURL: URL) throws {
        guard Self.isValid(adjustments) else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(adjustments: adjustments))
        try data.write(to: Self.sidecarURL(for: rawURL), options: .atomic)
    }

    private nonisolated static func isValid(_ value: RAW9Adjustments) -> Bool {
        (value.temperature.map { $0.isFinite && (2000 ... 50000).contains($0) } ?? true)
            && (value.tint.map { $0.isFinite && (-150 ... 150).contains($0) } ?? true)
            && value.exposure.isFinite && (-3 ... 3).contains(value.exposure)
            && value.noiseReduction.isFinite && (-1 ... 1).contains(value.noiseReduction)
            && value.sharpness.isFinite && (-1 ... 1).contains(value.sharpness)
            && value.contrast.isFinite && (-1 ... 1).contains(value.contrast)
    }
}
