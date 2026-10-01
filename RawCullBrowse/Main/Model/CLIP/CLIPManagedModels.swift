import BackgroundAssets
import Foundation
import System
import Security

nonisolated enum CLIPManagedModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case dataComp = "data-comp"
    // case openAI = "openai"

    static let defaultSelection = Self.dataComp

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .dataComp: "DataComp"
        // case .openAI: "OpenAI"
        }
    }

    var downloadID: CLIPModelDownloadID {
        switch self {
        case .dataComp: .clipDataComp
        // case .openAI: .clipOpenAI
        }
    }
}


nonisolated enum RawCullBrowseAIModelDownloadSource: Equatable, Sendable {
    case appleHosted
    static let live: Self = .appleHosted
    var isConfigured: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }
}

nonisolated enum RawCullBrowseBackgroundAssetsRuntime {
    /// `AssetPackManager.shared` traps during validation on these macOS 27
    /// seeds even when the signed app and profile contain the configured group.
    static let affectedMacOS27Builds: Set<String> = [
        "26A5406e",
        "26A5421a"
    ]

    static var isUsable: Bool {
        isUsable(
            operatingSystemVersionString: ProcessInfo.processInfo
                .operatingSystemVersionString,
            isDevelopmentSigned: isDevelopmentSigned,
        )
    }

    static func isUsable(
        operatingSystemVersionString: String,
        isDevelopmentSigned: Bool = true,
    ) -> Bool {
        let isAffectedBuild = affectedMacOS27Builds.contains {
            operatingSystemVersionString.contains($0)
        }
        return !isAffectedBuild || !isDevelopmentSigned
    }

    private static var isDevelopmentSigned: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return true }
        return SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.get-task-allow" as CFString,
            nil,
        ) as? Bool == true
    }

    static let unavailableMessage =
        "AI model downloads are temporarily unavailable in development builds "
            + "on this macOS 27 beta because of a Background Assets validation "
            + "regression. A packaged distribution build is unaffected."
}

nonisolated enum CLIPModelDownloadState: Equatable, Sendable {
    case checking
    case unavailable(reason: LocalizedStringResource)
    case licenceRequired
    case notConfigured
    case ready
    case downloading(progress: Double)
    case validating
    case installed(location: URL)
    case removing
    case failed(message: String)

    var isInstalled: Bool {
        if case .installed = self {
            true
        } else {
            false
        }
    }

    var installedLocation: URL? {
        guard case let .installed(location) = self else { return nil }
        return location
    }

    var canStartDownload: Bool {
        switch self {
        case .ready, .failed: true
        case .unavailable, .licenceRequired, .checking, .notConfigured, .downloading, .validating, .installed, .removing: false
        }
    }
}

nonisolated struct CLIPModelDownloadsSnapshot: Equatable, Sendable {
    let states: [CLIPModelDownloadID: CLIPModelDownloadState]
    let managedModelLocations: [CLIPModelDownloadID: URL]
    let acceptedLicenceModelIDs: Set<CLIPModelDownloadID>
}

nonisolated enum CLIPModelDownloadError: Error, LocalizedError, Sendable {
    case serviceNotConfigured
    case backgroundAssetsUnavailable(String)
    case releaseBlocked(String)
    case assetPackNotFound(String)
    case downloadedModelNotFound(String)
    case licenceAcceptanceRequired(String)
    case missingVerifiedLicenceText(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:
            "The AI model download service has not been configured."

        case let .backgroundAssetsUnavailable(message):
            message

        case let .releaseBlocked(modelName):
            "\(modelName) is not approved for redistribution yet."

        case let .assetPackNotFound(assetPackID):
            "The model asset pack \(assetPackID) is not present in the download manifest."

        case let .downloadedModelNotFound(path):
            "The downloaded asset pack does not contain the expected model at \(path)."

        case let .licenceAcceptanceRequired(modelName):
            "Accept the verified licence for \(modelName) before downloading it."

        case let .missingVerifiedLicenceText(modelName):
            "A verified complete licence document has not been packaged for \(modelName)."
        }
    }
}

nonisolated protocol CLIPModelDownloadServicing: Sendable {
    func state(
        for descriptor: CLIPModelDownloadDescriptor,
    ) async -> CLIPModelDownloadState

    func download(
        _ descriptor: CLIPModelDownloadDescriptor,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> URL

    func remove(
        _ descriptor: CLIPModelDownloadDescriptor,
    ) async throws
}

/// Apple-hosted Managed Background Assets implementation.
/// The StoreKit downloader extension and Info.plist select Apple hosting.
actor ManagedBackgroundAssetsCLIPModelDownloadService:
    CLIPModelDownloadServicing {
    private let source: RawCullBrowseAIModelDownloadSource
    private let backgroundAssetsRuntimeIsUsable: Bool

    init(
        source: RawCullBrowseAIModelDownloadSource = .live,
        backgroundAssetsRuntimeIsUsable: Bool = RawCullBrowseBackgroundAssetsRuntime
            .isUsable,
    ) {
        self.source = source
        self.backgroundAssetsRuntimeIsUsable = backgroundAssetsRuntimeIsUsable
    }

    func state(
        for descriptor: CLIPModelDownloadDescriptor,
    ) async -> CLIPModelDownloadState {
        guard source.isConfigured else {
            return .notConfigured
        }
        guard backgroundAssetsRuntimeIsUsable else {
            return .failed(
                message: RawCullBrowseBackgroundAssetsRuntime.unavailableMessage,
            )
        }

        if AssetPackManager.shared.assetPackIsAvailableLocally(
            withID: descriptor.assetPackID,
        ) {
            do {
                return try .installed(location: modelURL(for: descriptor))
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }

        do {
            _ = try await assetPack(for: descriptor)
            return .ready
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func download(
        _ descriptor: CLIPModelDownloadDescriptor,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> URL {
        guard source.isConfigured else {
            throw CLIPModelDownloadError.serviceNotConfigured
        }
        guard backgroundAssetsRuntimeIsUsable else {
            throw CLIPModelDownloadError.backgroundAssetsUnavailable(
                RawCullBrowseBackgroundAssetsRuntime.unavailableMessage,
            )
        }
        try Task.checkCancellation()

        let assetPack = try await assetPack(for: descriptor)

        let updates = AssetPackManager.shared.statusUpdates(
            forAssetPackWithID: descriptor.assetPackID,
        )
        let progressTask = Task { @concurrent in
            for await update in updates {
                guard !Task.isCancelled else { return }
                if case let .downloading(_, downloadProgress) = update {
                    await progress(downloadProgress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        try await AssetPackManager.shared.ensureLocalAvailability(
            of: assetPack,
            requireLatestVersion: true,
        )
        try Task.checkCancellation()
        await progress(1)
        return try modelURL(for: descriptor)
    }

    private func assetPack(
        for descriptor: CLIPModelDownloadDescriptor,
    ) async throws -> AssetPack {
        let manifest = try await AssetPackManager.shared.manifest
        if let assetPack = manifest.assetPack(
            withID: descriptor.assetPackID,
        ) {
            return assetPack
        }

        throw CLIPModelDownloadError.assetPackNotFound(
            descriptor.assetPackID,
        )
    }

    func remove(
        _ descriptor: CLIPModelDownloadDescriptor,
    ) async throws {
        guard backgroundAssetsRuntimeIsUsable else {
            throw CLIPModelDownloadError.backgroundAssetsUnavailable(
                RawCullBrowseBackgroundAssetsRuntime.unavailableMessage,
            )
        }
        try Task.checkCancellation()
        try await AssetPackManager.shared.remove(
            assetPackWithID: descriptor.assetPackID,
        )
    }

    private nonisolated func modelURL(
        for descriptor: CLIPModelDownloadDescriptor,
    ) throws -> URL {
        let url = try AssetPackManager.shared.url(
            for: FilePath(descriptor.assetPackModelPath),
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory,
        ), isDirectory.boolValue else {
            throw CLIPModelDownloadError.downloadedModelNotFound(
                descriptor.assetPackModelPath,
            )
        }
        return url
    }
}

actor CLIPModelDownloadCoordinator {
    private let catalog: CLIPModelDownloadCatalog
    private let service: any CLIPModelDownloadServicing
    private let acceptanceStore: any RawCullBrowseAIModelLicenceAcceptanceStoring

    init(
        catalog: CLIPModelDownloadCatalog = .production,
        service: any CLIPModelDownloadServicing = ManagedBackgroundAssetsCLIPModelDownloadService(),
        acceptanceStore: any RawCullBrowseAIModelLicenceAcceptanceStoring = RawCullBrowseAIModelLicenceAcceptanceFileStore(
            fileURL: URL.applicationSupportDirectory.appending(path: "RawCullBrowse/model-licence-acceptances.json")
        ),
    ) {
        self.catalog = catalog
        self.service = service
        self.acceptanceStore = acceptanceStore
    }

    func snapshot() async -> CLIPModelDownloadsSnapshot {
        var states: [
            CLIPModelDownloadID: CLIPModelDownloadState
        ] = [:]
        var locations: [CLIPModelDownloadID: URL] = [:]
        var acceptedIDs: Set<CLIPModelDownloadID> = []

        for descriptor in catalog.models {
            if case let .blocked(reason) = descriptor.releaseReadiness {
                states[descriptor.id] = .unavailable(reason: reason)
                continue
            }

            let serviceState = await service.state(for: descriptor)
            if let location = serviceState.installedLocation {
                states[descriptor.id] = serviceState
                locations[descriptor.id] = location
                continue
            }

            if descriptor.licence.requiresExplicitAcceptance {
                do {
                    if try await acceptanceStore.acceptance(
                        for: descriptor,
                    ) != nil {
                        acceptedIDs.insert(descriptor.id)
                        states[descriptor.id] = serviceState
                    } else {
                        states[descriptor.id] = .licenceRequired
                    }
                } catch {
                    states[descriptor.id] = .failed(
                        message: error.localizedDescription,
                    )
                }
            } else {
                states[descriptor.id] = serviceState
            }
        }

        return CLIPModelDownloadsSnapshot(
            states: states,
            managedModelLocations: locations,
            acceptedLicenceModelIDs: acceptedIDs,
        )
    }

    func acceptLicence(
        for id: CLIPModelDownloadID,
        rawCullBrowseVersion: String,
    ) async throws {
        let descriptor = try requiredDescriptor(for: id)
        guard descriptor.releaseReadiness.isReady else {
            throw CLIPModelDownloadError.releaseBlocked(
                descriptor.displayName,
            )
        }
        guard descriptor.licence.textSHA256 != nil else {
            throw CLIPModelDownloadError.missingVerifiedLicenceText(
                descriptor.displayName,
            )
        }
        try await acceptanceStore.recordAcceptance(
            for: descriptor,
            rawCullBrowseVersion: rawCullBrowseVersion,
        )
    }

    func download(
        _ id: CLIPModelDownloadID,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> URL {
        let descriptor = try requiredDescriptor(for: id)
        guard descriptor.releaseReadiness.isReady else {
            throw CLIPModelDownloadError.releaseBlocked(
                descriptor.displayName,
            )
        }
        if descriptor.licence.requiresExplicitAcceptance {
            guard try await acceptanceStore.acceptance(
                for: descriptor,
            ) != nil else {
                throw CLIPModelDownloadError.licenceAcceptanceRequired(
                    descriptor.displayName,
                )
            }
        }
        return try await service.download(descriptor, progress: progress)
    }

    func remove(
        _ id: CLIPModelDownloadID,
    ) async throws {
        let descriptor = try requiredDescriptor(for: id)
        try await service.remove(descriptor)
    }

    private func requiredDescriptor(
        for id: CLIPModelDownloadID,
    ) throws -> CLIPModelDownloadDescriptor {
        guard let descriptor = catalog.descriptor(for: id) else {
            throw CLIPModelDownloadError.assetPackNotFound(id.rawValue)
        }
        return descriptor
    }
}
