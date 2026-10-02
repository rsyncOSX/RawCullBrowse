import CoreImage
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

    @Test func `saves restores and resets without changing original`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let original = Data("original raw bytes".utf8)
        try original.write(to: raw)
        let store = RAW9SidecarStore()
        #expect(try await store.load(for: raw) == nil)
        let adjustments = RAW9Adjustments(exposure: 1.2, noiseReduction: -0.3, sharpness: 0.4, contrast: 0.2, temperature: 5200, tint: -12)
        try await store.save(adjustments, for: raw)
        #expect(try await store.load(for: raw) == adjustments)
        #expect(RAW9SidecarStore.sidecarURL(for: raw).lastPathComponent == "photo.ARW.rawcull-raw9.json")
        try await store.save(RAW9Adjustments(), for: raw)
        #expect(try await store.load(for: raw) == RAW9Adjustments())
        #expect(try Data(contentsOf: raw) == original)
    }

    @Test func `picker maps displayed coordinates into unrotated RAW pixels`() {
        let extent = CGRect(x: 0, y: 0, width: 400, height: 300)
        let landscape = RAW9Support.neutralLocation(normalizedPoint: CGPoint(x: 0.25, y: 0.75), extent: extent, orientation: .up)
        #expect(abs(landscape.x - 99.75) < 0.01)
        #expect(abs(landscape.y - 74.75) < 0.01)
        let portrait = RAW9Support.neutralLocation(normalizedPoint: CGPoint(x: 0.25, y: 0.75), extent: extent, orientation: .right)
        #expect(abs(portrait.x - 300.25) < 0.01)
        #expect(abs(portrait.y - 74.75) < 0.01)
    }

    @Test func `loads legacy sidecars with camera white balance`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let contents = #"{"version":1,"adjustments":{"exposure":1,"noiseReduction":0,"sharpness":0,"contrast":0}}"#
        try Data(contents.utf8).write(to: RAW9SidecarStore.sidecarURL(for: raw))
        let store = RAW9SidecarStore()
        let adjustments = try #require(try await store.load(for: raw))
        #expect(adjustments.exposure == 1)
        #expect(adjustments.temperature == nil)
        #expect(adjustments.tint == nil)
    }

    @Test(arguments: [
        #"{"version":1,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0,"temperature":1000}}"#,
        #"{"version":1,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0,"tint":151}}"#,
        "not JSON",
        #"{"version":2,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0}}"#,
        #"{"version":1,"adjustments":{"exposure":10,"noiseReduction":0,"sharpness":0,"contrast":0}}"#
    ])
    func `rejects invalid sidecars`(contents: String) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        try Data(contents.utf8).write(to: RAW9SidecarStore.sidecarURL(for: raw))
        let store = RAW9SidecarStore()
        await #expect(throws: (any Error).self) { try await store.load(for: raw) }
    }
}
