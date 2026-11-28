import Foundation
import Testing
@testable import BookmaniaCore

/// The iOS side of the cross-platform test against a real WebDAV server (core/sync/interop/run.sh), with
/// URLSession; skipped unless BOOKMANIA_WEBDAV_URL is set. It checks what Android's LiveWebDavTest (Kotlin, OkHttp)
/// wrote, then reads further and sends its progress, which the Android side checks.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BOOKMANIA_WEBDAV_URL"] != nil))
struct SyncLiveTests {
    let android = "a1111111-1111-4111-8111-111111111111"
    let ios = "b2222222-2222-4222-8222-222222222222"
    let folder = "互通測試"
    var book: String { SyncIds.localWorkKey(folder) }
    var ch1: String { "\(folder)/第1冊.epub" }
    var ch2: String { "\(folder)/第2冊.epub" }
    let t1: Int64 = 1_764_300_000_000
    let t2: Int64 = 1_764_400_000_000
    var locator: String { #"{"spine":3,"href":"OEBPS/text/ch04.xhtml","location":[12,0],"text":"互通的位置","progression":0.5,"updatedAt":\#(t1)}"# }

    func bytes(_ n: Int, _ seed: Int) -> Data { Data((0 ..< n).map { UInt8((($0 * 31 + seed) % 251)) }) }

    @Test func crossPlatformSyncOnARealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BOOKMANIA_WEBDAV_ROLE"] == "ios-check" else { return }
        let dav = try WebDAVClient(baseURL: env["BOOKMANIA_WEBDAV_URL"]!, user: env["BOOKMANIA_WEBDAV_USER"] ?? "", password: env["BOOKMANIA_WEBDAV_PASSWORD"] ?? "",
                                   transport: URLSessionTransport(), requireHTTPS: false)
        let b = FakeDevice(ios)
        // The book files are not here yet, but the chapters are (as after the files arrive).
        b.setChapter(book, ch1, Sync.ChapterValue())
        b.setChapter(book, ch2, Sync.ChapterValue())
        let sync = SyncEngine(dav: dav, device: Sync.DeviceInfo(id: ios, name: "iOS interop test", platform: "ios", app: "test"), adapter: b)

        let result = try await sync.syncLibrary()
        #expect(b.works[book] == Sync.WorkValue(favorite: true, added: t1 - 1000, categories: ["互通"]))
        #expect(b.categories["互通"] == Sync.CategoryValue(order: 0, flags: 0))
        #expect(b.settings["pref_ebook_fontSize"] == Sync.SettingValue(type: "string", value: .string("26")))
        #expect(b.settings["pref_reader_theme_key"] == Sync.SettingValue(type: "int", value: .int(4)))
        #expect(b.settings["pref_ebook_gutter_shadow"] == Sync.SettingValue(type: "bool", value: .bool(false)))
        // The library sync pulled the progress too (the Android library.json lists it).
        #expect(result.works.map(\.work) == [book])
        #expect(b.chapter(book, ch1) == Sync.ChapterValue(read: true, page: 41, lastRead: t1, duration: 600_000))
        #expect(b.chapter(book, ch2) == Sync.ChapterValue(page: 12, left: 30, bookmark: true, locator: locator, lastRead: t1, duration: 120_000))

        let files = try await sync.syncFiles(b, libraryWorks: [folder])
        #expect(files.downloaded.count == 2 && files.failed.isEmpty)
        #expect(b.files["\(folder)/第1冊.epub"] == bytes(2000, 1))
        #expect(b.files["\(folder)/第2冊.epub"] == bytes(1500, 2))

        // Reading on, on the iPad.
        var v = b.chapter(book, ch2)!
        v.page = 20
        v.left = 22
        v.lastRead = t2
        v.duration = 180_000
        b.setChapter(book, ch2, v)
        #expect(try await sync.syncWork(book, push: true).uploaded)
    }
}
