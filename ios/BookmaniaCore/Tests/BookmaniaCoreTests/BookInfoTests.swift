import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct BookInfoTests {
    @Test func metadataAndCoversOfTheThreeFormats() throws {
        for name in ["zh-vertical.epub", "zh-vertical.azw3", "zh-vertical-joint.mobi"] {
            let info = try BookInfoReader.read(Fixtures.url(name))
            #expect(info.metadata.title == "直排測試書", "\(name)")
            #expect(info.metadata.authors == ["Bookmania 測試"], "\(name)")
            let cover = try #require(info.cover, "\(name)")
            #expect(cover.count > 100, "\(name)")
            // PNG or JPEG signature
            #expect(cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) || cover.starts(with: [0xFF, 0xD8]), "\(name)")
        }
        let mobi6 = try BookInfoReader.read(Fixtures.url("zh-horizontal-mobi6.mobi"))
        #expect(mobi6.metadata.title == "橫排測試書")
    }

    @Test func protectedAndDamagedFilesThrow() {
        #expect(bookError { _ = try BookInfoReader.read(Fixtures.url("drm-adept.epub")) }?.drmScheme == "Adobe ADEPT")
        #expect(bookError { _ = try BookInfoReader.read(Fixtures.url("drm-flagged.mobi")) }?.drmScheme != nil)
        #expect(bookError { _ = try BookInfoReader.read(Fixtures.url("corrupt-truncated.epub")) }?.isCorrupt == true)
    }
}
