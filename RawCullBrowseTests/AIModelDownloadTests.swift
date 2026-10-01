import Foundation
@testable import RawCullBrowse
import Testing

struct AIModelDownloadTests {
    @Test(arguments: CLIPModelDownloadCatalog.production.models)
    func bundledLicenceMatchesVerifiedHash(_ descriptor: CLIPModelDownloadDescriptor) {
        #expect(descriptor.licence.verifiedBundledText(in: .main) != nil)
    }

    @Test
    func samDownloadRequiresRecordedLicenceAcceptance() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RawCullBrowseAIModelLicenceAcceptanceFileStore(
            fileURL: directory.appending(path: "acceptances.json")
        )
        let coordinator = CLIPModelDownloadCoordinator(
            service: ReadyModelDownloadService(), acceptanceStore: store
        )
        let before = await coordinator.snapshot()
        #expect(before.states[.sam3] == .licenceRequired)
        await #expect(throws: CLIPModelDownloadError.self) {
            try await coordinator.download(.sam3) { _ in }
        }
        try await coordinator.acceptLicence(for: .sam3, rawCullBrowseVersion: "test")
        let after = await coordinator.snapshot()
        #expect(after.states[.sam3] == .ready)
        let descriptor = try #require(CLIPModelDownloadCatalog.production.descriptor(for: .sam3))
        let persisted = RawCullBrowseAIModelLicenceAcceptanceFileStore(
            fileURL: directory.appending(path: "acceptances.json")
        )
        let acceptance = try await persisted.acceptance(for: descriptor)
        #expect(acceptance?.matches(descriptor: descriptor) == true)
    }
}

private actor ReadyModelDownloadService: CLIPModelDownloadServicing {
    func state(for descriptor: CLIPModelDownloadDescriptor) -> CLIPModelDownloadState { .ready }
    func download(
        _ descriptor: CLIPModelDownloadDescriptor,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) -> URL { URL(filePath: "/tmp/model") }
    func remove(_ descriptor: CLIPModelDownloadDescriptor) {}
}
