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
nonisolated struct RAW9Adjustments: Equatable, Sendable, Codable {
    var exposure: Double = 0
    var noiseReduction: Double = 0
    var sharpness: Double = 0
    var contrast: Double = 0
}

/// Keeps the filter and its intermediate render cache off the main actor.
actor RAW9PreviewRenderer {
    private var sourceURL: URL?
    private var filter: CIRAWFilter?
    private lazy var context = CIContext(options: [.cacheIntermediates: true])
    private var defaults: (noise: Float, sharpness: Float, contrast: Float) = (0, 0, 0)

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
            filter = loaded
            sourceURL = url
        }
        guard let filter else { throw CocoaError(.fileReadUnknown) }
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
        value.exposure.isFinite && (-3 ... 3).contains(value.exposure)
            && value.noiseReduction.isFinite && (-1 ... 1).contains(value.noiseReduction)
            && value.sharpness.isFinite && (-1 ... 1).contains(value.sharpness)
            && value.contrast.isFinite && (-1 ... 1).contains(value.contrast)
    }
}
