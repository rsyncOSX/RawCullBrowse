import Foundation
@testable import RawCullBrowse
import Testing

@Suite("RAW preview settings")
struct RAWPreviewSettingsTests {
    @Test func `existing settings default to eight bit`() throws {
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data("{}".utf8))
        #expect(settings.rawPreviewBitDepth == .eightBit)
    }

    @Test(arguments: RAWPreviewBitDepth.allCases)
    func `bit depth survives settings round trip`(bitDepth: RAWPreviewBitDepth) throws {
        var settings = BrowserSettings()
        settings.rawPreviewBitDepth = bitDepth
        let encoded = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(BrowserSettings.self, from: encoded)
        #expect(restored.rawPreviewBitDepth == bitDepth)
    }
}
