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

    @concurrent
    static func isSupported(for url: URL) async -> Bool {
        guard !Task.isCancelled, !SupportedFileType.isRenderedImage(url) else { return false }
        return autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url) else { return false }
            return preferredVersion(in: filter.supportedDecoderVersions) != nil
        }
    }
}

/// Preview-only adjustments; zero preserves the camera's calibrated defaults.
nonisolated struct RAW9Adjustments: Equatable, Sendable {
    var exposure: Double = 0
    var noiseReduction: Double = 0
    var sharpness: Double = 0
    var contrast: Double = 0
}

/// Keeps the filter and its intermediate render cache off the main actor.
actor RAW9PreviewRenderer {
    private var sourceURL: URL?
    private var filter: CIRAWFilter?
    private let context = CIContext(options: [.cacheIntermediates: true])
    private var defaults: (noise: Float, sharpness: Float, contrast: Float) = (0, 0, 0)

    func render(url: URL, adjustments: RAW9Adjustments) throws -> CGImage {
        try Task.checkCancellation()
        if sourceURL != url {
            filter = nil
            sourceURL = nil
            guard let loaded = CIRAWFilter(imageURL: url),
                  let version = RAW9Support.preferredVersion(in: loaded.supportedDecoderVersions)
            else { throw CocoaError(.fileReadUnsupportedScheme) }
            loaded.decoderVersion = version
            defaults = (loaded.luminanceNoiseReductionAmount, loaded.sharpnessAmount, loaded.contrastAmount)
            filter = loaded
            sourceURL = url
        }
        guard let filter else { throw CocoaError(.fileReadUnknown) }
        filter.exposure = Float(adjustments.exposure)
        filter.luminanceNoiseReductionAmount = min(1, max(0, defaults.noise + Float(adjustments.noiseReduction)))
        filter.sharpnessAmount = min(1, max(0, defaults.sharpness + Float(adjustments.sharpness)))
        filter.contrastAmount = min(1, max(0, defaults.contrast + Float(adjustments.contrast)))
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent)
        else { throw CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        return image
    }
}
