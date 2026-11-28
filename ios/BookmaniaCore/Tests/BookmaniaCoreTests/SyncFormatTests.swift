import Foundation
import Testing
@testable import BookmaniaCore

/// The example files of sync-format.md (fixtures/sync/formats), which Android's SyncFormatTest reads too, and the
/// merge scenarios both versions run (fixtures/sync/scenarios.json, results written by the Kotlin implementation).
@Suite struct SyncFormatTests {
    private let a = "6f1c2b9e-3d4a-4e5f-8a7b-1c2d3e4f5a6b"

    private func file<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: try Fixtures.syncData("formats/\(name)"))
    }

    @Test func libraryFile() throws {
        let f = try file(Sync.LibraryFile.self, "library.json")
        #expect(f.format == 1 && f.device == a)
        #expect(f.works["0:直排測試書 EPUB"] == Sync.WorkEntry(favorite: true, added: 1_700_000_000_000, categories: ["小說"], chapterFlags: 4097, viewerFlags: nil, t: 1_764_300_000_000, d: a))
        // Missing fields take their defaults.
        #expect(f.works["2499283573021220255:/manga/1"] == Sync.WorkEntry(t: 1_764_200_000_000, d: "0a9b8c7d-6e5f-4a3b-2c1d-0e9f8a7b6c5d"))
        #expect(f.categories["小說"] == Sync.CategoryEntry(order: 0, flags: 0, deleted: false, t: 1_764_300_000_000, d: a))
        #expect(f.categories["舊分類"]?.deleted == true)
        #expect(f.settings["pref_ebook_fontSize"]?.value == .string("24"))
        #expect(f.settings["pref_reader_theme_key"]?.value == .int(4))
        #expect(f.settings["pref_ebook_gutter_shadow"]?.value == .bool(false))
        #expect(f.settings["pref_ebook_gutter_shadow"]?.type == "bool")
        #expect(f.settings["pref_ebook_override_0123"] != nil && f.settings["pref_ebook_override_0123"]?.value == nil)
        #expect(f.progress == ["0:直排測試書 EPUB": 1_764_300_000_000])
        // What is written reads back the same.
        #expect(try JSONDecoder().decode(Sync.LibraryFile.self, from: Data(Sync.encode(f).utf8)) == f)
    }

    @Test func progressFile() throws {
        let f = try file(Sync.ProgressFile.self, "progress.json")
        #expect(f.work == "0:直排測試書 EPUB")
        let c = try #require(f.chapters["直排測試書 EPUB/zh-vertical.epub"])
        #expect(c.progress == Sync.ProgressPart(read: false, page: 12, left: 30, t: 1_764_300_000_000, d: a))
        #expect(c.bookmark == Sync.BookmarkPart(value: true, t: 1_764_200_000_000, d: a))
        #expect(SyncMerge.locatorTime(c.position?.locator) == 1_700_000_000_000)
        #expect(c.position?.locator?.contains("【第１３段】") == true)
        #expect(c.history == Sync.HistoryPart(lastRead: 1_764_300_000_000, duration: 120_000))
        let read = try #require(f.chapters["直排測試書 EPUB/zh-horizontal.epub"])
        #expect(read.progress == Sync.ProgressPart(read: true, page: 0, left: 0, t: 1_764_100_000_000, d: "0a9b8c7d-6e5f-4a3b-2c1d-0e9f8a7b6c5d"))
        // A position part without a locator: the position was cleared.
        #expect(read.position != nil && read.position?.locator == nil)
        #expect(read.bookmark == nil)
        #expect(try JSONDecoder().decode(Sync.ProgressFile.self, from: Data(Sync.encode(f).utf8)) == f)
    }

    @Test func filesAndDeviceFiles() throws {
        let f = try file(Sync.FilesFile.self, "files.json")
        #expect(f.files == [
            Sync.FileItem(work: "直排測試書 EPUB", path: "zh-vertical.epub", size: 48213, t: 1_764_300_000_000),
            Sync.FileItem(work: "漫畫測試", path: "第01話/001.jpg", size: 120_934, t: 1_764_300_000_000),
        ])
        #expect(f.files.allSatisfy(SyncNames.valid))
        #expect(try file(Sync.DeviceFile.self, "device.json") == Sync.DeviceFile(device: a, name: "Pixel 9", platform: "android", app: "1.3.0", written: 1_764_300_000_000))
        #expect(try file(Sync.LibraryFile.self, "library-newer.json").format == 2)
    }

    @Test func identifiers() {
        #expect(SyncIds.localWorkKey("直排測試書 EPUB") == "0:直排測試書 EPUB")
        #expect(SyncIds.localFolder("0:直排測試書 EPUB") == "直排測試書 EPUB")
        #expect(SyncIds.localFolder("123:/m/1") == nil)
        #expect(SyncIds.progressFileName("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709.json")
        #expect(SyncIds.newDeviceID().count == 36)
    }

    @Test func namesFromTheServerAreChecked() {
        for bad in ["", ".", "..", ".hidden", "a/b", "a\\b", "nul\u{0}", "tab\t", String(repeating: "x", count: 256)] {
            #expect(!SyncNames.validSegment(bad), "\(bad)")
        }
        #expect(SyncNames.validSegment("第01話"))
        #expect(SyncNames.validPath("第01話/001.jpg"))
        #expect(!SyncNames.validPath("a/b/c.jpg"))
        #expect(!SyncNames.validPath("../secret"))
        #expect(!SyncNames.valid(Sync.FileItem(work: "..", path: "x.epub", size: 1)))
        #expect(!SyncNames.valid(Sync.FileItem(work: "作品", path: "/x.epub", size: 1)))
    }

    // MARK: Shared merge scenarios

    private struct LibraryExpected: Decodable {
        var merged: Sync.LibraryState
        var changes: Sync.LibraryChanges
        var equal: [String]
    }

    private struct LibraryCase: Decodable {
        var snapshot: Sync.LibrarySnapshot
        var baseline: Sync.Baseline
        var remotes: [Sync.LibraryFile]
        var expected: LibraryExpected
    }

    private struct ProgressExpected: Decodable {
        var merged: Sync.ProgressState
        var changes: Sync.ProgressChanges
        var equal: [String]
    }

    private struct ProgressCase: Decodable {
        var snapshot: Sync.ProgressSnapshot
        var baseline: Sync.WorkBaseline
        var remotes: [Sync.ProgressFile]
        var expected: ProgressExpected
    }

    private struct Scenario: Decodable {
        var name: String
        var device: String
        var now: Int64
        var library: LibraryCase?
        var progress: ProgressCase?
    }

    @Test func theSharedMergeScenarios() throws {
        let scenarios = try JSONDecoder().decode([Scenario].self, from: try Fixtures.syncData("scenarios.json"))
        #expect(scenarios.count == 12)
        for s in scenarios {
            if let c = s.library {
                let local = SyncMerge.annotate(c.snapshot, c.baseline, now: s.now, device: s.device)
                let merged = SyncMerge.merge(local, c.remotes.map(\.state), now: s.now, device: s.device)
                let (changes, equal) = SyncMerge.changes(merged, c.snapshot)
                #expect(merged == c.expected.merged, "\(s.name)")
                #expect(changes == c.expected.changes, "\(s.name)")
                #expect(equal.sorted() == c.expected.equal, "\(s.name)")
            }
            if let c = s.progress {
                let local = SyncMerge.annotate(c.snapshot, c.baseline, now: s.now, device: s.device)
                let merged = SyncMerge.mergeProgress(local, c.remotes.map(\.state), now: s.now, device: s.device)
                let (changes, equal) = SyncMerge.changes(merged, c.snapshot)
                #expect(merged == c.expected.merged, "\(s.name)")
                #expect(changes == c.expected.changes, "\(s.name)")
                #expect(equal.sorted() == c.expected.equal, "\(s.name)")
            }
        }
    }
}
