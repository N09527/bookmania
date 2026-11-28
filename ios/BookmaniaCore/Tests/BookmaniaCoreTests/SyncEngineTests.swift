import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct WebDAVTests {
    @Test func onlyHTTPSAddresses() throws {
        let dav = InMemoryWebDAV()
        for bad in ["http://example.com/dav/", "ftp://example.com/", "example.com/dav", "https:///dav"] {
            #expect(throws: SyncError.self) { try WebDAVClient(baseURL: bad, user: "u", password: "p", transport: dav) }
        }
        #expect(try WebDAVClient(baseURL: "https://example.com/dav", user: "u", password: "p", transport: dav).base == "https://example.com/dav/")
    }

    @Test func pathSegmentsArePercentEncoded() throws {
        #expect(WebDAVClient.encodeSegment("直排 EPUB") == "%E7%9B%B4%E6%8E%92%20EPUB")
        #expect(WebDAVClient.encodeSegment("a-b_c.d~e") == "a-b_c.d~e")
        #expect(WebDAVClient.encodeSegment("/?#%") == "%2F%3F%23%25")
        #expect(WebDAVClient.decodePath("%E7%9B%B4%E6%8E%92%20EPUB/%F0%9F%98%80") == "直排 EPUB/😀")
        #expect(WebDAVClient.decodePath("直排%20EPUB") == "直排 EPUB")
        #expect(WebDAVClient.decodePath("%+1x") == "%+1x")
        let client = try WebDAVClient(baseURL: "https://example.com/dav/", user: "u", password: "p", transport: InMemoryWebDAV())
        #expect(client.url(["Bookmania", "作品"], collection: true) == "https://example.com/dav/Bookmania/%E4%BD%9C%E5%93%81/")
    }

    private let listing = """
    <?xml version="1.0"?>
    <D:multistatus xmlns:D="DAV:" xmlns:lp1="http://apache.org/dav/props/">
    <D:response><D:href>/dav/Bookmania/sync-v1/devices/</D:href>
     <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    <D:response><D:href>https://example.com/dav/Bookmania/sync-v1/devices/6f1c2b9e-3d4a-4e5f-8a7b-1c2d3e4f5a6b/</D:href>
     <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:getetag>"a1"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
     <D:propstat><D:prop><D:getcontentlength/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
    <D:response><D:href>/dav/Bookmania/sync-v1/devices/%E4%BD%9C%E5%93%81.json</D:href>
     <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength><lp1:executable>F</lp1:executable></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    </D:multistatus>
    """

    @Test func aListingWithAnotherPrefixFullURLsAndEncodedNames() throws {
        #expect(try WebDAVClient.parseMultistatus(listing, requested: "https://example.com/dav/Bookmania/sync-v1/devices/") == [
            DAVEntry(name: "6f1c2b9e-3d4a-4e5f-8a7b-1c2d3e4f5a6b", collection: true, etag: "\"a1\"", length: nil),
            DAVEntry(name: "作品.json", collection: false, etag: nil, length: 42),
        ])
    }

    @Test func aListingInTheDefaultNamespace() throws {
        let xml = """
        <multistatus xmlns="DAV:"><response><href>/dav/x/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        <response><href>/dav/x/y</href><propstat><prop><resourcetype></resourcetype><getcontentlength>7</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """
        #expect(try WebDAVClient.parseMultistatus(xml, requested: "https://h/dav/x/") == [DAVEntry(name: "y", collection: false, etag: nil, length: 7)])
    }

    @Test func documentTypeDeclarationsAreSkippedNotProcessed() throws {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE d:multistatus [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> <!ENTITY big "aaaaaaaaaa"> ]>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/&xxe;&big;&amp;x</d:href>
        <d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """
        #expect(try WebDAVClient.parseMultistatus(xml, requested: "https://h/dav/").map(\.name) == ["&xxe;&big;&x"])
    }

    @Test func responsesThatAreNotAListing() {
        #expect(throws: SyncError.self) { try WebDAVClient.parseMultistatus("<html><body>login</body></html>", requested: "https://h/") }
        #expect(throws: SyncError.self) { try WebDAVClient.parseMultistatus("<d:multistatus xmlns:d=\"DAV:\"><d:response>", requested: "https://h/") }
    }

    @Test func requestsAgainstTheInMemoryServer() async throws {
        let server = InMemoryWebDAV(prefix: "", fullURLHrefs: true, encodeHrefs: false)
        let dav = try WebDAVClient(baseURL: server.base, user: "reader", password: "secret", transport: server)
        try await dav.ensureCollections(["Bookmania", "作品"])
        try await dav.ensureCollections(["Bookmania", "作品"])
        try await dav.putJSON(["Bookmania", "作品", "a b.json"], "{}")
        #expect(try await dav.get(["Bookmania", "作品", "a b.json"]) == Data("{}".utf8))
        #expect(try await dav.get(["Bookmania", "missing.json"]) == nil)
        #expect(try await dav.list(["Bookmania"]) == [DAVEntry(name: "作品", collection: true)])
        #expect(try await dav.list(["Bookmania", "作品"]) == [DAVEntry(name: "a b.json", collection: false, length: 2)])
        #expect(try await dav.list(["nothing"]).isEmpty)
        await #expect(throws: SyncError(.http, "PUT no/parent.json: 409", status: 409)) { try await dav.putJSON(["no", "parent.json"], "{}") }
        let wrong = try WebDAVClient(baseURL: server.base, user: "reader", password: "wrong", transport: server)
        await #expect(throws: SyncError(.auth, "GET x: 401", status: 401)) { _ = try await wrong.get(["x"]) }
    }
}

/// Two devices (an Android phone and an iPad, say) syncing through one server, as Android's SyncEngineTest.
@Suite struct SyncEngineTests {
    final class Clock: @unchecked Sendable {
        var now: Int64 = 1_000_000
    }

    let server = InMemoryWebDAV()
    let clock = Clock()
    let phone = FakeDevice("a0000000-0000-4000-8000-000000000001")
    let pad = FakeDevice("b0000000-0000-4000-8000-000000000002")
    let phoneSync: SyncEngine
    let padSync: SyncEngine
    let book = SyncIds.localWorkKey("直排測試書")
    let ch1 = "直排測試書/第1冊.epub"
    let ch2 = "直排測試書/第2冊.epub"

    init() throws {
        let dav = try WebDAVClient(baseURL: server.base, user: "reader", password: "secret", transport: server)
        let clock = clock
        phoneSync = SyncEngine(dav: dav, device: Sync.DeviceInfo(id: phone.id, name: "test android", platform: "android", app: "1.3.0"), adapter: phone) { clock.now }
        padSync = SyncEngine(dav: dav, device: Sync.DeviceInfo(id: pad.id, name: "test ios", platform: "ios", app: "1.3.0"), adapter: pad) { clock.now }
    }

    private func tick(_ ms: Int64 = 1000) { clock.now += ms }

    @Test func theLibraryAndSettingsGoBothWays() async throws {
        phone.works[book] = Sync.WorkValue(favorite: true, added: clock.now, categories: ["小說"])
        phone.categories["小說"] = Sync.CategoryValue(order: 0, flags: 0)
        phone.settings["pref_ebook_fontSize"] = Sync.SettingValue(type: "string", value: .string("24"))
        _ = try await phoneSync.syncLibrary()
        #expect(server.files.keys.contains { $0.hasSuffix("/devices/\(phone.id)/library.json") })
        #expect(server.files.keys.contains { $0.hasSuffix("/devices/\(phone.id)/device.json") })

        tick()
        pad.settings["pref_ebook_fontSize"] = Sync.SettingValue(type: "string", value: .string("18"))
        _ = try await padSync.syncLibrary()
        #expect(pad.works[book] == Sync.WorkValue(favorite: true, added: phone.works[book]!.added, categories: ["小說"]))
        #expect(pad.categories["小說"] == Sync.CategoryValue(order: 0, flags: 0))
        #expect(pad.settings["pref_ebook_fontSize"]?.value == .string("24"))

        tick()
        pad.works[book]?.favorite = false
        pad.works[book]?.categories = []
        pad.categories["小說"] = nil
        _ = try await padSync.syncLibrary()
        tick()
        _ = try await phoneSync.syncLibrary()
        #expect(phone.works[book]?.favorite == false)
        #expect(phone.categories["小說"] == nil)
    }

    @Test func progressFollowsTheReaderAcrossDevices() async throws {
        for d in [phone, pad] {
            d.works[book] = Sync.WorkValue(favorite: true, added: 1)
            d.setChapter(book, ch1, Sync.ChapterValue())
            d.setChapter(book, ch2, Sync.ChapterValue())
        }
        _ = try await phoneSync.syncLibrary()
        _ = try await padSync.syncLibrary()

        tick()
        _ = try await phoneSync.syncWork(book, push: false)
        tick(60_000)
        phone.setChapter(book, ch1, Sync.ChapterValue(read: true, page: 99, lastRead: clock.now, duration: 60_000))
        phone.setChapter(book, ch2, Sync.ChapterValue(page: 7, left: 93, locator: "{\"spine\":2,\"href\":\"c.xhtml\",\"updatedAt\":\(clock.now)}", lastRead: clock.now, duration: 30_000))
        #expect(try await phoneSync.syncWork(book, push: true).uploaded)

        tick(60_000)
        _ = try await padSync.syncWork(book, push: false)
        #expect(pad.chapter(book, ch1) == Sync.ChapterValue(read: true, page: 99, lastRead: phone.chapter(book, ch1)!.lastRead, duration: 60_000))
        #expect(pad.chapter(book, ch2) == phone.chapter(book, ch2))

        tick(60_000)
        var v = pad.chapter(book, ch2)!
        v.page = 20
        v.left = 80
        v.lastRead = clock.now
        v.duration = 90_000
        pad.setChapter(book, ch2, v)
        _ = try await padSync.syncWork(book, push: true)
        tick(60_000)
        _ = try await phoneSync.syncWork(book, push: false)
        #expect(phone.chapter(book, ch2)?.page == 20)
        #expect(phone.chapter(book, ch2)?.duration == 90_000)

        _ = try await phoneSync.syncWork(book, push: true)
        let puts = server.requests.filter { $0.hasPrefix("PUT") }.count
        _ = try await phoneSync.syncWork(book, push: true)
        #expect(server.requests.filter { $0.hasPrefix("PUT") }.count == puts)
    }

    @Test func progressChangedElsewhereIsPulledByTheLibrarySync() async throws {
        for d in [phone, pad] {
            d.works[book] = Sync.WorkValue(favorite: true, added: 1)
            d.setChapter(book, ch1, Sync.ChapterValue())
        }
        _ = try await phoneSync.syncLibrary()
        _ = try await padSync.syncLibrary()
        tick()
        phone.setChapter(book, ch1, Sync.ChapterValue(read: true, lastRead: clock.now))
        _ = try await phoneSync.syncWork(book, push: true)
        tick()
        #expect(try await padSync.syncLibrary().works.map(\.work) == [book])
        #expect(pad.chapter(book, ch1)?.read == true)
        tick()
        #expect(try await padSync.syncLibrary().works.isEmpty)
    }

    @Test func progressChangedOutsideTheReaderGoesWithTheLibrarySync() async throws {
        phone.works[book] = Sync.WorkValue(favorite: true, added: 1)
        phone.setChapter(book, ch1, Sync.ChapterValue(page: 12, lastRead: clock.now))
        phone.setChapter(book, ch2, Sync.ChapterValue())
        _ = try await phoneSync.syncLibrary(libraryWorks: [book])
        let name = SyncIds.progressFileName(book)
        let path = "Bookmania/sync-v1/devices/\(phone.id)/progress/\(name)"
        #expect(Sync.decode(Sync.ProgressFile.self, server.files[path])?.chapters[ch1]?.progress?.page == 12)
        tick()
        phone.setChapter(book, ch2, Sync.ChapterValue(read: true))
        _ = try await phoneSync.syncLibrary(libraryWorks: [book])
        #expect(Sync.decode(Sync.ProgressFile.self, server.files[path])?.chapters[ch2]?.progress?.read == true)
        tick()
        let before = server.requests.count
        _ = try await phoneSync.syncLibrary(libraryWorks: [book])
        #expect(!server.requests.dropFirst(before).contains { $0.contains("/progress/") })
        pad.setChapter(book, ch2, Sync.ChapterValue())
        _ = try await padSync.syncLibrary()
        #expect(pad.chapter(book, ch2)?.read == true)
    }

    @Test func theFirstSyncOfALibraryReadBeforeSendsLibraryJSONTwiceNotOncePerWork() async throws {
        let books = (1...3).map { SyncIds.localWorkKey("書\($0)") }
        for b in books {
            phone.works[b] = Sync.WorkValue(favorite: true, added: 1)
            phone.setChapter(b, String(b.split(separator: ":", maxSplits: 1)[1]) + "/1.epub", Sync.ChapterValue(page: 5, lastRead: clock.now))
        }
        _ = try await phoneSync.syncLibrary(libraryWorks: Set(books))
        let own = "Bookmania/sync-v1/devices/\(phone.id)/"
        #expect(server.requests.filter { $0 == "PUT \(own)library.json" }.count == 2)
        #expect(server.requests.filter { $0.hasPrefix("PUT \(own)progress/") }.count == 3)
        let library = Sync.decode(Sync.LibraryFile.self, server.files[own + "library.json"])
        #expect(Set(library?.progress.keys.map { $0 } ?? []) == Set(books))
    }

    let androidLocator = "{\"spine\":0,\"href\":\"c.xhtml\",\"location\":[12,0],\"text\":\"第一段\",\"progression\":0.0,\"total\":0.25,\"chapterPage\":2,\"updatedAt\":5000}"
    let iosLocator = "{\"chapterPage\":2,\"href\":\"c.xhtml\",\"location\":[12,0],\"progression\":0,\"spine\":0,\"text\":\"第一段\",\"total\":0.25,\"updatedAt\":5000}"

    @Test func positionsAreComparedByContentNotByHowEachVersionWritesThem() {
        #expect(SyncMerge.sameLocator(androidLocator, iosLocator))
        #expect(SyncMerge.sameLocator(#"{"a":1,"b":null}"#, #"{"a":1.0}"#))
        #expect(!SyncMerge.sameLocator(androidLocator, iosLocator.replacingOccurrences(of: "[12,0]", with: "[13,0]")))
        #expect(!SyncMerge.sameLocator(#"{"a":"1"}"#, #"{"a":1}"#))
        #expect(!SyncMerge.sameLocator(#"{"a":true}"#, #"{"a":1}"#))
        #expect(!SyncMerge.sameLocator(androidLocator, nil))
        #expect(!SyncMerge.sameLocator("not json", "not json "))
        #expect(SyncMerge.sameLocator(nil, nil))
    }

    @Test func aPositionTakenFromAnotherVersionIsNotSentBackAsAChange() async throws {
        phone.works[book] = Sync.WorkValue(favorite: true, added: 1)
        phone.setChapter(book, ch1, Sync.ChapterValue(page: 3, locator: androidLocator, lastRead: 5000))
        _ = try await phoneSync.syncLibrary(libraryWorks: [book])
        tick()
        pad.setChapter(book, ch1, Sync.ChapterValue())
        _ = try await padSync.syncLibrary()
        #expect(pad.chapter(book, ch1)?.locator == androidLocator)
        var c = try #require(pad.chapter(book, ch1))
        c.locator = iosLocator
        pad.setChapter(book, ch1, c)
        tick()
        let before = server.requests.count
        _ = try await padSync.syncLibrary(libraryWorks: [book])
        #expect(!server.requests.dropFirst(before).contains { $0.hasPrefix("PUT") && $0.contains("/progress/") })
        #expect(!padSync.hasLocalChanges(book))
    }

    @Test func progressThatCouldNotBeSentIsSentLater() async throws {
        phone.works[book] = Sync.WorkValue(favorite: true, added: 1)
        phone.setChapter(book, ch1, Sync.ChapterValue())
        _ = try await phoneSync.syncLibrary()
        tick()
        phone.setChapter(book, ch1, Sync.ChapterValue(page: 5, lastRead: clock.now))
        server.offline = true
        await #expect(throws: SyncError(.network, "offline")) { _ = try await phoneSync.syncWork(book, push: true) }
        #expect(phone.baseline.pending == [book])
        server.offline = false
        tick()
        _ = try await phoneSync.syncLibrary()
        #expect(phone.baseline.pending.isEmpty)
        let name = SyncIds.progressFileName(book)
        let file = try #require(Sync.decode(Sync.ProgressFile.self, server.files["Bookmania/sync-v1/devices/\(phone.id)/progress/\(name)"]))
        #expect(file.chapters[ch1]?.progress?.page == 5)
    }

    @Test func bookFilesAreUploadedAndDownloadedNeverOverwritten() async throws {
        let folder = "直排測試書"
        phone.works[book] = Sync.WorkValue(favorite: true, added: 1)
        phone.files["\(folder)/第1冊.epub"] = Data(repeating: 1, count: 1000)
        phone.files["\(folder)/cover.jpg"] = Data(repeating: 2, count: 10)
        phone.files["其他/不在書櫃.epub"] = Data(count: 5)
        _ = try await phoneSync.syncLibrary()
        let up = try await phoneSync.syncFiles(phone, libraryWorks: [folder])
        #expect(Set(up.uploaded.map(\.path)) == ["第1冊.epub", "cover.jpg"])
        #expect(server.files["Bookmania/sync-v1/files/\(folder)/第1冊.epub"]?.count == 1000)
        #expect(!server.files.keys.contains { $0.contains("不在書櫃") })

        _ = try await padSync.syncLibrary()
        #expect(pad.works[book]?.favorite == true)
        pad.files["\(folder)/cover.jpg"] = Data(count: 12)
        let down = try await padSync.syncFiles(pad, libraryWorks: [folder])
        #expect(down.downloaded.map(\.path) == ["第1冊.epub"])
        #expect(down.conflicts.map(\.path) == ["cover.jpg"])
        #expect(pad.files["\(folder)/cover.jpg"]?.count == 12)
        #expect(pad.files["\(folder)/第1冊.epub"] == Data(repeating: 1, count: 1000))

        let again = try await phoneSync.syncFiles(phone, libraryWorks: [folder])
        #expect(again.uploaded.isEmpty && again.downloaded.isEmpty)
    }

    private func otherDevice(_ files: [String: String]) {
        let dir = "Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003"
        server.addCollections(["Bookmania", "Bookmania/sync-v1", "Bookmania/sync-v1/devices", dir, "Bookmania/sync-v1/files", "Bookmania/sync-v1/files/作品"])
        for (k, v) in files { server.files["\(dir)/\(k)"] = Data(v.utf8) }
    }

    @Test func namesThatCouldEscapeTheFolderAreNotDownloaded() async throws {
        otherDevice(["files.json": #"{"format":1,"files":[{"work":"作品","path":"../../secret","size":1},{"work":"..","path":"x.epub","size":1},{"work":"作品","path":"ok.epub","size":3}]}"#])
        server.files["Bookmania/sync-v1/files/作品/ok.epub"] = Data([1, 2, 3])
        pad.works[SyncIds.localWorkKey("作品")] = Sync.WorkValue(favorite: true, added: 1)
        let result = try await padSync.syncFiles(pad, libraryWorks: ["作品", ".."])
        #expect(result.downloaded.map(\.path) == ["ok.epub"])
        #expect(result.rejected.count == 2)
        #expect(Set(pad.files.keys) == ["作品/ok.epub"])
    }

    @Test func aDownloadOfTheWrongSizeIsNotKept() async throws {
        otherDevice(["files.json": #"{"format":1,"files":[{"work":"作品","path":"a.epub","size":10}]}"#])
        server.files["Bookmania/sync-v1/files/作品/a.epub"] = Data(count: 4)
        let result = try await padSync.syncFiles(pad, libraryWorks: ["作品"])
        #expect(result.downloaded.isEmpty)
        #expect(result.failed.count == 1)
        #expect(pad.files.isEmpty)
    }

    @Test func filesOfANewerFormatAreLeftOut() async throws {
        otherDevice(["library.json": #"{"format":2,"works":{"0:X":{"favorite":true,"t":5,"d":"c"}}}"#])
        let result = try await padSync.syncLibrary()
        #expect(result.newerFormat == ["c0000000-0000-4000-8000-000000000003"])
        #expect(pad.works.isEmpty)
    }

    @Test func aWrongPasswordStopsTheSync() async throws {
        let wrong = SyncEngine(dav: try WebDAVClient(baseURL: server.base, user: "reader", password: "nope", transport: server),
                               device: Sync.DeviceInfo(id: pad.id, name: "x", platform: "ios", app: "1"), adapter: pad)
        await #expect(throws: SyncError.self) { _ = try await wrong.syncLibrary() }
        await #expect(throws: SyncError.self) { _ = try await wrong.syncWork(book, push: true) }
        #expect(pad.baseline.pending.isEmpty)
    }
}
