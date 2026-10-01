import Foundation
@testable import RawCullBrowse
import Testing

@Suite("RAW 9 sidecars")
struct RAW9SidecarStoreTests {
    private func temporaryRAW() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("photo.ARW")
    }

    @Test func savesRestoresAndResetsWithoutChangingOriginal() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let original = Data("original raw bytes".utf8)
        try original.write(to: raw)
        let store = RAW9SidecarStore()
        #expect(try await store.load(for: raw) == nil)
        let adjustments = RAW9Adjustments(exposure: 1.2, noiseReduction: -0.3, sharpness: 0.4, contrast: 0.2)
        try await store.save(adjustments, for: raw)
        #expect(try await store.load(for: raw) == adjustments)
        #expect(RAW9SidecarStore.sidecarURL(for: raw).lastPathComponent == "photo.ARW.rawcull-raw9.json")
        try await store.save(RAW9Adjustments(), for: raw)
        #expect(try await store.load(for: raw) == RAW9Adjustments())
        #expect(try Data(contentsOf: raw) == original)
    }

    @Test(arguments: [
        "not JSON",
        #"{"version":2,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0}}"#,
        #"{"version":1,"adjustments":{"exposure":10,"noiseReduction":0,"sharpness":0,"contrast":0}}"#,
    ])
    func rejectsInvalidSidecars(contents: String) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        try Data(contents.utf8).write(to: RAW9SidecarStore.sidecarURL(for: raw))
        let store = RAW9SidecarStore()
        await #expect(throws: (any Error).self) { try await store.load(for: raw) }
    }
}
